import SwiftUI
import UIKit

// Shared interaction for continuous controls. Feedback only comes from user input.
struct AdjustmentDetent {
    var latched = false
    mutating func value(_ proposed: Double, neutral: Double, step: Double) -> Double {
        let distance = abs(proposed - neutral)
        if latched { latched = distance < step * 2.5 }
        else { latched = distance <= step * 1.25 }
        return latched ? neutral : proposed
    }
}

@MainActor final class AdjustmentFeedback {
    private let tick = UISelectionFeedbackGenerator()
    private let detent = UIImpactFeedbackGenerator(style: .soft)
    private var previous: Int?
    func begin(value: Double, step: Double) {
        previous = Int((value / step).rounded()); tick.prepare(); detent.prepare()
    }
    func changed(value: Double, step: Double, neutral: Double) {
        let next = Int((value / step).rounded())
        guard previous != next else { return }
        previous = next
        if abs(value - neutral) < step * 0.1 { detent.impactOccurred(intensity: 0.75); detent.prepare() }
        else { tick.selectionChanged(); tick.prepare() }
    }
}

extension View {
    func adjustmentGlass(active: Bool) -> some View {
        background {
            if active { Color.clear.frame(width: 44, height: 32).homeGlass().allowsHitTesting(false) }
        }
    }
}

@MainActor extension Binding where Value: Equatable {
    func withSelectionFeedback() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { next in
            guard next != wrappedValue else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            wrappedValue = next
        })
    }
}

struct HapticGlassSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step = 0.01
    var neutral = 0.0
    var editingChanged: (Bool) -> Void = { _ in }
    @State private var editing = false
    @State private var snap = AdjustmentDetent()
    @State private var feedback = AdjustmentFeedback()
    private var interaction: Binding<Double> {
        Binding(get: { value }, set: { proposed in
            let quantized = min(range.upperBound, max(range.lowerBound, (proposed / step).rounded() * step))
            let next = snap.value(quantized, neutral: neutral, step: step)
            feedback.changed(value: next, step: step, neutral: neutral)
            value = next
        })
    }
    var body: some View {
        // The native iOS 26 thumb supplies the same pressed Liquid Glass as FX.
        Slider(value: interaction, in: range, onEditingChanged: { active in
            if active { snap = AdjustmentDetent(); feedback.begin(value: value, step: step) }
            editing = active; editingChanged(active)
        }).onDisappear {
            if editing { editing = false; editingChanged(false) }
        }
    }
}
