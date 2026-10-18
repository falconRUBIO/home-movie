import XCTest
import AVFoundation
import CoreImage
@testable import HomeMovie

final class FilmEffectsTests: XCTestCase {
    private func pixels(_ image: CIImage) -> [Float] {
        let bounds = image.extent
        var result = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        result.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        return result
    }
    func testLegacyMovieLoadsWithEffectsOff() throws {
        let old = Movie(name: "Before Film Effects", format: .landscape)
        let data = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(Movie.self, from: data)
        XCTAssertFalse(restored.exportEffects.isActive)
        XCTAssertEqual(restored.exportEffects.summary, "Off")
    }
    func testDisabledRendererIsExactBypass() throws {
        let input = CIImage(color: CIColor(red: 0.3, green: 0.5, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let output = try FilmEffectsRenderer().render(input, settings: .off, time: .zero)
        XCTAssertTrue(output === input)
    }
    func testSettingsRejectInvalidDataAndCacheChanges() throws {
        var settings = FilmEffectsSettings.off
        let original = settings.cacheIdentity
        settings.grainEnabled = true
        XCTAssertNotEqual(settings.cacheIdentity, original)
        settings.grainAmount = .nan
        XCTAssertThrowsError(try settings.validate())
        settings.grainAmount = 0.25; settings.bloomSpread = 2
        XCTAssertThrowsError(try settings.validate())
        settings.bloomSpread = 0.35; settings.version = 99
        XCTAssertThrowsError(try settings.validate())
    }
    func testFrameSeedUsesTimelineAndSurvivesSeeking() {
        let seed: UInt32 = 104729
        let a = FilmEffectsSettings.frameSeed(time: CMTime(value: 600, timescale: 600), seed: seed)
        let b = FilmEffectsSettings.frameSeed(time: CMTime(value: 30, timescale: 30), seed: seed)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, FilmEffectsSettings.frameSeed(time: CMTime(value: 31, timescale: 30), seed: seed))
        XCTAssertEqual(a, FilmEffectsSettings.frameSeed(time: CMTime(value: 600, timescale: 600), seed: seed))
    }
    func testMetalGrainIsDeterministicAnimatedAndNeutral() throws {
        let input = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        var settings = FilmEffectsSettings.off; settings.grainEnabled = true; settings.grainAmount = 1
        let renderer = FilmEffectsRenderer()
        let a = pixels(try renderer.render(input, settings: settings, time: .zero))
        let repeated = pixels(try renderer.render(input, settings: settings, time: .zero))
        let next = pixels(try renderer.render(input, settings: settings, time: CMTime(value: 1, timescale: 30)))
        XCTAssertEqual(a, repeated); XCTAssertNotEqual(a, next)
        let red = stride(from: 0, to: a.count, by: 4).map { a[$0] }
        XCTAssertGreaterThan((red.max() ?? 0) - (red.min() ?? 0), 0.00001)
        XCTAssertEqual(red.reduce(0, +) / Float(red.count), 0.5, accuracy: 0.002)
        for index in stride(from: 0, to: a.count, by: 4) {
            XCTAssertEqual(a[index], a[index + 1], accuracy: 0.000001)
            XCTAssertEqual(a[index], a[index + 2], accuracy: 0.000001)
        }
    }
    func testOpticsDoNotGradeNonHighlights() throws {
        let input = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        var settings = FilmEffectsSettings.off; settings.halationEnabled = true; settings.bloomEnabled = true
        let result = pixels(try FilmEffectsRenderer().render(input, settings: settings, time: .zero))
        XCTAssertEqual(result[0], 0.3, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.4, accuracy: 0.001)
        XCTAssertEqual(result[2], 0.2, accuracy: 0.001)
    }
    func testBloomAndHalationWorkIndependently() throws {
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let background = CIImage(color: CIColor(red: 0.04, green: 0.04, blue: 0.04)).cropped(to: bounds)
        let light = CIImage(color: .white).cropped(to: CGRect(x: 110, y: 110, width: 36, height: 36))
        let input = light.composited(over: background).cropped(to: bounds)
        var bloom = FilmEffectsSettings.off; bloom.bloomEnabled = true; bloom.bloomAmount = 1; bloom.bloomSpread = 0.7
        var halation = FilmEffectsSettings.off; halation.halationEnabled = true; halation.halationAmount = 1; halation.halationSpread = 0.7
        let renderer = FilmEffectsRenderer()
        let b = pixels(try renderer.render(input, settings: bloom, time: .zero))
        let h = pixels(try renderer.render(input, settings: halation, time: .zero))
        let index = (128 * 256 + 108) * 4
        XCTAssertGreaterThan(b[index], 0.04)
        XCTAssertEqual(b[index], b[index + 1], accuracy: 0.001)
        XCTAssertGreaterThan(h[index], h[index + 1])
        XCTAssertGreaterThan(h[index + 1], h[index + 2])
        XCTAssertNotEqual(b, h)
    }
    func testOpticalControlsHaveVisibleResponseOnUnclippedHighlightsAndPreserveDarkAreas() throws {
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let base = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: bounds)
        let light = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
            .cropped(to: CGRect(x: 100, y: 100, width: 56, height: 56))
        let source = light.composited(over: base).cropped(to: bounds)
        let renderer = FilmEffectsRenderer()
        for halation in [false, true] {
            var settings = FilmEffectsSettings.off
            settings.bloomEnabled = !halation; settings.halationEnabled = halation
            settings.bloomAmount = 0.6; settings.halationAmount = 0.6
            settings.bloomSensitivity = 0.5; settings.halationSensitivity = 0.5
            settings.bloomSpread = 0.5; settings.halationSpread = 0.5
            let result = pixels(try renderer.render(source, settings: settings, time: .zero))
            let edge = (128 * 256 + 98) * 4
            XCTAssertGreaterThan(result[edge], 0.095, "Highlight diffusion should be visible at useful settings")
            if halation { XCTAssertGreaterThan(result[edge], result[edge + 1]) }
            else { XCTAssertEqual(result[edge], result[edge + 2], accuracy: 0.001) }
            XCTAssertEqual(result[(10 * 256 + 10) * 4], 0.08, accuracy: 0.003)
            let full = result[edge]
            settings.bloomAmount = 0.1; settings.halationAmount = 0.1
            let reduced = pixels(try renderer.render(source, settings: settings, time: .zero))
            XCTAssertGreaterThan(full, reduced[edge])
        }
    }

