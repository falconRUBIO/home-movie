import XCTest
import AVFoundation
import CoreImage
@testable import HomeMovie

final class GradedPipelineTests: XCTestCase {
    func testWhiteBalanceSolvesExistingSourceGainModelAndRejectsUnusableTargets() throws {
        for (w, t) in [(0.0, 0.0), (0.4, -0.2), (-0.5, 0.3)] {
            let r = 0.18 * exp2(-2 * (0.22 * w + 0.13 * t))
            let g = 0.18 * exp2(-2 * (0.025 * w - 0.16 * t))
            let b = 0.18 * exp2(-2 * (-0.245 * w + 0.13 * t))
            let correction = try WhiteBalanceSampler.correction(red: r, green: g, blue: b)
            XCTAssertEqual(correction.warmth, w, accuracy: 0.00001)
            XCTAssertEqual(correction.tint, t, accuracy: 0.00001)
        }
        XCTAssertThrowsError(try WhiteBalanceSampler.correction(red: 0, green: 0, blue: 0))
        XCTAssertThrowsError(try WhiteBalanceSampler.correction(red: .nan, green: 0.2, blue: 0.2))
        XCTAssertThrowsError(try WhiteBalanceSampler.correction(red: 0.9, green: 0.01, blue: 0.01))
    }
    func testLUTContractsRoundTripLegacyDefaultAndPreventDoubleNormalization() throws {
        var cube = try ColorCube.appleStandard.get()
        XCTAssertEqual(cube.contract, .logToDisplay)
        XCTAssertThrowsError(try cube.following(cube))
        cube.colorContract = .displayLook
        let combined = try cube.following(ColorCube.appleStandard.get())
        XCTAssertEqual(combined.contract, .logToDisplay)
        let saved = try JSONEncoder().encode(combined)
        XCTAssertEqual(try JSONDecoder().decode(ColorCube.self, from: saved).contract, .logToDisplay)
        cube.colorContract = LUTColorContract(input: .appleLogRec2020, output: .appleLogRec2020)
        XCTAssertThrowsError(try cube.validate())
    }
    func testExtendedLookHighlightsRemainDistinctAndGamutFitsWithoutChannelClipping() throws {
        let context = CIContext(options: LogPiPColor.contextOptions())
        func pixel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> [Float] {
            // CIColor's default color space can bound constant colors before
            // the kernel. Raw float pixels are the actual extended-range fixture.
            let values: [Float] = [Float(r), Float(g), Float(b), 1]
            let source = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
                size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            var raw = [Float](repeating: 0, count: 4)
            raw.withUnsafeMutableBytes { context.render(source, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            XCTAssertEqual(raw[0], Float(r), accuracy: 0.002)
            let mapped = try ColorCube.mapExtendedOutput(source)
            var result = [Float](repeating: 0, count: 4)
            result.withUnsafeMutableBytes { context.render(mapped, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            return result
        }
        let a = try pixel(1.05, 1.05, 1.05), b = try pixel(1.25, 1.25, 1.25)
        XCTAssertGreaterThan(b[0], a[0]); XCTAssertLessThan(b[0], 1)
        let saturated = try pixel(1.3, 0.3, -0.1)
        XCTAssertTrue(saturated.prefix(3).allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(saturated[0], saturated[1]); XCTAssertGreaterThan(saturated[1], saturated[2])
        let mid = try pixel(0.4, 0.4, 0.4)
        XCTAssertEqual(mid[0], 0.4, accuracy: 0.001)
    }
    func testMain10GradientExportRetainsMoreThanEightBitPrecisionAndMatchesPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let size = CGSize(width: 1024, height: 64), source = root.appendingPathComponent("source.mp4")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: GradedMovieExporter.videoSettings(size: size))
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: GradedMovieExporter.pixelFormat,
            kCVPixelBufferWidthKey as String: 1024, kCVPixelBufferHeightKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? HomeMovieError.message("Main10 fixture could not start") }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext(options: LogPiPColor.contextOptions())
        let image = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 1024, y: 0),
            "inputColor0": CIColor(red: 0.1, green: 0.1, blue: 0.1),
            "inputColor1": CIColor(red: 0.9, green: 0.9, blue: 0.9)])?.outputImage)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? HomeMovieError.message("Main10 fixture encoder failed") }
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 12, timescale: 30)); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let asset = AVURLAsset(url: source), composition = AVMutableComposition()
        let sourceTracks = try await asset.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let duration = CMTime(value: 12, timescale: 30)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        let video = AVMutableVideoComposition(); video.renderSize = size; video.frameDuration = CMTime(value: 1, timescale: 30)
        video.customVideoCompositorClass = LogVideoCompositor.self
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2; video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        video.instructions = [ColorInstruction(range: CMTimeRange(start: .zero, duration: duration), trackID: track.trackID, transform: .identity, cube: nil)]
        let bundle = CompositionBundle(asset: composition, videoComposition: video, audioMix: nil, duration: duration)
        let destination = root.appendingPathComponent("graded.mp4")
        try await GradedMovieExporter.export(bundle, to: destination) { _ in }
        func row(_ asset: AVAsset, composition: AVVideoComposition?) async throws -> [UInt16] {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: GradedMovieExporter.pixelFormat]
            let output: AVAssetReaderOutput
            if let composition {
                let composed = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: settings)
                composed.videoComposition = composition; output = composed
            } else { output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: settings) }
            reader.add(output); XCTAssertTrue(reader.startReading()); defer { reader.cancelReading() }
            let sample = try XCTUnwrap(output.copyNextSampleBuffer()), buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).advanced(by: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * 32)
            return (0..<1024).map { base.load(fromByteOffset: $0 * 2, as: UInt16.self) >> 6 }
        }
        let preview = try await row(composition, composition: video), exported = try await row(AVURLAsset(url: destination), composition: nil)
        XCTAssertGreaterThan(Set(exported).count, 256)
        for x in [128, 512, 896] { XCTAssertEqual(Double(preview[x]), Double(exported[x]), accuracy: 8) }
        let balance = try await WhiteBalanceSampler.sample(url: source, time: CMTime(value: 3, timescale: 30), point: CGPoint(x: 0.5, y: 0.5), canvas: size, logEncoded: false)
        XCTAssertEqual(balance.warmth, 0, accuracy: 0.02); XCTAssertEqual(balance.tint, 0, accuracy: 0.02)
        let cancelledURL = root.appendingPathComponent("cancelled.mp4")
        let cancelled = Task { try await GradedMovieExporter.export(bundle, to: cancelledURL) { _ in } }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled export must not succeed") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledURL.path))
        let exportedAsset = AVURLAsset(url: destination)
        let exportedTracks = try await exportedAsset.loadTracks(withMediaType: .video)
        let descriptions = try await XCTUnwrap(exportedTracks.first).load(.formatDescriptions)
        XCTAssertTrue(descriptions.allSatisfy(LogPiPColor.encodedTenBit))
        XCTAssertEqual(CMFormatDescriptionGetExtension(try XCTUnwrap(descriptions.first), extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String, AVVideoColorPrimaries_ITU_R_709_2)
    }
}
