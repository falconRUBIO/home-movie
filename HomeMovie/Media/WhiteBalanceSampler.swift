import AVFoundation
import CoreImage

// Samples decoded source pixels BEFORE the LUT, using the same spatial transform
// as scene review. The result drives the existing reversible Warmth/Tint recipe.
enum WhiteBalanceSampler {
    static func correction(red: Double, green: Double, blue: Double) throws -> (warmth: Double, tint: Double) {
        guard [red, green, blue].allSatisfy({ $0.isFinite && $0 > 0.002 }) else {
            throw HomeMovieError.message("Choose a brighter neutral gray area.")
        }
        let rg = log2(red / green), bg = log2(blue / green)
        let warmth = (bg - rg) / 0.93
        let tint = (-rg - 0.39 * warmth) / 0.58
        guard abs(warmth) <= 1, abs(tint) <= 1 else {
            throw HomeMovieError.message("Choose a less strongly colored neutral area, or adjust Warmth and Tint manually.")
        }
        return (warmth, tint)
    }
    static func sample(url: URL, time: CMTime, point: CGPoint, canvas: CGSize, logEncoded: Bool) async throws -> (warmth: Double, tint: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw HomeMovieError.message("The clip is unavailable.") }
        let range = try await track.load(.timeRange)
        let size = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: logEncoded ? GradedMovieExporter.pixelFormat : kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { throw HomeMovieError.message("The clip could not be sampled.") }
        reader.add(output)
        let position = CMTimeMinimum(CMTimeMaximum(.zero, time), CMTimeSubtract(range.duration, CMTime(value: 1, timescale: 30)))
        reader.timeRange = CMTimeRange(start: CMTimeAdd(range.start, position), duration: CMTime(value: 1, timescale: 15))
        guard reader.startReading() else { throw reader.error ?? HomeMovieError.message("The clip could not be sampled.") }
        defer { reader.cancelReading() }
        try Task.checkCancellation()
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw reader.error ?? HomeMovieError.message("This frame could not be sampled. Try another frame.")
        }
        var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(CVPixelBufferGetHeight(buffer)))
        let outputFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvas.height)
        image = image.transformed(by: flip.concatenating(MediaAssembler.fitTransform(size: size, preferred: preferred, canvas: canvas)).concatenating(outputFlip))
        let location = CGPoint(x: point.x * canvas.width, y: (1 - point.y) * canvas.height)
        let patch = CGRect(x: location.x - 4, y: location.y - 4, width: 9, height: 9)
        guard image.extent.contains(patch) else { throw HomeMovieError.message("Choose a neutral area inside the video.") }
        let kernel = try linearKernel.get()
        guard let linear = kernel.apply(extent: patch, arguments: [image, logEncoded ? 1.0 : 0.0]) else {
            throw HomeMovieError.message("White balance could not be calculated.")
        }
        let average = linear.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: patch)])
        var values = [Float](repeating: 0, count: 4)
        let context = CIContext(options: LogPiPColor.contextOptions())
        values.withUnsafeMutableBytes {
            context.render(average, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        return try correction(red: Double(values[0]), green: Double(values[1]), blue: Double(values[2]))
    }
    private static let linearKernel: Result<CIColorKernel, Error> = Result {
        guard let url = Bundle.main.url(forResource: "FilmEffects", withExtension: "metallib") else { throw HomeMovieError.message("White balance is unavailable.") }
        return try CIColorKernel(functionName: "neutralSource", fromMetalLibraryData: Data(contentsOf: url))
    }
}
