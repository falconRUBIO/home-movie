import XCTest
import AVFoundation
import CoreImage
@testable import HomeMovie

final class SceneAdjustmentsTests: XCTestCase {
    private func sample(_ image: CIImage) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        pixel.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        return pixel
    }
    private func gray(_ value: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    func testNeutralIsExactBypassAndInvalidValuesAreRejected() throws {
        let image = gray(0.5)
        XCTAssertTrue(try SceneAdjustments.neutral.apply(to: image) === image)
        XCTAssertThrowsError(try SceneAdjustments(exposure: .nan).validate())
        XCTAssertThrowsError(try SceneAdjustments(shadows: 2).validate())
        XCTAssertThrowsError(try SceneAdjustments(highlights: .infinity).validate())
    }
    func testLightStageRunsAfterLUTWithoutMutatingEither() throws {
        let input = gray(0.7)
        let values = Array(repeating: [Float(0.2), Float(0.2), Float(0.2), Float(1)], count: 8).flatMap { $0 }
        let cube = ColorCube(name: "Constant", dimension: 2, rgba: values.withUnsafeBytes { Data($0) })
        let recipe = SceneAdjustments(exposure: 0.5)
        let instruction = ColorInstruction(range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)),
            trackID: 1, transform: .identity, cube: cube, adjustments: recipe)
        let expected = sample(try recipe.apply(to: cube.apply(to: input)))
        let actual = sample(try instruction.applyingColor(to: input))
        XCTAssertEqual(actual, expected)
        XCTAssertGreaterThan(actual[0], 0.2)
        XCTAssertEqual(sample(input)[0], 0.7, accuracy: 0.0001)
        XCTAssertEqual(sample(try cube.apply(to: input))[0], 0.2, accuracy: 0.0001)
    }
    func testTonalMasksPreserveOppositeRangeAndEndpoints() throws {
        let shadows = SceneAdjustments(shadows: 0.7)
        XCTAssertGreaterThan(sample(try shadows.apply(to: gray(0.1)))[0], 0.1)
        XCTAssertEqual(sample(try shadows.apply(to: gray(0.9)))[0], 0.9, accuracy: 0.0001)
        let highlights = SceneAdjustments(highlights: -0.7)
        XCTAssertLessThan(sample(try highlights.apply(to: gray(0.9)))[0], 0.9)
        XCTAssertEqual(sample(try highlights.apply(to: gray(0.1)))[0], 0.1, accuracy: 0.0001)
        let all = SceneAdjustments(exposure: 1, shadows: 1, highlights: -1)
        XCTAssertEqual(sample(try all.apply(to: gray(0)))[0], 0, accuracy: 0.0001)
        XCTAssertEqual(sample(try all.apply(to: gray(1)))[0], 1, accuracy: 0.0001)
    }
    func testOldSceneCatalogDecodesWithNeutralLight() throws {
        let scene = Scene(id: UUID(), sequence: 0, source: "fixture", capturedAt: Date(), timeZone: "UTC",
            sourceDuration: MediaTime(seconds: 2), trimStart: MediaTime(seconds: 0), trimEnd: MediaTime(seconds: 2),
            width: 1920, height: 1080, hasAudio: false, bytes: 1)
        let data = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(Scene.self, from: data)
        XCTAssertEqual(decoded.lightAdjustments, .neutral)
    }
}
