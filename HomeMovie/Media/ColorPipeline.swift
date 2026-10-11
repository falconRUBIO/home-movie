import Foundation
import AVFoundation
import CoreImage
import CryptoKit

struct LUTReference: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var path: String { "Looks/\(id.uuidString).json" }
}
struct ColorCube: Codable, Sendable {
    let name: String
    let dimension: Int
    let rgba: Data
    var minimum: [Float] = [0, 0, 0]
    var maximum: [Float] = [1, 1, 1]
    func validate() throws {
        guard (2...65).contains(dimension), rgba.count == dimension * dimension * dimension * 16,
              !name.isEmpty, name.count <= 80, minimum.count == 3, maximum.count == 3,
              zip(minimum, maximum).allSatisfy({ $0.isFinite && $1.isFinite && $1 > $0 }) else {
            throw HomeMovieError.message("This look has invalid color data.")
        }
        let valid = rgba.withUnsafeBytes { bytes in
            (0..<(rgba.count / 4)).allSatisfy { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self).isFinite }
        }
        guard valid else { throw HomeMovieError.message("This look contains invalid color values.") }
    }
    static func parse(_ text: String, name: String) throws -> ColorCube {
        guard text.utf8.count <= 32_000_000 else { throw HomeMovieError.message("Choose a cube file smaller than 32 MB.") }
        var dimension: Int?, rgb: [Float] = [], minimum: [Float] = [0, 0, 0], maximum: [Float] = [1, 1, 1]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let values = line.split(whereSeparator: \.isWhitespace)
            guard let first = values.first else { continue }
            if first == "TITLE" { continue }
            if first == "LUT_1D_SIZE" { throw HomeMovieError.message("Choose a 3D cube look. This file is a linear conversion table.") }
            if first == "LUT_3D_SIZE" {
                guard dimension == nil, values.count == 2, let size = Int(values[1]), (2...65).contains(size), rgb.isEmpty else {
                    throw HomeMovieError.message("Choose a 3D cube with a size from 2 to 65.")
                }
                dimension = size; rgb.reserveCapacity(size * size * size * 4); continue
            }
            if first == "DOMAIN_MIN" || first == "DOMAIN_MAX" {
                guard values.count == 4, rgb.isEmpty else { throw HomeMovieError.message("Invalid cube range.") }
                let numbers = values.dropFirst().compactMap { Float($0) }
                guard numbers.count == 3 else { throw HomeMovieError.message("Invalid cube range.") }
                if first == "DOMAIN_MIN" { minimum = numbers } else { maximum = numbers }; continue
            }
            guard let dimension, values.count == 3, rgb.count < dimension * dimension * dimension * 4 else {
                throw HomeMovieError.message("This cube file is incomplete or unsupported.")
            }
            let numbers = values.compactMap { Float($0) }
            guard numbers.count == 3, numbers.allSatisfy({ $0.isFinite && abs($0) <= 64 }) else {
                throw HomeMovieError.message("Invalid cube sample.")
            }
            rgb.append(contentsOf: numbers); rgb.append(1)
        }
        guard let dimension else { throw HomeMovieError.message("No 3D color table was found.") }
        var clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if clean.hasSuffix(" LUT") { clean = String(clean.dropLast(4)) }
        let cube = ColorCube(name: clean.isEmpty ? "Custom Look" : clean, dimension: dimension,
            rgba: rgb.withUnsafeBytes { Data($0) }, minimum: minimum, maximum: maximum)
        try cube.validate(); return cube
    }
    static func load(_ reference: LUTReference, root: URL) throws -> ColorCube {
        let url = root.appendingPathComponent(reference.path)
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 8_000_000 else {
            throw HomeMovieError.message("This movie’s look is unavailable. Choose another look.")
        }
        let cube = try JSONDecoder().decode(ColorCube.self, from: Data(contentsOf: url)); try cube.validate(); return cube
    }
    static let appleStandard: Result<ColorCube, Error> = Result {
        guard let url = Bundle.main.url(forResource: "AppleLogToRec709", withExtension: "lut") else {
            throw HomeMovieError.message("The standard Log look is unavailable.")
        }
        let packed = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
        guard packed.count == 65 * 65 * 65 * 6 else { throw HomeMovieError.message("Invalid standard Log look.") }
        var samples: [Float] = []; samples.reserveCapacity(65 * 65 * 65 * 4)
        packed.withUnsafeBytes { bytes in
            for i in stride(from: 0, to: packed.count, by: 6) {
                for c in 0..<3 { samples.append(Float(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i + c * 2, as: UInt16.self))) / 65535) }
                samples.append(1)
            }
        }
        return ColorCube(name: "Apple Standard", dimension: 65, rgba: samples.withUnsafeBytes { Data($0) })
    }
    func apply(to source: CIImage) throws -> CIImage {
        let scale = (0..<3).map { CGFloat(1 / (maximum[$0] - minimum[$0])) }
        let image = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale[2], w: 0),
            "inputBiasVector": CIVector(x: -CGFloat(minimum[0]) * scale[0], y: -CGFloat(minimum[1]) * scale[1], z: -CGFloat(minimum[2]) * scale[2], w: 0)
        ])
        guard let filter = CIFilter(name: "CIColorCube", parameters: ["inputImage": image,
            "inputCubeDimension": dimension, "inputCubeData": rgba]), let output = filter.outputImage else {
            throw HomeMovieError.message("This look could not be rendered.")
        }
        return output
    }
}

final class ColorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = true
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let cube: ColorCube?
    init(range: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform, cube: ColorCube?) {
        timeRange = range; self.trackID = trackID; self.transform = transform; self.cube = cube
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}
final class LogVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String:
        [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true]
    let supportsWideColorSourceFrames = true
    let supportsHDRSourceFrames = true
    let canConformColorOfSourceFrames = false
    private let queue = DispatchQueue(label: "HomeMovie.log-render", qos: .userInitiated)
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    private let cancellationLock = NSLock()
    private var generation = 0
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() { cancellationLock.lock(); generation += 1; cancellationLock.unlock() }
    private func currentGeneration() -> Int { cancellationLock.lock(); defer { cancellationLock.unlock() }; return generation }
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let started = currentGeneration()
        queue.async {
            guard self.currentGeneration() == started else { request.finishCancelledRequest(); return }
            do {
                guard let instruction = request.videoCompositionInstruction as? ColorInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.trackID),
                      let destination = request.renderContext.newPixelBuffer() else {
                    throw HomeMovieError.message("A video frame could not be prepared.")
                }
                var image = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
                if let cube = instruction.cube { image = try cube.apply(to: image) }
                let sourceFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(CVPixelBufferGetHeight(source)))
                let outputFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: request.renderContext.size.height)
                image = image.transformed(by: sourceFlip.concatenating(instruction.transform).concatenating(outputFlip))
                let bounds = CGRect(origin: .zero, size: request.renderContext.size)
                image = image.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
                self.context.render(image, to: destination, bounds: bounds, colorSpace: nil)
                guard self.currentGeneration() == started else { request.finishCancelledRequest(); return }
                CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                request.finish(withComposedVideoFrame: destination)
            } catch { request.finish(with: error) }
        }
    }
}
