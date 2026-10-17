import XCTest
import AVFoundation
import CoreImage
@testable import HomeMovie

final class SceneAdjustmentsTests: XCTestCase {
    private let sampleContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private func sample(_ image: CIImage) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        let context = sampleContext
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
        let recipe = SceneAdjustments(exposure: 0.5, warmth: 0.4, tint: -0.3, brightness: 0.2, brilliance: 0.3, pushPull: -0.2)
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
    func testCombinedExtremeControlsNeverInvertOrClipTheTonalRamp() throws {
        let width = 256
        var rgba: [Float] = []
        for x in 0..<width {
            let level = Float(x) / Float(width - 1)
            rgba.append(contentsOf: [level, level, level, 1])
        }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: 1), format: .RGBAf, colorSpace: nil)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for exposure in [-1.0, 1.0] {
            for shadows in [-1.0, 1.0] {
                for highlights in [-1.0, 1.0] {
                    let output = try SceneAdjustments(exposure: exposure, shadows: shadows, highlights: highlights).apply(to: image)
                    var pixels = [Float](repeating: 0, count: width * 4)
                    pixels.withUnsafeMutableBytes {
                        context.render(output, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                            bounds: image.extent, format: .RGBAf, colorSpace: nil)
                    }
                    let ramp = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
                    XCTAssertTrue(ramp.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                    XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $1 >= $0 })
                }
            }
        }
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


extension SceneAdjustmentsTests {
    func testLegacyRecipesDecodeWithNeutralColorBalanceAndRoundTripNewValues() throws {
        let legacy = Data(#"{"exposure":0.25,"shadows":-0.2,"highlights":0.1}"#.utf8)
        let decoded = try JSONDecoder().decode(SceneAdjustments.self, from: legacy)
        XCTAssertEqual(decoded.exposure, 0.25)
        XCTAssertEqual(decoded.warmth, 0)
        XCTAssertEqual(decoded.tint, 0)
        let recipe = SceneAdjustments(exposure: 0.25, warmth: -0.4, tint: 0.6)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(recipe)), recipe)
        XCTAssertThrowsError(try SceneAdjustments(warmth: .nan).validate())
        XCTAssertThrowsError(try SceneAdjustments(tint: 1.01).validate())
    }
    func testWarmthAndTintDirectionsPreserveLuminanceAndNeutralEndpoints() throws {
        let input = gray(0.5)
        for direction in [-1.0, 1.0] {
            let warm = sample(try SceneAdjustments(warmth: direction).apply(to: input))
            let tint = sample(try SceneAdjustments(tint: direction).apply(to: input))
            XCTAssertGreaterThan((warm[0] - warm[2]) * Float(direction), 0)
            XCTAssertGreaterThan(((tint[0] + tint[2]) / 2 - tint[1]) * Float(direction), 0)
            for values in [warm, tint] {
                XCTAssertEqual(values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722, 0.5, accuracy: 0.0001)
                XCTAssertEqual(values[3], 1, accuracy: 0.0001)
            }
        }
        for warmth in [-1.0, 1.0] {
            for tint in [-1.0, 1.0] {
                let recipe = SceneAdjustments(warmth: warmth, tint: tint)
                for level in [0.0, 0.01, 0.5, 0.99, 1.0] {
                    let pixel = sample(try recipe.apply(to: gray(CGFloat(level))))
                    XCTAssertTrue(pixel.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                    if level == 0 || level == 1 {
                        for channel in 0..<3 { XCTAssertEqual(pixel[channel], Float(level), accuracy: 0.0001) }
                    }
                }
            }
        }
    }
}


extension SceneAdjustmentsTests {
    func testAdditionalLightControlsHaveDistinctResponsesAndNeutralDefaults() throws {
        let old = Data(#"{"exposure":0.2,"warmth":0.3,"tint":-0.1}"#.utf8)
        let decoded = try JSONDecoder().decode(SceneAdjustments.self, from: old)
        XCTAssertEqual(decoded.brightness, 0)
        XCTAssertEqual(decoded.brilliance, 0)
        XCTAssertEqual(decoded.pushPull, 0)
        let recipe = SceneAdjustments(brightness: -0.3, brilliance: 0.4, pushPull: 0.5)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(recipe)), recipe)
        XCTAssertThrowsError(try SceneAdjustments(brightness: .nan).validate())
        XCTAssertThrowsError(try SceneAdjustments(brilliance: 2).validate())
        XCTAssertThrowsError(try SceneAdjustments(pushPull: .infinity).validate())
        let bright = sample(try SceneAdjustments(brightness: 1).apply(to: gray(0.5)))[0]
        let dark = sample(try SceneAdjustments(brightness: -1).apply(to: gray(0.5)))[0]
        XCTAssertGreaterThan(bright, 0.5)
        XCTAssertLessThan(dark, 0.5)
        let bShadow = sample(try SceneAdjustments(brightness: 1).apply(to: gray(0.1)))[0] - 0.1
        let bMiddle = bright - 0.5
        let eShadow = sample(try SceneAdjustments(exposure: 1).apply(to: gray(0.1)))[0] - 0.1
        let eMiddle = sample(try SceneAdjustments(exposure: 1).apply(to: gray(0.5)))[0] - 0.5
        XCTAssertLessThan(bShadow / bMiddle, eShadow / eMiddle)
        XCTAssertGreaterThan(sample(try SceneAdjustments(brilliance: 1).apply(to: gray(0.2)))[0], 0.2)
        XCTAssertLessThan(sample(try SceneAdjustments(brilliance: 1).apply(to: gray(0.9)))[0], 0.9)
        XCTAssertLessThan(sample(try SceneAdjustments(pushPull: 1).apply(to: gray(0.2)))[0], 0.2)
        XCTAssertGreaterThan(sample(try SceneAdjustments(pushPull: 1).apply(to: gray(0.8)))[0], 0.8)
        XCTAssertGreaterThan(sample(try SceneAdjustments(pushPull: -1).apply(to: gray(0.2)))[0], 0.2)
    }
    func testAdditionalLightControlsPreserveMonotonicRampAndEndpointsAtExtremes() throws {
        let levels: [CGFloat] = [0, 0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99, 1]
        for brightness in [-1.0, 1.0] {
            for brilliance in [-1.0, 1.0] {
                for pushPull in [-1.0, 1.0] {
                    let recipe = SceneAdjustments(brightness: brightness, brilliance: brilliance, pushPull: pushPull)
                    let ramp = try levels.map { sample(try recipe.apply(to: gray($0)))[0] }
                    XCTAssertTrue(ramp.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
                    XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $1 >= $0 })
                    XCTAssertEqual(ramp.first!, 0, accuracy: 0.0001)
                    XCTAssertEqual(ramp.last!, 1, accuracy: 0.0001)
                }
            }
        }
    }
}
