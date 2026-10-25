import XCTest
import AVFoundation
import CoreImage
import UIKit
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
        XCTAssertLessThan(colorfulness(muted), 0.002)
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
    private func hslLuminance(_ pixel: [Float]) -> Float {
        let linear = pixel.prefix(3).map { value -> Float in
            value < 0.081 ? value / 4.5 : pow((value + 0.099) / 1.099, 1 / 0.45)
        }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    func testHSLHueAndSaturationPreserveMeasuredLuminance() throws {
        for input in [color(0.8, 0.2, 0.2), color(0.45, 0.3, 0.2), color(0.2, 0.4, 0.85)] {
            let original = hslLuminance(sample(input))
            for amount in [-1.0, -0.5, 0.5, 1.0] {
                for path in [\HSLValues.hue, \.saturation] {
                    var hsl = HSLAdjustments()
                    for band in HSLBand.allCases { hsl[band][keyPath: path] = amount }
                    let output = sample(try hsl.apply(to: input))
                    XCTAssertEqual(hslLuminance(output), original, accuracy: 0.003)
                    XCTAssertTrue(output.prefix(3).allSatisfy { $0.isFinite && (0...1).contains($0) })
                }
            }
        }
    }
    func testHSLSaturationDoesNotInventStrongColorInMutedPixels() throws {
        let input = color(0.52, 0.48, 0.48)
        var hsl = HSLAdjustments(); hsl[.red].saturation = 1
        let output = sample(try hsl.apply(to: input))
        // The former HSL saturation-to-one response made this almost pure red.
        XCTAssertLessThan(output[0] - output[1], 0.1)
        XCTAssertGreaterThan(output[0] - output[1], 0.04)
        let neutralHighlight = color(0.96, 0.955, 0.955)
        let unchanged = sample(try hsl.apply(to: neutralHighlight))
        for i in 0..<3 { XCTAssertEqual(unchanged[i], sample(neutralHighlight)[i], accuracy: 0.002) }
    }
    func testHSLLightnessRetainsColorAndOrdersBrightness() throws {
        let input = color(0.7, 0.3, 0.2), original = sample(input)
        var previous: Float = -1
        for amount in [-1.0, -0.5, 0, 0.5, 1.0] {
            var hsl = HSLAdjustments()
            for band in HSLBand.allCases { hsl[band].lightness = amount }
            let output = sample(try hsl.apply(to: input))
            let level = hslLuminance(output)
            XCTAssertGreaterThan(level, previous); previous = level
            XCTAssertGreaterThan(output[0], output[1]); XCTAssertGreaterThan(output[1], output[2])
            XCTAssertGreaterThan(colorfulness(output), colorfulness(original) * 0.75)
        }
    }
    func testHSLAllBandBoundariesAreContinuousAndUnselectedPixelsStayExact() throws {
        for band in HSLBand.allCases {
            var hsl = HSLAdjustments(); hsl[band] = HSLValues(hue: 0.8, saturation: 0.7, lightness: -0.4)
            var previous: [Float]?
            for step in 0...720 {
                let input = CIImage(color: CIColor(color: UIColor(hue: CGFloat(step) / 720,
                    saturation: 0.6, brightness: 0.75, alpha: 1)))
                    .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                let output = sample(try hsl.apply(to: input))
                XCTAssertTrue(output.prefix(3).allSatisfy { $0.isFinite && (0...1).contains($0) })
                if let previous { for i in 0..<3 { XCTAssertLessThan(abs(output[i] - previous[i]), 0.035) } }
                previous = output
            }
        }
        var hsl = HSLAdjustments(); hsl[.red].hue = 1
        let extendedBlue = color(0.1, 0.1, 1.2)
        XCTAssertEqual(sample(try hsl.apply(to: extendedBlue)), sample(extendedBlue))
    }
    func testHSLRespectsPremultipliedAlpha() throws {
        var hsl = HSLAdjustments(); hsl[.red] = HSLValues(hue: 0.5, saturation: 0.4, lightness: 0.2)
        let opaque = sample(try hsl.apply(to: color(0.8, 0.2, 0.2)))
        let transparent = CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let output = sample(try hsl.apply(to: transparent))
        for i in 0..<3 { XCTAssertEqual(output[i], opaque[i] * 0.5, accuracy: 0.003) }
        XCTAssertEqual(output[3], 0.5, accuracy: 0.001)
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
        let deepShadow = sample(try SceneAdjustments(blackPoint: 1).apply(to: gray(0.04)))[0]
        XCTAssertGreaterThan(deepShadow, 0, "Deepening black must retain nonzero shadow detail")
        XCTAssertLessThan(deepShadow, 0.01)
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
        let linear = pow((0.5 + 0.0992968268) / 1.0992968268, 1 / 0.45)
        XCTAssertEqual(standard, Float(1.0992968268 * pow(linear * 2, 0.45) - 0.0992968268), accuracy: 0.0001)
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
    func testStandardWhiteBalanceAlonePreservesBrightChannelRatiosInsideSDR() throws {
        func linear(_ x: Double) -> Double { x < 0.081 ? x / 4.5 : pow((x + 0.099) / 1.099, 1 / 0.45) }
        let original = [0.96, 0.89, 0.81]
        for w in [-1.0, 0, 1] {
            for t in [-1.0, 0, 1] where w != 0 || t != 0 {
                var recipe = SceneAdjustments.neutral; recipe.warmth = w; recipe.tint = t
                let result = sample(try recipe.applyingBalance(to: color(original[0], original[1], original[2]), logEncoded: false))
                XCTAssertTrue(result.prefix(3).allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.0001 })
                let gains = [exp2(2 * (0.22 * w + 0.13 * t)), exp2(2 * (0.025 * w - 0.16 * t)), exp2(2 * (-0.245 * w + 0.13 * t))]
                let expected = zip(original, gains).map { linear($0.0) * $0.1 }
                XCTAssertEqual(linear(Double(result[0])) / linear(Double(result[1])), expected[0] / expected[1], accuracy: 0.015)
                XCTAssertEqual(linear(Double(result[2])) / linear(Double(result[1])), expected[2] / expected[1], accuracy: 0.015)
            }
        }
    }
    func testStandardWhiteBalanceApproachesNeutralContinuouslyAndPreservesLogOrdering() throws {
        let source = color(0.96, 0.89, 0.81)
        for amount in [-0.0001, 0.0001] {
            var recipe = SceneAdjustments.neutral; recipe.warmth = amount
            let result = sample(try recipe.applyingBalance(to: source, logEncoded: false))
            for c in 0..<3 { XCTAssertEqual(result[c], sample(source)[c], accuracy: 0.002) }
        }
        var recipe = SceneAdjustments.neutral; recipe.warmth = 0.5
        let log = sample(try recipe.applyingBalance(to: color(0.7, 0.7, 0.7), logEncoded: true))
        XCTAssertGreaterThan(log[0], log[2], "Log balance must retain its source-encoded ordering")
    }

}


