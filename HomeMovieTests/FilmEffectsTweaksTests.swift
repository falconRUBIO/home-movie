import XCTest
@testable import HomeMovie

final class FilmEffectsTweaksTests: XCTestCase {
    func testColorControlsFollowMovieAndPreserveRelativeClipEdits() throws {
        var movie = FilmEffectsSettings.off
        var edited = movie; edited.grainColor = 0.5; edited.halationSaturation = 0.75
        let tweaks = FilmEffectsTweaks().updating(from: movie, to: edited, relativeTo: movie)
        XCTAssertEqual(tweaks.offsets[.grainColor], -0.5)
        XCTAssertEqual(tweaks.offsets[.halationSaturation], -0.25)
        try tweaks.validate()
        let restored = try JSONDecoder().decode(FilmEffectsTweaks.self, from: JSONEncoder().encode(tweaks))
        movie.grainColor = 0.8; movie.halationSaturation = 0.5
        let resolved = restored.applying(to: movie)
        XCTAssertEqual(resolved.grainColor, 0.3, accuracy: 0.000001)
        XCTAssertEqual(resolved.halationSaturation, 0.25, accuracy: 0.000001)
        XCTAssertFalse(resolved.grainEnabled); XCTAssertFalse(resolved.halationEnabled)
    }
    private var movieLook: FilmEffectsSettings {
        var settings = FilmEffectsSettings.off
        settings.grainEnabled = true; settings.grainAmount = 0.5
        settings.bloomEnabled = true; settings.bloomAmount = 0.3
        return settings
    }
    func testClipStartsWithMovieAndOnlyTouchedControlGetsAnOffset() throws {
        let movie = movieLook
        XCTAssertEqual(FilmEffectsTweaks().applying(to: movie), movie)
        var edited = movie; edited.grainAmount = 0.2
        let tweak = FilmEffectsTweaks().updating(from: movie, to: edited, relativeTo: movie)
        XCTAssertEqual(tweak.offsets.count, 1)
        XCTAssertEqual(tweak.offsets[.grain] ?? 0, -0.3, accuracy: 0.000001)
        XCTAssertEqual(tweak.applying(to: movie).grainAmount, 0.2, accuracy: 0.000001)
        var changedMovie = movie; changedMovie.grainAmount = 0.7; changedMovie.bloomAmount = 0.8
        let resolved = tweak.applying(to: changedMovie)
        XCTAssertEqual(resolved.grainAmount, 0.4, accuracy: 0.000001)
        XCTAssertEqual(resolved.bloomAmount, 0.8)
        try tweak.validate()
        XCTAssertEqual(movie, movieLook)
    }
    func testDisabledLegacyAmountsAreZeroAndClipCanEnableAnEffect() {
        let movie = FilmEffectsSettings.off
        var edited = movie; edited.grainEnabled = true; edited.grainAmount = 0.4
        let tweak = FilmEffectsTweaks().updating(from: movie, to: edited, relativeTo: movie)
        XCTAssertEqual(tweak.offsets[.grain], 0.4)
        XCTAssertTrue(tweak.applying(to: movie).grainEnabled)
        var zero = movieLook; zero.grainEnabled = false
        let reduced = FilmEffectsTweaks().updating(from: movieLook, to: zero, relativeTo: movieLook)
        XCTAssertFalse(reduced.applying(to: movieLook).grainEnabled)
    }
    func testClampingDoesNotEraseOffsetsWhenAnotherSliderChanges() {
        let movie = movieLook
        let tweaks = FilmEffectsTweaks(offsets: [.grain: -0.8, .glow: 0.9])
        let previous = tweaks.applying(to: movie)
        XCTAssertEqual(previous.grainAmount, 0)
        XCTAssertEqual(previous.bloomAmount, 1)
        var edited = previous; edited.sharpnessAmount = 0.2
        let updated = tweaks.updating(from: previous, to: edited, relativeTo: movie)
        XCTAssertEqual(updated.offsets[.grain], -0.8)
        XCTAssertEqual(updated.offsets[.glow], 0.9)
        var brighter = movie; brighter.grainAmount = 1
        XCTAssertEqual(updated.applying(to: brighter).grainAmount, 0.2, accuracy: 0.000001)
    }
    func testReturningControlToMovieValueRemovesItsTweak() {
        let movie = movieLook
        let tweaks = FilmEffectsTweaks(offsets: [.grain: -0.2], grainTexture: .coarse16)
        let reset = tweaks.updating(from: tweaks.applying(to: movie), to: movie, relativeTo: movie)
        XCTAssertNil(reset.normalized)
        XCTAssertEqual(reset.applying(to: movie), movie)
    }
    func testCodableRoundTripAndInvalidOffsets() throws {
        let tweaks = FilmEffectsTweaks(offsets: [.grain: -0.2, .grainSize: 1.4], grainTexture: .coarse16)
        let restored = try JSONDecoder().decode(FilmEffectsTweaks.self, from: JSONEncoder().encode(tweaks))
        XCTAssertEqual(restored, tweaks)
        try restored.validate()
        XCTAssertThrowsError(try FilmEffectsTweaks(offsets: [.grain: .nan]).validate())
        XCTAssertThrowsError(try FilmEffectsTweaks(offsets: [.grain: 1.01]).validate())
        XCTAssertThrowsError(try FilmEffectsTweaks(offsets: [.grainSize: 1.6]).validate())
    }
    func testUndoRedoIncludesClipTweaksAndMovieBaseTogether() {
        let initial = SceneEditState(start: 0, end: 10, adjustments: .neutral, effects: movieLook)
        var edited = initial; edited.clipEffects = FilmEffectsTweaks(offsets: [.grain: -0.2])
        var history = SceneEditHistory(initial)
        history.begin(initial); history.end(edited)
        XCTAssertEqual(history.undo(), initial)
        XCTAssertEqual(history.redo(), edited)
    }
}
