import XCTest
import AVFoundation
import CoreImage
@testable import HomeMovie

final class LogPiPTests: XCTestCase {
    func testLogPiPCanvasUsesMovieOrientationRatherThanFrontSensorRotation() {
        for format in MovieFormat.allCases {
            for observed: CGFloat in [0, 90, 180, 270] {
                let canvasAngle = format.recordingAngle(observed: observed, profile: .appleLog, composited: true)
                XCTAssertEqual(MovieFormat.captureFormat(angle: canvasAngle), format)
                XCTAssertEqual(format.recordingAngle(observed: observed, profile: .appleLog), observed,
                    "Ordinary Log capture must retain the camera-native correction")
            }
        }
        XCTAssertTrue(CameraCompatibility.isHD(width: 1080, height: 1920))
        XCTAssertTrue(CameraCompatibility.isHD(width: 1920, height: 1440))
        XCTAssertTrue(CameraCompatibility.isHD(width: 3840, height: 2160))
        XCTAssertFalse(CameraCompatibility.isHD(width: 1280, height: 720))
    }
    func testPortraitLogPiPRecordingSavesTenBitLogWithAnUprightCanvas() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let angle = MovieFormat.portrait.recordingAngle(observed: 0, profile: .appleLog, composited: true)
        let writer = try ContinuousTakeWriter(url: url, angle: angle, profile: .appleLog)
        XCTAssertEqual(writer.canvas, MovieFormat.portrait.canvas)
        let rear = try frame(0.2), front = try frame(0.8)
        let state = PiPPresentation(composition: .sideBySide, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), opacity: 1, enabled: true)
        let image = PiPCompositor.image(background: rear, presenter: front, canvas: writer.canvas,
            backgroundAngle: 90, presenterAngle: 0, presentation: state, profile: .appleLog)
        let rendered = try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(image, canvas: writer.canvas))
        for index in 0..<3 {
            var accepted = false
            for _ in 0..<100 {
                if writer.appendRenderedVideo(rendered, at: CMTime(value: Int64(index), timescale: 30)) { accepted = true; break }
                if let failure = writer.failure { throw failure }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(accepted)
        }
        let finished = expectation(description: "Portrait Log PiP saved and verified")
        writer.finish { error in XCTAssertNil(error); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 30)
        try await LogPiPValidation.verifySavedFile(url: url, expectedCanvas: MovieFormat.portrait.canvas)
        let info = try await MediaInspector.inspect(url)
        XCTAssertEqual(info.profile, .appleLog); XCTAssertEqual(info.size, MovieFormat.portrait.canvas)
        do {
            try await LogPiPValidation.verifySavedFile(url: url, expectedCanvas: MovieFormat.landscape.canvas)
            XCTFail("A rotated or incorrectly sized saved take must fail validation")
        } catch {}
    }
    private func frame(_ value: CGFloat, size: CGSize = CGSize(width: 128, height: 128)) throws -> CVPixelBuffer {
        try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(
            CIImage(color: CIColor(red: value, green: value, blue: value)), canvas: size))
    }
    func testLogCompositionRetainsTenBitCodeValuesAndTransferAttachments() throws {
        let rear = try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(
            CIImage(color: CIColor(red: 0.65, green: 0.25, blue: 0.1)), canvas: CGSize(width: 128, height: 128)))
        let front = try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(
            CIImage(color: CIColor(red: 0.1, green: 0.4, blue: 0.75)), canvas: CGSize(width: 128, height: 128)))
        XCTAssertTrue(LogPiPColor.isLog(rear)); XCTAssertTrue(LogPiPColor.isLog(front))
        let canvas = CGSize(width: 256, height: 256)
        let state = PiPPresentation(composition: .sideBySide, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), opacity: 1, enabled: true)
        let composed = PiPCompositor.image(background: rear, presenter: front, canvas: canvas,
            backgroundAngle: 0, presenterAngle: 0, presentation: state, profile: .appleLog)
        let result = try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(composed, canvas: canvas))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(result), LogPiPColor.pixelFormat)
        XCTAssertTrue(LogPiPColor.isLog(result))
        let context = CIContext(options: LogPiPColor.contextOptions())
        let image = CIImage(cvPixelBuffer: result, options: [.colorSpace: NSNull()])
        let samples: [(Int, [Float])] = [(40, [0.65, 0.25, 0.1]), (200, [0.1, 0.4, 0.75])]
        for (x, expected) in samples {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: x, y: 128, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            }
            for channel in 0..<3 {
                XCTAssertEqual(pixel[channel], expected[channel], accuracy: 0.02, "Spatial composition must not bake a viewing transform into Log")
            }
        }
    }
    func testLogSourceHintCarriesAppleLogAndStandardBufferIsRejected() throws {
        let hint = try LogPiPColor.sourceHint(canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(CMFormatDescriptionGetExtension(hint, extensionKey: kCMFormatDescriptionExtension_LogTransferFunction) as? String,
            kCMFormatDescriptionLogTransferFunction_AppleLog as String)
        let standard = try XCTUnwrap(PiPFrameRenderer().render(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)), canvas: CGSize(width: 64, height: 64)))
        XCTAssertFalse(LogPiPColor.isLog(standard))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ContinuousTakeWriter(url: url, angle: 90, profile: .appleLog)
        XCTAssertFalse(writer.appendVideo(standard, at: .zero)); XCTAssertNotNil(writer.failure)
        writer.writer.cancelWriting()
    }
    func testActualLogEncoderPreservesMetadataAndTenBitDecoding() async throws {
        try await LogPiPValidation.shared.check()
    }
}