extension SceneAdjustmentsTests {
    private func appleLog(_ linear: Double) -> Double {
        if linear >= 0.01 { return 0.08550479 * log2(linear + 0.00964052) + 0.69336945 }
        return linear >= -0.05641088 ? 47.28711236 * pow(linear + 0.05641088, 2) : 0
    }
    private func logGray(_ linear: Double) -> CIImage { gray(CGFloat(appleLog(linear))) }
    private func logLinear(_ code: Float) -> Double {
        let join = 47.28711236 * pow(0.01 + 0.05641088, 2)
        return Double(code) >= join ? exp2((Double(code) - 0.69336945) / 0.08550479) - 0.00964052
            : sqrt(max(Double(code), 0) / 47.28711236) - 0.05641088
    }
    func testScenePrimariesAnchorMiddleGrayAndPreserveLogHeadroom() throws {
        for contrast in [-1.0, -0.5, 0.5, 1] {
            let recipe = SceneAdjustments(shadows: 1, highlights: -1, contrast: contrast)
            let middle = sample(try recipe.applyingBalance(to: logGray(0.18), logEncoded: true))[0]
            XCTAssertEqual(logLinear(middle), 0.18, accuracy: 0.0003)
        }
        let source = logGray(2)
        let recovered = sample(try SceneAdjustments(highlights: -1).applyingBalance(to: source, logEncoded: true))[0]
        XCTAssertLessThan(logLinear(recovered), 1)
        XCTAssertGreaterThan(logLinear(recovered), 0.18)
        let lifted = sample(try SceneAdjustments(shadows: 1).applyingBalance(to: logGray(0.005), logEncoded: true))[0]
        XCTAssertEqual(logLinear(lifted), 0.02, accuracy: 0.0001)
        let expanded = sample(try SceneAdjustments(contrast: 1).applyingBalance(to: logGray(16), logEncoded: true))[0]
        XCTAssertGreaterThan(expanded, 1, "Keep scene headroom before the LUT instead of clipping RGB channels")
    }
    func testLogPrimaryCombinationPreservesChannelRatiosAndNeutralAlpha() throws {
        let levels = [0.5, 0.25, 0.125]
        let source = color(CGFloat(appleLog(levels[0])), CGFloat(appleLog(levels[1])), CGFloat(appleLog(levels[2])))
        let recipe = SceneAdjustments(exposure: 0.3, shadows: 0.8, highlights: -0.6, contrast: 0.7)
        let output = sample(try recipe.applyingBalance(to: source, logEncoded: true)).prefix(3).map(logLinear)
        XCTAssertEqual(output[0] / output[1], 2, accuracy: 0.02)
        XCTAssertEqual(output[1] / output[2], 2, accuracy: 0.02)
        let transparent = CIImage(color: CIColor(red: 0.7, green: 0.5, blue: 0.4, alpha: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let opaque = sample(try recipe.applyingBalance(to: color(0.7, 0.5, 0.4), logEncoded: true))
        let half = sample(try recipe.applyingBalance(to: transparent, logEncoded: true))
        for c in 0..<3 { XCTAssertEqual(half[c], opaque[c] * 0.5, accuracy: 0.002) }
        XCTAssertEqual(half[3], 0.5, accuracy: 0.001)
    }
    func testLogPrimariesRetainOrderingAcrossAllZoneBoundariesAndExtremes() throws {
        let levels = (0...256).map { 0.18 * exp2(Double($0) / 16 - 12) }
        let pixels: [Float] = levels.flatMap { value in
            let encoded = Float(appleLog(value)); return [encoded, encoded, encoded, 1]
        }
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: pixels.count * 4,
            size: CGSize(width: levels.count, height: 1), format: .RGBAf, colorSpace: nil)
        for shadow in [-1.0, 0, 1] { for highlight in [-1.0, 0, 1] { for contrast in [-1.0, 0, 1] {
            let recipe = SceneAdjustments(shadows: shadow, highlights: highlight, contrast: contrast)
            let result = try recipe.applyingBalance(to: image, logEncoded: true)
            var output = [Float](repeating: 0, count: pixels.count)
            output.withUnsafeMutableBytes { sampleContext.render(result, toBitmap: $0.baseAddress!, rowBytes: pixels.count * 4,
                bounds: image.extent, format: .RGBAf, colorSpace: nil) }
            let ramp = stride(from: 0, to: output.count, by: 4).map { output[$0] }
            XCTAssertTrue(ramp.allSatisfy { $0.isFinite })
            XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $1 >= $0 }, "Source tone ordering must not reverse")
        } } }
    }
    func testPrimaryControlsRunBeforeTheLookExactlyOnce() throws {
        let image = logGray(2)
        // A bounded encoding-to-display test LUT. Editing after it cannot recover
        // the two bright levels once the source input is clamped by the look.
        var samples: [Float] = []
        for b in 0...1 { for g in 0...1 { for r in 0...1 { samples += [Float(r), Float(g), Float(b), 1] } } }
        let ceiling = Float(appleLog(1))
        let cube = ColorCube(name: "Bounded", dimension: 2, rgba: samples.withUnsafeBytes { Data($0) }, maximum: [ceiling, ceiling, ceiling])
        let recipe = SceneAdjustments(shadows: 0.5, highlights: -1)
        let instruction = ColorInstruction(range: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)),
            trackID: 1, transform: .identity, cube: cube, adjustments: recipe)
        let balanced = try recipe.applyingBalance(to: image, logEncoded: true)
        XCTAssertEqual(sample(try cube.apply(to: image))[0], 1, accuracy: 0.001)
        XCTAssertEqual(sample(try cube.apply(to: logGray(3)))[0], 1, accuracy: 0.001)
        let recoveredA = sample(try instruction.applyingColor(to: image))[0]
        let recoveredB = sample(try instruction.applyingColor(to: logGray(3)))[0]
        XCTAssertLessThan(recoveredA, recoveredB)
        XCTAssertLessThan(recoveredB, 1)
        XCTAssertEqual(sample(try recipe.applyingFinishing(to: balanced)), sample(balanced), "Do not apply source controls twice")
        XCTAssertEqual(sample(try instruction.applyingColor(to: image)), sample(try cube.apply(to: balanced)))
        var legacy = recipe; legacy.pipelineVersion = 1
        XCTAssertTrue(try legacy.applyingBalance(to: image, logEncoded: true) === image)
    }
    func testDisplayBrightnessAndCurvesPreserveLinearColorRatios() throws {
        let source = color(0.6, 0.35, 0.2)
        func linear(_ x: Float) -> Float { x < 0.081 ? x / 4.5 : pow((x + 0.099) / 1.099, 1 / 0.45) }
        let original = sample(source).prefix(3).map(linear)
        var curveRecipe = SceneAdjustments()
        curveRecipe.curve.points = [.init(x: 0, y: 0), .init(x: 0.5, y: 0.6), .init(x: 1, y: 1)]
        for recipe in [SceneAdjustments(brightness: 0.5), SceneAdjustments(brilliance: 0.5), curveRecipe] {
            let output = sample(try recipe.applyingFinishing(to: source)).prefix(3).map(linear)
            XCTAssertEqual(output[0] / output[1], original[0] / original[1], accuracy: 0.02)
            XCTAssertEqual(output[1] / output[2], original[1] / original[2], accuracy: 0.02)
        }
    }
    func testBlackAndWhiteControlsKeepDetailAtBothEndsOfTheRamp() throws {
        let black = SceneAdjustments(blackPoint: 1), white = SceneAdjustments(whitePoint: 1)
        let low = try [0.005, 0.01, 0.02, 0.04].map { sample(try black.applyingFinishing(to: gray($0)))[0] }
        let high = try [0.92, 0.96, 0.98, 0.99].map { sample(try white.applyingFinishing(to: gray($0)))[0] }
        XCTAssertGreaterThan(low[0], 0); XCTAssertLessThan(high.last!, 1)
        XCTAssertEqual(sample(try black.applyingFinishing(to: gray(0.8)))[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(sample(try white.applyingFinishing(to: gray(0.2)))[0], 0.2, accuracy: 0.0001)
        XCTAssertTrue(zip(low, low.dropFirst()).allSatisfy { $1 > $0 })
        XCTAssertTrue(zip(high, high.dropFirst()).allSatisfy { $1 > $0 })
    }
    func testBrillianceDoesNotDependOnNeighboringPixels() throws {
        let pixels: [Float] = [0,0,0,1, 0.4,0.4,0.4,1, 1,1,1,1]
        let source = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: 48,
            size: CGSize(width: 3, height: 1), format: .RGBAf, colorSpace: nil)
        let recipe = SceneAdjustments(brilliance: 1)
        let output = try recipe.applyingFinishing(to: source)
        let center = output.transformed(by: CGAffineTransform(translationX: -1, y: 0))
        let uniform = try recipe.applyingFinishing(to: gray(0.4))
        for c in 0..<4 { XCTAssertEqual(sample(center)[c], sample(uniform)[c], accuracy: 0.001) }
    }
}


extension SceneAdjustmentsTests {
    func testFinishingRampDoesNotReverseAtTransferCurveJoins() throws {
        let width = 4097
        let pixels: [Float] = (0..<width).flatMap { i in
            let x = Float(i) / Float(width - 1); return [x, x, x, 1]
        }
        let source = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: 1), format: .RGBAf, colorSpace: nil)
        let recipe = SceneAdjustments(brightness: -1, brilliance: -1, pushPull: -1, blackPoint: 1, whitePoint: -1)
        let output = try recipe.applyingFinishing(to: source)
        var values = [Float](repeating: 0, count: pixels.count)
        values.withUnsafeMutableBytes { sampleContext.render(output, toBitmap: $0.baseAddress!, rowBytes: width * 16,
            bounds: source.extent, format: .RGBAf, colorSpace: nil) }
        let ramp = stride(from: 0, to: values.count, by: 4).map { values[$0] }
        XCTAssertTrue(ramp.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(zip(ramp, ramp.dropFirst()).allSatisfy { $1 >= $0 - 0.000002 },
            "The former rounded transfer join reversed brightness by about 0.0002")
    }
}
