import SwiftUI
import UIKit

// The caller selects the movie recipe or resolved clip recipe; slider behavior stays shared.
struct FilmEffectsControlSections: View {
    @Binding var settings: FilmEffectsSettings
    var editingChanged: (Bool) -> Void = { _ in }
    var compact = false
    @State private var showGrainDetails = false
    @State private var showHalationDetails = false
    @State private var showBloomDetails = false
    var body: some View {
        Group {
            grainControls
            halationControls
            bloomControls
            softnessControls
            rolloffControls
            Section {
                amountSlider("Sharpness", value: $settings.sharpnessAmount)
            } footer: { Text("Brings out fine detail. High amounts can emphasize noise.") }
            Section {
                amountSlider("Vignette", value: $settings.vignetteAmount)
            } footer: { Text("Gradually darkens the edges, keeping the center clear.") }
        }
    }
    private var softnessControls: some View {
        Section {
            amountSlider("Optical Softness", value: effectAmount(\.softnessAmount, enabled: \.softnessEnabled), accessibilityLabel: "Optical Softness amount")
        } footer: { Text("Gently softens fine detail for a less digital texture.") }
    }
    private var rolloffControls: some View {
        Section {
            amountSlider("Highlight Roll-Off", value: effectAmount(\.rolloffAmount, enabled: \.rolloffEnabled), accessibilityLabel: "Highlight Roll-Off amount")
        } footer: { Text("Softens the brightest tones while preserving shadow detail. Lower amounts keep highlights brighter.") }
    }
    private var grainControls: some View {
        Section {
            amountSlider("Grain", value: effectAmount(\.grainAmount, enabled: \.grainEnabled), accessibilityLabel: "Grain amount")
                DisclosureGroup("Adjustments", isExpanded: $showGrainDetails) {
                    Picker("Texture", selection: $settings.grainTexture.withSelectionFeedback()) {
                        ForEach(FilmGrainTexture.allCases) { texture in Text(texture.label).tag(texture) }
                    }
                    amountSlider("Size", value: $settings.grainSize, range: 0.5...2, percent: false, accessibilityLabel: "Grain size")
                    amountSlider("Color", value: $settings.grainColor, resetValue: 1, accessibilityLabel: "Grain color")
                    Text("Zero keeps the grain monochrome. Higher values add restrained color texture.").font(.caption).foregroundStyle(.secondary)
                    Button("Reset Grain") { settings.grainEnabled = false; settings.grainAmount = 0; UISelectionFeedbackGenerator().selectionChanged(); settings.grainSize = 1; settings.grainTexture = .fine35; settings.grainColor = 1 }
                }
        } footer: { Text("Adds fine, moving film texture. Pause to inspect the detail.") }
    }
    private var halationControls: some View {
        Section {
            amountSlider("Halation", value: effectAmount(\.halationAmount, enabled: \.halationEnabled), accessibilityLabel: "Halation amount")
                DisclosureGroup("Adjustments", isExpanded: $showHalationDetails) {
                    amountSlider("Spread", value: $settings.halationSpread, resetValue: 0.35, accessibilityLabel: "Halation spread")
                    amountSlider("Highlight Sensitivity", value: $settings.halationSensitivity, resetValue: 0.25, accessibilityLabel: "Halation highlight sensitivity")
                    amountSlider("Color Intensity", value: $settings.halationSaturation, resetValue: 1, accessibilityLabel: "Halation color intensity")
                    Text("Controls the halo’s warm color without changing the scene’s color.").font(.caption).foregroundStyle(.secondary)
                    Button("Reset Halation") { settings.halationEnabled = false; settings.halationAmount = 0; UISelectionFeedbackGenerator().selectionChanged(); settings.halationSpread = 0.35; settings.halationSensitivity = 0.25; settings.halationSaturation = 1 }
                }
        } footer: { Text("Adds a warm halo around bright edges. Higher sensitivity includes more highlights.") }
    }
    private var bloomControls: some View {
        Section {
            amountSlider("Glow", value: effectAmount(\.bloomAmount, enabled: \.bloomEnabled), accessibilityLabel: "Glow amount")
                DisclosureGroup("Adjustments", isExpanded: $showBloomDetails) {
                    amountSlider("Spread", value: $settings.bloomSpread, resetValue: 0.35, accessibilityLabel: "Glow spread")
                    amountSlider("Highlight Sensitivity", value: $settings.bloomSensitivity, resetValue: 0.25, accessibilityLabel: "Glow highlight sensitivity")
                    Button("Reset Glow") { settings.bloomEnabled = false; settings.bloomAmount = 0; UISelectionFeedbackGenerator().selectionChanged(); settings.bloomSpread = 0.35; settings.bloomSensitivity = 0.25 }
                }
        } footer: { Text("Spreads colored light around highlights while preserving bright surface detail.") }
    }
    // Keep the legacy enable flags readable, but expose one amount: zero is off.
    private func effectAmount(_ amount: WritableKeyPath<FilmEffectsSettings, Double>, enabled: WritableKeyPath<FilmEffectsSettings, Bool>) -> Binding<Double> {
        Binding(get: { settings[keyPath: enabled] ? settings[keyPath: amount] : 0 }, set: { value in
            settings[keyPath: amount] = value
            settings[keyPath: enabled] = value > 0
        })
    }
    private func amountSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, percent: Bool = true, resetValue: Double? = nil, accessibilityLabel: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 6) {
            HStack {
                Text(label).fontWeight(.semibold)
                Spacer()
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : String(format: "%.1f×", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        value.wrappedValue = resetValue ?? (percent ? 0 : 1)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    .accessibilityHidden(true)
            }.font(.subheadline)
            HapticGlassSlider(value: value, range: range, neutral: resetValue ?? (percent ? 0 : 1), editingChanged: editingChanged)
                .frame(minHeight: 44).accessibilityLabel(accessibilityLabel ?? label)
                .accessibilityAction(named: "Reset Adjustment") {
                    value.wrappedValue = resetValue ?? (percent ? 0 : 1)
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                .accessibilityValue(percent ? "\(Int((value.wrappedValue * 100).rounded())) percent" : String(format: "%.1f times", value.wrappedValue))
        }.padding(.vertical, compact ? 0 : 4)
    }
}
