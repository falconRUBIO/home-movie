import SwiftUI

// Scene review edits the movie recipe used by preview and export.
struct FilmEffectsControlSections: View {
    @Binding var settings: FilmEffectsSettings
    @State private var showGrainDetails = false
    @State private var showHalationDetails = false
    @State private var showBloomDetails = false
    var body: some View {
        Group {
            halationControls
            bloomControls
            grainControls
            softnessControls
            rolloffControls
            Section {
                Button("Reset FX") { settings = .off }
            } footer: {
                Text("Applies to all scenes in this movie. Original recordings stay unchanged.")
            }
        }
    }
    private var softnessControls: some View {
        Section {
            Toggle("Optical Softness", isOn: $settings.softnessEnabled)
            if settings.softnessEnabled {
                amountSlider("Amount", value: $settings.softnessAmount)
            }
        } footer: { Text("Gently softens fine detail for a less digital texture. Faces stay clear.") }
    }
    private var rolloffControls: some View {
        Section {
            Toggle("Highlight Roll-Off", isOn: $settings.rolloffEnabled)
            if settings.rolloffEnabled {
                amountSlider("Amount", value: $settings.rolloffAmount)
            }
        } footer: { Text("Smooths bright tones toward white. Lower amounts keep highlights brighter.") }
    }
    private var grainControls: some View {
        Section {
            Toggle("Grain", isOn: $settings.grainEnabled)
            if settings.grainEnabled {
                amountSlider("Amount", value: $settings.grainAmount)
                DisclosureGroup("Adjustments", isExpanded: $showGrainDetails) {
                    Picker("Texture", selection: $settings.grainTexture) {
                        ForEach(FilmGrainTexture.allCases) { texture in Text(texture.label).tag(texture) }
                    }
                    amountSlider("Size", value: $settings.grainSize, range: 0.5...2, percent: false)
                    Button("Reset Grain") { settings.grainAmount = 0.25; settings.grainSize = 1; settings.grainTexture = .fine35 }
                }
            }
        } footer: { Text("Adds fine, moving film texture. Pause to inspect the detail.") }
    }
    private var halationControls: some View {
        Section {
            Toggle("Halation", isOn: $settings.halationEnabled)
            if settings.halationEnabled {
                amountSlider("Amount", value: $settings.halationAmount)
                DisclosureGroup("Adjustments", isExpanded: $showHalationDetails) {
                    amountSlider("Spread", value: $settings.halationSpread)
                    amountSlider("Highlight Sensitivity", value: $settings.halationSensitivity)
                    Button("Reset Halation") { settings.halationAmount = 0.2; settings.halationSpread = 0.35; settings.halationSensitivity = 0.25 }
                }
            }
        } footer: { Text("Adds a warm halo around bright edges. Higher sensitivity includes more highlights.") }
    }
    private var bloomControls: some View {
        Section {
            Toggle("Glow", isOn: $settings.bloomEnabled)
            if settings.bloomEnabled {
                amountSlider("Amount", value: $settings.bloomAmount)
                DisclosureGroup("Adjustments", isExpanded: $showBloomDetails) {
                    amountSlider("Spread", value: $settings.bloomSpread)
                    amountSlider("Highlight Sensitivity", value: $settings.bloomSensitivity)
                    Button("Reset Glow") { settings.bloomAmount = 0.15; settings.bloomSpread = 0.35; settings.bloomSensitivity = 0.25 }
                }
            }
        } footer: { Text("Softens the glow around bright lights while keeping their color.") }
    }
    private func amountSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, percent: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: "%.1f×", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).accessibilityLabel(label)
        }.padding(.vertical, 4)
    }
}