    func testOldEffectsRecipeDefaultsNewControlsOff() throws {
        let old = Data(#"{"version":1,"grainEnabled":true,"grainAmount":0.4,"seed":42}"#.utf8)
        let settings = try JSONDecoder().decode(FilmEffectsSettings.self, from: old)
        XCTAssertTrue(settings.grainEnabled)
        XCTAssertEqual(settings.grainAmount, 0.4)
        XCTAssertEqual(settings.seed, 42)
        XCTAssertFalse(settings.softnessEnabled)
        XCTAssertFalse(settings.rolloffEnabled)
        try settings.validate()
        XCTAssertEqual(try JSONDecoder().decode(FilmEffectsSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testNewControlsPersistValidateAndChangeCache() throws {
        var settings = FilmEffectsSettings.off
        settings.softnessEnabled = true; settings.softnessAmount = 0.6
        settings.rolloffEnabled = true; settings.rolloffAmount = 0.7
        XCTAssertTrue(settings.isActive)
        XCTAssertNotEqual(settings.cacheIdentity, FilmEffectsSettings.off.cacheIdentity)
        XCTAssertEqual(try JSONDecoder().decode(FilmEffectsSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.softnessAmount = .infinity
        XCTAssertThrowsError(try settings.validate())
        settings.softnessAmount = 0.6; settings.rolloffAmount = -0.1
        XCTAssertThrowsError(try settings.validate())
    }
    func testSoftnessReducesEdgeContrastAndKeepsFlatAreasUnchanged() throws {
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let dark = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: bounds)
        let light = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8))
            .cropped(to: CGRect(x: 128, y: 0, width: 128, height: 256))
        let source = light.composited(over: dark).cropped(to: bounds)
        var settings = FilmEffectsSettings.off; settings.softnessEnabled = true; settings.softnessAmount = 1
        let output = try FilmEffectsRenderer().render(source, settings: settings, time: .zero)
        XCTAssertEqual(output.extent, bounds)
        let result = pixels(output)
        XCTAssertGreaterThan(result[(128 * 256 + 127) * 4], 0.2)
        XCTAssertLessThan(result[(128 * 256 + 128) * 4], 0.8)
        XCTAssertEqual(result[(128 * 256 + 30) * 4], 0.2, accuracy: 0.001)
        XCTAssertEqual(result[(128 * 256 + 220) * 4], 0.8, accuracy: 0.001)
    }
    func testRolloffHasSmoothMonotonicShoulderAndPreservesShadows() throws {
        let bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        let renderer = FilmEffectsRenderer()
        var settings = FilmEffectsSettings.off; settings.rolloffEnabled = true; settings.rolloffAmount = 1
        var previous: Float = -1
        for step in 0...20 {
            let level = Float(step) / 20
            let source = CIImage(color: CIColor(red: CGFloat(level), green: CGFloat(level), blue: CGFloat(level))).cropped(to: bounds)
            let result = pixels(try renderer.render(source, settings: settings, time: .zero))
            XCTAssertGreaterThan(result[0], previous)
            XCTAssertEqual(result[0], result[1], accuracy: 0.000001)
            XCTAssertEqual(result[3], 1, accuracy: 0.000001)
            if level <= 0.55 { XCTAssertEqual(result[0], level, accuracy: 0.001) }
            if level >= 0.85 { XCTAssertLessThan(result[0], level - 0.02) }
            previous = result[0]
        }
        let source = CIImage(color: .white).cropped(to: bounds)
        settings.rolloffAmount = 0
        let bypass = try renderer.render(source, settings: settings, time: .zero)
        XCTAssertTrue(bypass === source)
    }
    func testGrainIsVisibleOnSaturatedColorsAndAllEffectsCombine() throws {
        let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        let source = CIImage(color: CIColor(red: 0.9, green: 0.4, blue: 0)).cropped(to: bounds)
        var settings = FilmEffectsSettings.off; settings.grainEnabled = true; settings.grainAmount = 1
        settings.grainSize = 2; settings.grainTexture = .coarse16
        let renderer = FilmEffectsRenderer()
        let grain = pixels(try renderer.render(source, settings: settings, time: .zero))
        let green = stride(from: 1, to: grain.count, by: 4).map { grain[$0] }
        XCTAssertGreaterThan((green.max() ?? 0) - (green.min() ?? 0), 0.01)
        settings.softnessEnabled = true; settings.rolloffEnabled = true
        settings.bloomEnabled = true; settings.halationEnabled = true
        let combined = pixels(try renderer.render(source, settings: settings, time: .zero))
        XCTAssertTrue(combined.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.001 })
        XCTAssertNotEqual(grain, combined)
    }

    func testEffectsSettingsPersistAndInvalidateExportRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root)
        _ = try await store.load()
        let movie = try await store.create(name: "Film", format: .landscape)
        var settings = FilmEffectsSettings.off; settings.grainEnabled = true; settings.grainTexture = .coarse16
        settings.softnessEnabled = true; settings.rolloffEnabled = true
        try await store.setFilmEffects(movieID: movie.id, settings: settings)
        let savedMovies = await store.snapshot()
        let saved = try XCTUnwrap(savedMovies.first)
        XCTAssertEqual(saved.revision, movie.revision + 1)
        XCTAssertEqual(saved.exportEffects, settings)
        let reopened = ProjectStore(root: root); _ = try await reopened.load()
        let restoredMovies = await reopened.snapshot()
        let restored = try XCTUnwrap(restoredMovies.first)
        XCTAssertEqual(restored.exportEffects, settings)
        try await store.setFilmEffects(movieID: movie.id, settings: settings)
        let unchangedMovies = await store.snapshot()
        let unchanged = try XCTUnwrap(unchangedMovies.first)
        XCTAssertEqual(unchanged.revision, saved.revision)
    }
}

