import XCTest
import CoreImage
import CoreVideo
@testable import HomeMovie

final class LightToolsTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private func gray(_ level: Double) -> CIImage {
        CIImage(color: CIColor(red: CGFloat(level), green: CGFloat(level), blue: CGFloat(level)))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    private func pixel(_ image: CIImage) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        result.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        }
        return result
    }
    func testLightToolsRoundTripLegacyDefaultsAndValidation() throws {
        let old = try JSONDecoder().decode(SceneAdjustments.self, from: Data(#"{"blackPoint":-0.3,"pipelineVersion":2}"#.utf8))
        XCTAssertEqual(old.fade, 0); XCTAssertEqual(old.curve, .neutral)
        XCTAssertEqual(old.blackPoint, -0.3); XCTAssertEqual(old.pipelineVersion, 2)
        var recipe = old; recipe.fade = 0.65; recipe.curve = LightCurve(shadows: 0.1, midtones: 0.6, highlights: 0.9)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(recipe)), recipe)
        for value in [-0.01, 1.01, Double.nan, .infinity] {
            var bad = recipe; bad.fade = value; XCTAssertThrowsError(try bad.validate())
        }
        for invalid in [LightCurve(shadows: .nan), LightCurve(shadows: 0.6), LightCurve(highlights: 1.1), LightCurve(midtones: 0.75)] {
            var bad = recipe; bad.curve = invalid; XCTAssertThrowsError(try bad.validate())
        }
    }
    func testFadeIsAnOutputFloorWithStableWhitesAndOrderedTones() throws {
        var recipe = SceneAdjustments.neutral; recipe.fade = 1
        XCTAssertTrue(recipe.isActive)
        var previous: Float = -1
        for i in 0...16 {
            let level = Double(i) / 16
            let result = pixel(try recipe.applyingFinishing(to: gray(level)))
            XCTAssertEqual(result[0], Float(0.22 + level * 0.78), accuracy: 0.001)
            XCTAssertEqual(result[0], result[1], accuracy: 0.0001)
            XCTAssertEqual(result[1], result[2], accuracy: 0.0001)
            XCTAssertGreaterThan(result[0], previous); previous = result[0]
        }
        XCTAssertEqual(pixel(try recipe.applyingFinishing(to: gray(1)))[0], 1, accuracy: 0.001)
        XCTAssertEqual(pixel(try LightCurve.neutral.apply(to: gray(0.4), fade: 0)), pixel(gray(0.4)))
        // The existing negative Black Point remains a localized toe, while Fade
        // raises the completed image's floor without changing older recipes.
        let toe = pixel(try SceneAdjustments(blackPoint: -1).apply(to: gray(0.5)))[0]
        let faded = pixel(try recipe.applyingFinishing(to: gray(0.5)))[0]
        XCTAssertGreaterThan(faded - toe, 0.07)
    }
    func testCurvesStayMonotoneAndGraphMatchesRenderedLuminance() throws {
        for curve in [LightCurve.neutral, LightCurve(shadows: 0.02, midtones: 0.12, highlights: 0.95),
                      LightCurve(shadows: 0.45, midtones: 0.5, highlights: 0.55)] {
            try curve.validate()
            var previous = -1.0
            for i in 0...128 {
                let output = curve.output(at: Double(i) / 128)
                XCTAssertTrue((0...1).contains(output))
                XCTAssertGreaterThanOrEqual(output, previous); previous = output
            }
            for i in 0...16 {
                let level = Double(i) / 16
                let rendered = pixel(try curve.apply(to: gray(level), fade: 0))[0]
                XCTAssertEqual(Double(rendered), curve.output(at: level), accuracy: 0.001)
            }
        }
        var constrained = LightCurve.neutral
        constrained.move(1, to: 1); constrained.move(3, to: 0)
        try constrained.validate()
        XCTAssertLessThan(constrained.shadows, constrained.midtones)
        XCTAssertGreaterThan(constrained.highlights, constrained.midtones)
    }
    func testHistogramCountsLimitsAndHonorsPaddedRowsAndAlpha() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image))
        let rowBytes = CVPixelBufferGetBytesPerRow(image)
        memset(base, 0, rowBytes * 2)
        let pixels: [UInt8] = [0,0,0,255, 255,255,255,255, 128,128,128,255, 0,0,255,255]
        pixels.withUnsafeBytes { base.copyMemory(from: $0.baseAddress!, byteCount: 16) }
        CVPixelBufferUnlockBaseAddress(image, [])
        let histogram = try XCTUnwrap(ReviewHistogram.measure(image))
        XCTAssertEqual(histogram.samples, 4); XCTAssertEqual(histogram.bins.reduce(0, +), 4)
        XCTAssertEqual(histogram.blackFraction, 0.25); XCTAssertEqual(histogram.whiteFraction, 0.5)
        XCTAssertEqual(histogram.bins[0], 1); XCTAssertEqual(histogram.bins[63], 1)
        XCTAssertEqual(histogram.bins[32], 1); XCTAssertEqual(histogram.bins[13], 1)
    }
    func testHistogramMeasuresTheEditedImageRatherThanTheSource() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let destination = try XCTUnwrap(buffer)
        let source = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        context.render(source, to: destination, bounds: source.extent, colorSpace: nil)
        XCTAssertEqual(try XCTUnwrap(ReviewHistogram.measure(destination)).blackFraction, 1)
        var recipe = SceneAdjustments.neutral; recipe.fade = 1
        context.render(try recipe.applyingFinishing(to: source), to: destination, bounds: source.extent, colorSpace: nil)
        let edited = try XCTUnwrap(ReviewHistogram.measure(destination))
        XCTAssertEqual(edited.blackFraction, 0); XCTAssertEqual(edited.whiteFraction, 0)
        XCTAssertEqual(edited.bins[14], edited.samples)
    }
}
