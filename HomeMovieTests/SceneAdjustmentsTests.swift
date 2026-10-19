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
    private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    private func colorfulness(_ pixel: [Float]) -> Float {
        let rgb = Array(pixel.prefix(3))
        return (rgb.max()! - rgb.min()!) / max(rgb.max()!, 0.00001)
    }
    func testHSLRoundTripLegacyDefaultsAndValidation() throws {
        var recipe = SceneAdjustments.neutral
        recipe.hsl[.orange] = HSLValues(hue: 0.25, saturation: -0.5, lightness: 0.4)
        XCTAssertTrue(recipe.isActive)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(recipe)), recipe)
        XCTAssertFalse(try JSONDecoder().decode(SceneAdjustments.self, from: Data("{}".utf8)).hsl.isActive)
        recipe.hsl[.blue].hue = .nan
        XCTAssertThrowsError(try recipe.validate())
        let malformed = Data(#"{"hsl":{"bands":[]}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SceneAdjustments.self, from: malformed))
    }
    func testHSLNeutralIdentityGrayProtectionAndSelectedColor() throws {
        let red = color(0.8, 0.2, 0.2), blue = color(0.2, 0.2, 0.8)
        XCTAssertEqual(sample(try HSLAdjustments().apply(to: red)), sample(red))
        var hsl = HSLAdjustments(); hsl[.red].saturation = -1
        let muted = sample(try hsl.apply(to: red))
        XCTAssertLessThan(colorfulness(muted), colorfulness(sample(red)) * 0.5)
        let unchanged = sample(try hsl.apply(to: blue))
        for i in 0..<4 { XCTAssertEqual(unchanged[i], sample(blue)[i], accuracy: 0.002) }
        for band in HSLBand.allCases { hsl[band] = HSLValues(hue: 1, saturation: 1, lightness: 1) }
        let neutral = sample(try hsl.apply(to: gray(0.4)))
        for i in 0..<3 { XCTAssertEqual(neutral[i], 0.4, accuracy: 0.002) }
    }
    func testHSLWrapAndSharedFinishingStage() throws {
        var recipe = SceneAdjustments.neutral
        recipe.hsl[.red] = HSLValues(hue: 0.5, saturation: 0, lightness: 0.4)
        let a = sample(try recipe.applyingFinishing(to: color(0.8, 0.2, 0.201)))
        let b = sample(try recipe.applyingFinishing(to: color(0.8, 0.201, 0.2)))
        for i in 0..<3 { XCTAssertEqual(a[i], b[i], accuracy: 0.01) }
        let original = sample(color(0.8, 0.2, 0.2))
        XCTAssertGreaterThan(a[1], original[1])
        let balanced = sample(try recipe.applyingBalance(to: color(0.8, 0.2, 0.2), logEncoded: true))
        for i in 0..<3 { XCTAssertEqual(balanced[i], original[i], accuracy: 0.002) }
    }
    func testNewControlsRoundTripAndOldEditsRetainTheirPipeline() throws {
        let recipe = SceneAdjustments(exposure: 0.3, contrast: 0.4, blackPoint: -0.2, saturation: 0.5, vibrance: -0.6)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(recipe)), recipe)
        let old = try JSONDecoder().decode(SceneAdjustments.self, from: Data(#"{"exposure":0.3,"warmth":0.2}"#.utf8))
        XCTAssertEqual(old.pipelineVersion, 1)
        XCTAssertEqual(old.contrast, 0); XCTAssertEqual(old.blackPoint, 0)
        XCTAssertEqual(old.saturation, 0); XCTAssertEqual(old.vibrance, 0)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(old)), old)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: Data("{}".utf8)), .neutral)
        for path in [\SceneAdjustments.contrast, \.blackPoint, \.saturation, \.vibrance] {
            for invalid in [Double.nan, .infinity, -1.01, 1.01] {
                var bad = SceneAdjustments.neutral; bad[keyPath: path] = invalid
                XCTAssertThrowsError(try bad.validate())
            }
        }
        var badVersion = recipe; badVersion.pipelineVersion = 3
        XCTAssertThrowsError(try badVersion.validate())
    }
    func testContrastIsSymmetricAndBlackPointIsAnIndependentToe() throws {
        let strong = SceneAdjustments(contrast: 1), soft = SceneAdjustments(contrast: -1)
        XCTAssertLessThan(sample(try strong.apply(to: gray(0.25)))[0], 0.1)
        XCTAssertGreaterThan(sample(try strong.apply(to: gray(0.75)))[0], 0.9)
        XCTAssertEqual(sample(try strong.apply(to: gray(0.5)))[0], 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(sample(try soft.apply(to: gray(0.25)))[0], 0.35)
        XCTAssertLessThan(sample(try soft.apply(to: gray(0.75)))[0], 0.65)
        XCTAssertEqual(sample(try SceneAdjustments(blackPoint: 1).apply(to: gray(0.04)))[0], 0, accuracy: 0.0001)
        XCTAssertEqual(sample(try SceneAdjustments(blackPoint: -1).apply(to: gray(0)))[0], 0.12, accuracy: 0.0001)
        XCTAssertEqual(sample(try SceneAdjustments(blackPoint: 1).apply(to: gray(1)))[0], 1, accuracy: 0.0001)
        XCTAssertLessThan(abs(sample(try SceneAdjustments(blackPoint: -1).apply(to: gray(0.8)))[0] - 0.8), 0.002)
    }
    func testSaturationAndVibrancePreserveLuminanceNeutralsAndGamut() throws {
        let input = color(0.6, 0.35, 0.2)
        let monochrome = sample(try SceneAdjustments(saturation: -1, vibrance: 1).apply(to: input))
        XCTAssertEqual(monochrome[0], monochrome[1], accuracy: 0.0001)
        XCTAssertEqual(monochrome[1], monochrome[2], accuracy: 0.0001)
        let expected: Float = 0.6 * 0.2126 + 0.35 * 0.7152 + 0.2 * 0.0722
        for recipe in [SceneAdjustments(saturation: 1), SceneAdjustments(vibrance: 1), SceneAdjustments(saturation: -1)] {
            let pixel = sample(try recipe.apply(to: input))
            XCTAssertEqual(pixel[0] * 0.2126 + pixel[1] * 0.7152 + pixel[2] * 0.0722, expected, accuracy: 0.0001)
            XCTAssertTrue(pixel.allSatisfy { $0.isFinite && (0...1).contains($0) })
            let neutral = sample(try recipe.apply(to: gray(0.4)))
            for channel in 0..<3 { XCTAssertEqual(neutral[channel], 0.4, accuracy: 0.0001) }
            let saturated = sample(try recipe.apply(to: color(1, 0, 0)))
            XCTAssertTrue(saturated.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
        let muted = color(0.35, 0.4, 0.5), vivid = color(0.1, 0.2, 0.9)
        let mutedGain = colorfulness(sample(try SceneAdjustments(vibrance: 1).apply(to: muted))) - colorfulness(sample(muted))
        let vividGain = colorfulness(sample(try SceneAdjustments(vibrance: 1).apply(to: vivid))) - colorfulness(sample(vivid))
        XCTAssertGreaterThan(mutedGain, 0.1)
        XCTAssertGreaterThan(mutedGain, vividGain)
        let warm = color(0.5, 0.425, 0.35), cool = color(0.35, 0.425, 0.5)
        let warmGain = colorfulness(sample(try SceneAdjustments(vibrance: 1).apply(to: warm))) - colorfulness(sample(warm))
        let coolGain = colorfulness(sample(try SceneAdjustments(vibrance: 1).apply(to: cool))) - colorfulness(sample(cool))
        XCTAssertGreaterThan(coolGain, warmGain)
    }
    func testContrastAndBlackPointCombinedRampIsMonotonicAtExtremes() throws {
        let width = 257
        let rgba: [Float] = (0..<width).flatMap { i in
            let x = Float(i) / Float(width - 1); return [x, x, x, 1]
        }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: 1), format: .RGBAf, colorSpace: nil)
        for contrast in [-1.0, 1.0] {
            for blackPoint in [-1.0, 1.0] {
                let output = try SceneAdjustments(contrast: contrast, blackPoint: blackPoint, saturation: 1, vibrance: 1).apply(to: image)
                var pixels = [Float](repeating: 0, count: width * 4)
                pixels.withUnsafeMutableBytes { sampleContext.render(output, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: image.extent, format: .RGBAf, colorSpace: nil) }
                let ramp = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
                XCTAssertTrue(ramp.allSatisfy { $0.isFinite && (0...1).contains($0) })
                XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $1 >= $0 })
                XCTAssertEqual(ramp.last!, 1, accuracy: 0.0001)
            }
        }
    }
    func testSourceBalanceUsesLinearStopsAndKeepsLUTInputEncoding() throws {
        let original = gray(0.48827245852686763) // Apple Log encoding of 18% gray.
        XCTAssertTrue(try SceneAdjustments.neutral.applyingBalance(to: original, logEncoded: true) === original)
        let bright = sample(try SceneAdjustments(exposure: 0.5).applyingBalance(to: original, logEncoded: true))[0]
        let expected = 0.08550479 * log2(0.36 + 0.00964052) + 0.69336945
        XCTAssertEqual(bright, Float(expected), accuracy: 0.0001)
        let whiteBalance = sample(try SceneAdjustments(warmth: 1).applyingBalance(to: original, logEncoded: true))
        XCTAssertGreaterThan(whiteBalance[0], whiteBalance[2])
        let white = sample(try SceneAdjustments(exposure: 0.5).applyingBalance(to: gray(1), logEncoded: true))[0]
        XCTAssertGreaterThan(white, 1, "Do not clamp before a correcting exposure or the LUT")
        let standard = sample(try SceneAdjustments(exposure: 0.5).applyingBalance(to: gray(0.5), logEncoded: false))[0]
        let linear = pow((0.5 + 0.099) / 1.099, 1 / 0.45)
        XCTAssertEqual(standard, Float(1.099 * pow(linear * 2, 0.45) - 0.099), accuracy: 0.0001)
    }
    func testBalancePrecedesLUTAndFinishingFollowsItWithoutChangingSources() throws {
        var values: [Float] = []
        for b in 0...1 { for g in 0...1 { for r in 0...1 { values += [Float(r) * 2, Float(g) * 2, Float(b) * 2, 1] } } }
        let cube = ColorCube(name: "Bright look", dimension: 2, rgba: values.withUnsafeBytes { Data($0) })
        let input = gray(0.6), recipe = SceneAdjustments(exposure: -1, contrast: 0.2, blackPoint: -0.1, saturation: 0.3, vibrance: 0.4)
        let instruction = ColorInstruction(range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)),
            trackID: 1, transform: .identity, cube: cube, adjustments: recipe)
        let expected = try recipe.applyingFinishing(to: cube.apply(to: recipe.applyingBalance(to: input, logEncoded: true)))
        XCTAssertEqual(sample(try instruction.applyingColor(to: input)), sample(expected))
        var legacy = recipe; legacy.pipelineVersion = 1
        let oldInstruction = ColorInstruction(range: instruction.timeRange, trackID: 1, transform: .identity, cube: cube, adjustments: legacy)
        XCTAssertEqual(sample(try oldInstruction.applyingColor(to: input)), sample(try legacy.apply(to: cube.apply(to: input))))
        XCTAssertLessThan(sample(try instruction.applyingColor(to: input))[0], sample(try oldInstruction.applyingColor(to: input))[0])
        XCTAssertEqual(sample(input)[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(cube.rgba, values.withUnsafeBytes { Data($0) })
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
        let recipe = SceneAdjustments(exposure: 0.5, warmth: 0.4, tint: -0.3, brightness: 0.2, brilliance: 0.3, pushPull: -0.2, pipelineVersion: 1)
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
        XCTAssertEqual(sample(try all.apply(to: gray(1)))[0], 0.7, accuracy: 0.0001)
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

extension SceneAdjustmentsTests {
    func testExposureUsesStopsAndIsContinuousAtZero() throws {
        let input = gray(0.2)
        let up = sample(try SceneAdjustments(exposure: 0.5).apply(to: input))[0]
        let down = sample(try SceneAdjustments(exposure: -0.5).apply(to: input))[0]
        // Rec.709 decode(.2)≈.0554: +1 stop ≈.308 and −1 stop ≈.120.
        XCTAssertEqual(up, 0.308, accuracy: 0.005)
        XCTAssertEqual(down, 0.120, accuracy: 0.005)
        let nearZero = sample(try SceneAdjustments(exposure: 0.00001).apply(to: gray(1)))[0]
        XCTAssertEqual(nearZero, 1, accuracy: 0.001)
    }
    func testNewBasicsPersistAndHaveVisibleIndependentResponses() throws {
        let old = try JSONDecoder().decode(SceneAdjustments.self, from: Data("{}".utf8))
        XCTAssertEqual(old, .neutral)
        let recipe = SceneAdjustments(contrast: 0.4, blackPoint: 0.3, whitePoint: -0.2, saturation: 0.6, vibrance: 0.5)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(recipe)), recipe)
        XCTAssertLessThan(sample(try SceneAdjustments(contrast: 1).apply(to: gray(0.2)))[0], 0.1)
        XCTAssertLessThan(sample(try SceneAdjustments(blackPoint: 1).apply(to: gray(0.04)))[0], 0.01)
        XCTAssertGreaterThan(sample(try SceneAdjustments(blackPoint: -1).apply(to: gray(0)))[0], 0.1)
        XCTAssertLessThan(sample(try SceneAdjustments(whitePoint: -1).apply(to: gray(1)))[0], 0.8)
        let color = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let mono = sample(try SceneAdjustments(saturation: -1).apply(to: color))
        XCTAssertEqual(mono[0], mono[1], accuracy: 0.0001)
        XCTAssertEqual(mono[1], mono[2], accuracy: 0.0001)
        let vivid = sample(try SceneAdjustments(vibrance: 1).apply(to: color))
        XCTAssertGreaterThan(vivid[2] - vivid[0], 0.3)
        for key in [\SceneAdjustments.contrast, \.blackPoint, \.whitePoint, \.saturation, \.vibrance] {
            var invalid = SceneAdjustments(); invalid[keyPath: key] = .nan
            XCTAssertThrowsError(try invalid.validate())
        }
    }
    func testNeutralDetentHasHysteresisAndReleasesInBothDirections() {
        var detent = AdjustmentDetent()
        XCTAssertEqual(detent.value(0.01, neutral: 0, step: 0.01), 0)
        XCTAssertEqual(detent.value(0.02, neutral: 0, step: 0.01), 0)
        XCTAssertEqual(detent.value(0.03, neutral: 0, step: 0.01), 0.03)
        XCTAssertEqual(detent.value(-0.01, neutral: 0, step: 0.01), 0)
        XCTAssertEqual(detent.value(-0.03, neutral: 0, step: 0.01), -0.03)
    }
}


