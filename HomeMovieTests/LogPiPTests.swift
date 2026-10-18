import XCTest
import AVFoundation
import CoreImage
@testable import HomeMovie

final class LogPiPTests: XCTestCase {
    private func frame(_ value: CGFloat, size: CGSize = CGSize(width: 128, height: 128)) throws -> CVPixelBuffer {
        try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(
            CIImage(color: CIColor(red: value, green: value, blue: value)), canvas: size))
    }
    func testLogCompositionRetainsTenBitCodeValuesAndTransferAttachments() throws {
        let rear = try frame(0.2), front = try frame(0.8)
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
        let samples: [(Int, Float)] = [(40, 0.2), (200, 0.8)]
        for (x, expected) in samples {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                    bounds: CGRect(x: x, y: 128, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            }
            XCTAssertEqual(pixel[0], expected, accuracy: 0.02, "Spatial composition must not bake a viewing transform into Log")
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
