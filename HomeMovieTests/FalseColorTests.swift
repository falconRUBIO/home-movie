import XCTest
import AVFoundation
import CoreImage
import MetalKit
@testable import HomeMovie

final class FalseColorTests: XCTestCase {
    private let context = CIContext(options: LogPiPColor.contextOptions())
    private func encode(_ linear: Double) -> Double {
        if linear >= 0.01 { return 0.08550479 * log2(linear + 0.00964052) + 0.69336945 }
        return 47.28711236 * pow(linear + 0.05641088, 2)
    }
    private func sample(_ image: CIImage, x: CGFloat = 0, y: CGFloat = 0) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        return pixel
    }
    private func assertColor(_ actual: [Float], _ expected: [Float], file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<4 { XCTAssertEqual(actual[i], expected[i], accuracy: 0.025, file: file, line: line) }
    }
    private func neutral(_ stops: Double, fullRange: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let format = fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : LogPiPColor.pixelFormat
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        let code = encode(0.18 * pow(2, stops))
        let y = UInt16((fullRange ? code * 1023 : 64 + code * 876).rounded()) << 6
        XCTAssertEqual(CVPixelBufferLockBaseAddress(result, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(result, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(result, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(result, plane) {
                let values = base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)
                for column in 0..<(stride / 2) { values[column] = plane == 0 ? y : UInt16(512 << 6) }
            }
        }
        LogPiPColor.attach(to: result)
        return result
    }
    func testZonesRenderFromAppleLogRatherThanDisplayBrightness() throws {
        let cases: [(Double, [Float])] = [
            (-7, [0.55, 0, 0.85, 1]), (-5, [0, 0.25, 1, 1]),
            (0, [0.1, 0.8, 0.2, 1]), (1, [1, 0.45, 0.65, 1]),
            (3.5, [1, 0.65, 0, 1]), (4.5, [1, 0.08, 0.03, 1])]
        for fullRange in [false, true] {
            for (stops, expected) in cases {
                assertColor(sample(try FalseColorPreview.image(neutral(stops, fullRange: fullRange))), expected)
            }
        }
    }
    func testRejectsUntaggedFramesInsteadOfDisplayingMisleadingExposure() throws {
        let buffer = try neutral(0)
        CVBufferRemoveAttachment(buffer, kCVImageBufferLogTransferFunctionKey)
        XCTAssertThrowsError(try FalseColorPreview.image(buffer))
    }
    func testHiddenPresenterDoesNotInvalidateTheVisibleExposureMap() throws {
        let rear = try neutral(0), hidden = try neutral(0)
        CVBufferRemoveAttachment(hidden, kCVImageBufferLogTransferFunctionKey)
        let image = try FalseColorPreview.image(background: rear, presenter: hidden, canvas: CGSize(width: 64, height: 64),
            backgroundAngle: 0, presenterAngle: 0, presentation: PiPPresentation())
        assertColor(sample(image), [0.1, 0.8, 0.2, 1])
    }
    @MainActor func testToggleBypassesLUTAndRestoresItWithoutChangingSource() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(LiveLookRenderer(device: device))
        let frames = LiveFrames(), buffer = try neutral(0)
        let before = sample(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]))
        let data: [Float] = Array(repeating: [Float(0.2), 0.2, 0.2, 1], count: 8).flatMap { $0 }
        let cube = data.withUnsafeBytes { ColorCube(name: "Test", dimension: 2, rgba: Data($0)) }
        renderer.configure(frames: frames, cube: cube, active: true, logSource: true, falseColor: true)
        let id = renderer.presentationID
        assertColor(sample(try renderer.previewImage(buffer, to: CGSize(width: 64, height: 64), pip: nil)), [0.1, 0.8, 0.2, 1])
        renderer.configure(frames: frames, cube: cube, active: true, logSource: true, falseColor: false)
        XCTAssertFalse(renderer.canPresent(id))
        assertColor(sample(try renderer.previewImage(buffer, to: CGSize(width: 64, height: 64), pip: nil)), [0.2, 0.2, 0.2, 1])
        assertColor(sample(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])), before)
        XCTAssertTrue(LogPiPColor.isLog(buffer))
        renderer.configure(frames: frames, cube: nil, active: true, logSource: true, falseColor: true)
        XCTAssertTrue(renderer.canPresent(renderer.presentationID), "Flat Log must not require a LUT")
        renderer.configure(frames: frames, cube: nil, active: true, passthrough: true, logSource: false, falseColor: true)
        XCTAssertFalse(renderer.falseColor, "Remembered preference must not classify SDR as Apple Log")
    }
    @MainActor func testPiPMapsBothSourcesBeforeCompositionAndKeepsWriterOutputClean() throws {
        let rear = try neutral(0), front = try neutral(4.5)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(PiPLayoutRenderer(device: device))
        renderer.profile = .appleLog; renderer.falseColor = true
        for composition: PiPComposition in [.sideBySide, .topAndBottom, .inset] {
            for swapped in [false, true] {
                let presentation = PiPPresentation(composition: composition, splitSwapped: swapped,
                    rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3), opacity: 1, enabled: true)
                let unit = composition == .inset ? presentation.rect : try XCTUnwrap(composition.presenterRect(swapped: swapped))
                let point = CGPoint(x: unit.midX * 128, y: (1 - unit.midY) * 128)
                let mapped = try renderer.monitoringImage(background: rear, presenter: front, canvas: CGSize(width: 128, height: 128),
                    backgroundAngle: 0, presenterAngle: 90, presentation: presentation)
                assertColor(sample(mapped, x: point.x.rounded(), y: point.y.rounded()), [1, 0.08, 0.03, 1])
                let rearUnit = composition == .inset ? CGRect(x: 0, y: 0, width: 0.4, height: 0.4) : try XCTUnwrap(composition.presenterRect(swapped: !swapped))
                assertColor(sample(mapped, x: (rearUnit.midX * 128).rounded(), y: ((1 - rearUnit.midY) * 128).rounded()), [0.1, 0.8, 0.2, 1])
                let clean = PiPCompositor.image(background: rear, presenter: front, canvas: CGSize(width: 128, height: 128),
                    backgroundAngle: 0, presenterAngle: 90, presentation: presentation, profile: .appleLog)
                let pixel = sample(clean, x: point.x.rounded(), y: point.y.rounded())
                XCTAssertEqual(pixel[0], pixel[1], accuracy: 0.01)
                XCTAssertEqual(pixel[1], pixel[2], accuracy: 0.01)
            }
        }
    }
}