extension SceneAdjustmentsTests {
    func testTonalJoinsDoNotCreateContrastSeams() throws {
        let controls: [(WritableKeyPath<SceneAdjustments, Double>, Double)] = [(\.shadows, 0.55), (\.highlights, 0.45), (\.brilliance, 0.5)]
        for (key, join) in controls {
            for direction in [-1.0, 1.0] {
                var recipe = SceneAdjustments(); recipe[keyPath: key] = direction
                let a = sample(try recipe.apply(to: gray(CGFloat(join - 0.001))))[0]
                let b = sample(try recipe.apply(to: gray(CGFloat(join))))[0]
                let c = sample(try recipe.apply(to: gray(CGFloat(join + 0.001))))[0]
                // The production CI context uses half-float intermediate textures.
                // Allow one half-float ULP near white (0.0005), below an 8-bit
                // display step, while rejecting flat joins and root-curve spikes.
                XCTAssertEqual(b - a, c - b, accuracy: 0.0005, "Tonal joins should keep a continuous slope")
                XCTAssertEqual(b - a, 0.001, accuracy: 0.0005, "The lower side of a join should retain unit slope")
                XCTAssertEqual(c - b, 0.001, accuracy: 0.0005, "The upper side of a join should retain unit slope")
            }
        }
    }
}
