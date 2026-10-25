import Foundation

/// Sparse, relative clip edits. Absent controls continue following the movie recipe.
struct FilmEffectsTweaks: Codable, Equatable, Sendable {
    enum Control: String, Codable, CaseIterable, Sendable {
        case grain, grainSize, halation, halationSpread, halationSensitivity
        case glow, glowSpread, glowSensitivity, softness, rolloff, sharpness, vignette
        var range: ClosedRange<Double> { self == .grainSize ? 0.5...2 : 0...1 }
        var keyPath: WritableKeyPath<FilmEffectsSettings, Double> {
            switch self {
            case .grain: \.grainAmount
            case .grainSize: \.grainSize
            case .halation: \.halationAmount
            case .halationSpread: \.halationSpread
            case .halationSensitivity: \.halationSensitivity
            case .glow: \.bloomAmount
            case .glowSpread: \.bloomSpread
            case .glowSensitivity: \.bloomSensitivity
            case .softness: \.softnessAmount
            case .rolloff: \.rolloffAmount
            case .sharpness: \.sharpnessAmount
            case .vignette: \.vignetteAmount
            }
        }
        var enabledKeyPath: WritableKeyPath<FilmEffectsSettings, Bool>? {
            switch self {
            case .grain: \.grainEnabled
            case .halation: \.halationEnabled
            case .glow: \.bloomEnabled
            case .softness: \.softnessEnabled
            case .rolloff: \.rolloffEnabled
            default: nil
            }
        }
        func value(in settings: FilmEffectsSettings) -> Double {
            if let enabledKeyPath, !settings[keyPath: enabledKeyPath] { return 0 }
            return settings[keyPath: keyPath]
        }
        func set(_ value: Double, in settings: inout FilmEffectsSettings) {
            let clamped = min(range.upperBound, max(range.lowerBound, value))
            settings[keyPath: keyPath] = clamped
            if let enabledKeyPath { settings[keyPath: enabledKeyPath] = clamped > 0 }
        }
    }
    var offsets: [Control: Double] = [:]
    var grainTexture: FilmGrainTexture?
    var isEmpty: Bool { offsets.isEmpty && grainTexture == nil }
    var normalized: Self? { isEmpty ? nil : self }

    func applying(to movie: FilmEffectsSettings) -> FilmEffectsSettings {
        var result = movie
        for (control, offset) in offsets {
            control.set(control.value(in: movie) + offset, in: &result)
        }
        if let grainTexture { result.grainTexture = grainTexture }
        return result
    }
    /// Diff just the controls touched by this edit. Preserve other offsets even when
    /// their resolved value is currently clamped at zero or full strength.
    func updating(from previous: FilmEffectsSettings, to edited: FilmEffectsSettings,
                  relativeTo movie: FilmEffectsSettings) -> Self {
        var result = self
        for control in Control.allCases where abs(control.value(in: previous) - control.value(in: edited)) > 0.0000001 {
            let delta = control.value(in: edited) - control.value(in: movie)
            result.offsets[control] = abs(delta) > 0.0000001 ? delta : nil
        }
        if edited.grainTexture != previous.grainTexture {
            result.grainTexture = edited.grainTexture == movie.grainTexture ? nil : edited.grainTexture
        }
        return result
    }
    func validate() throws {
        guard offsets.allSatisfy({ control, delta in
            delta.isFinite && abs(delta) <= control.range.upperBound - control.range.lowerBound
        }) else { throw HomeMovieError.message("This clip’s FX tweaks are invalid.") }
    }
}