extension FalseColorTests {
    func testViewfinderChoiceResolvesLegacySwitchesWithoutConflictingModes() {
        XCTAssertEqual(CameraPreviewMode(originalLog: false, falseColor: false), .look)
        XCTAssertEqual(CameraPreviewMode(originalLog: true, falseColor: false), .log)
        XCTAssertEqual(CameraPreviewMode(originalLog: false, falseColor: true), .falseColor)
        XCTAssertEqual(CameraPreviewMode(originalLog: true, falseColor: true), .falseColor)
    }
    func testViewfinderChoiceRoundTripsAndOnlyChangesPreviewPreferences() throws {
        let suite = "LookPreviewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Cinema", forKey: "fixtureMovieLook")
        defaults.set("appleLog", forKey: "fixtureCaptureProfile")
        for original in [false, true] { for falseColor in [false, true] {
            defaults.set(original, forKey: CameraPreviewMode.originalLogPreferenceKey)
            defaults.set(falseColor, forKey: FalseColorPreview.preferenceKey)
            for choice in CameraPreviewMode.allCases {
                choice.store(in: defaults)
                XCTAssertEqual(CameraPreviewMode.read(from: defaults), choice)
                XCTAssertFalse(defaults.bool(forKey: CameraPreviewMode.originalLogPreferenceKey)
                    && defaults.bool(forKey: FalseColorPreview.preferenceKey))
                XCTAssertEqual(defaults.string(forKey: "fixtureMovieLook"), "Cinema")
                XCTAssertEqual(defaults.string(forKey: "fixtureCaptureProfile"), "appleLog")
            }
        } }
    }
}


extension FalseColorTests {
    func testAllSixLegendColorsMatchTheRenderedMapInFullAndVideoRange() throws {
        let probes: [(FalseColorZone, Double)] = [(.purple, -7), (.blue, -5), (.middleGray, 0),
            (.pink, 1), (.orange, 3.5), (.red, 4.5)]
        XCTAssertEqual(probes.map(\.0), FalseColorZone.allCases)
        for fullRange in [false, true] {
            for (zone, stops) in probes {
                let actual = sample(try FalseColorPreview.image(neutral(stops, fullRange: fullRange)))
                assertColor(actual, [zone.rgb.x, zone.rgb.y, zone.rgb.z, 1])
            }
        }
    }
    func testUnmarkedExposureRangesStayGrayscaleRatherThanImplyingAWarning() throws {
        for stops in [-3.0, -1, 0.5, 2, 2.5] {
            let actual = sample(try FalseColorPreview.image(neutral(stops)))
            XCTAssertEqual(actual[0], actual[1], accuracy: 0.002)
            XCTAssertEqual(actual[1], actual[2], accuracy: 0.002)
        }
    }
}