extension FilmEffectsTests {
    func testLegacyEffectsDoNotSilentlyEnableNewEffects() throws {
        let old = try JSONDecoder().decode(FilmEffectsSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.sharpnessAmount, 0); XCTAssertEqual(old.vignetteAmount, 0)
        XCTAssertFalse(old.isActive)
        var settings = old; settings.sharpnessAmount = 0.5; settings.vignetteAmount = 0.6
        XCTAssertEqual(try JSONDecoder().decode(FilmEffectsSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertTrue(settings.isActive)
        settings.sharpnessAmount = 2
        XCTAssertThrowsError(try settings.validate())
    }
    func testVignetteProtectsCenterAndDarkensEdgesProgressively() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        var half = FilmEffectsSettings.off; half.vignetteAmount = 0.5
        var full = half; full.vignetteAmount = 1
        let renderer = FilmEffectsRenderer()
        let a = pixels(try renderer.render(source, settings: half, time: .zero))
        let b = pixels(try renderer.render(source, settings: full, time: .zero))
        XCTAssertEqual(b[(64 * 128 + 64) * 4], 0.5, accuracy: 0.001)
        XCTAssertLessThan(b[0], a[0]); XCTAssertLessThan(a[0], 0.45)
        XCTAssertEqual(b[0], b[1], accuracy: 0.001)
    }
}
