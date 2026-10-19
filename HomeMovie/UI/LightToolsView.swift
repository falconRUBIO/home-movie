import SwiftUI
import UIKit

struct LightHistogramView: View {
    let histogram: ReviewHistogram?
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Label("Tonal Range", systemImage: "chart.bar.xaxis")
                Spacer()
                if let histogram {
                    limitLabel("Black", fraction: histogram.blackFraction, symbol: "circle.bottomhalf.filled")
                    limitLabel("White", fraction: histogram.whiteFraction, symbol: "circle.tophalf.filled")
                } else { Text("Waiting for frame…").foregroundStyle(.secondary) }
            }.font(.caption)
            Canvas { context, size in
                let bins = histogram?.bins ?? Array(repeating: 0, count: 64)
                let peak = Double(max(1, bins.max() ?? 1))
                let step = size.width / CGFloat(bins.count)
                for (i, bin) in bins.enumerated() {
                    let height = CGFloat(sqrt(Double(bin) / peak)) * (size.height - 2)
                    let rect = CGRect(x: CGFloat(i) * step, y: size.height - height,
                        width: max(1, step - 0.5), height: height)
                    context.fill(Path(rect), with: .color(.secondary.opacity(0.65)))
                }
            }.frame(height: 32).accessibilityHidden(true)
            HStack { Text("Shadows"); Spacer(); Text("Highlights") }
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview tonal range")
            .accessibilityValue(histogram.map { "Black limit \(percent($0.blackFraction)); white channel limit \(percent($0.whiteFraction))" } ?? "Waiting for frame")
            .accessibilityHint("Sampled after edits. Pixels at display limits do not prove detail was lost in the original recording.")
    }
    private func percent(_ fraction: Double) -> String { String(format: "%.1f%%", fraction * 100) }
    private func limitLabel(_ name: String, fraction: Double, symbol: String) -> some View {
        Label("\(name) \(percent(fraction))", systemImage: symbol)
            .monospacedDigit().foregroundStyle(fraction >= 0.001 ? Color.orange : Color.secondary)
    }
}

struct LightCurveEditor: View {
    @Binding var curve: LightCurve
    var editingChanged: (Bool) -> Void
    @State private var dragging: Int?
    @State private var feedback = AdjustmentFeedback()
    @State private var snap = AdjustmentDetent()
    @Environment(\.isEnabled) private var enabled
    private let names = ["Black", "Shadows", "Midtones", "Highlights", "White"]
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let inset: CGFloat = 22
                let width = max(1, geometry.size.width - inset * 2)
                let height = max(1, geometry.size.height - inset * 2)
                ZStack {
                    Canvas { context, _ in
                        var grid = Path()
                        for i in 0...4 {
                            let x = inset + width * CGFloat(i) / 4
                            let y = inset + height * CGFloat(i) / 4
                            grid.move(to: CGPoint(x: x, y: inset)); grid.addLine(to: CGPoint(x: x, y: inset + height))
                            grid.move(to: CGPoint(x: inset, y: y)); grid.addLine(to: CGPoint(x: inset + width, y: y))
                        }
                        context.stroke(grid, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                        var reference = Path()
                        reference.move(to: CGPoint(x: inset, y: inset + height))
                        reference.addLine(to: CGPoint(x: inset + width, y: inset))
                        context.stroke(reference, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        var path = Path()
                        for i in 0...128 {
                            let x = Double(i) / 128
                            let point = CGPoint(x: inset + CGFloat(x) * width, y: inset + CGFloat(1 - curve.output(at: x)) * height)
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        context.stroke(path, with: .color(.orange), lineWidth: 2)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                    ForEach(1...3, id: \.self) { index in
                        Circle().fill(.background).overlay { Circle().stroke(.orange, lineWidth: 2) }
                            .frame(width: dragging == index ? 16 : 12, height: dragging == index ? 16 : 12)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .position(x: inset + CGFloat(index) * width / 4,
                                y: inset + CGFloat(1 - curve.levels[index]) * height)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lightCurve"))
                                .onChanged { gesture in
                                    if dragging != index {
                                        dragging = index; snap = AdjustmentDetent()
                                        feedback.begin(value: curve.levels[index], step: 0.01); editingChanged(true)
                                    }
                                    let raw = Double(1 - (gesture.location.y - inset) / height)
                                    let neutral = Double(index) / 4
                                    let level = snap.value((raw * 100).rounded() / 100, neutral: neutral, step: 0.01)
                                    curve.move(index, to: level)
                                    feedback.changed(value: curve.levels[index], step: 0.01, neutral: neutral)
                                }.onEnded { _ in dragging = nil; editingChanged(false) })
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(names[index]) curve point")
                            .accessibilityValue("\(Int((curve.levels[index] * 100).rounded())) percent")
                            .accessibilityAdjustableAction { direction in
                                let delta = direction == .increment ? 0.01 : -0.01
                                curve.move(index, to: curve.levels[index] + delta)
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                            .accessibilityAction(named: "Reset Point") { curve.move(index, to: Double(index) / 4) }
                    }
                }.coordinateSpace(name: "lightCurve")
            }.frame(height: 180)
            HStack {
                Text(dragging.map { "\(names[$0]) · \(Int((curve.levels[$0] * 100).rounded()))" }
                    ?? "Drag points to shape brightness.").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Curve", systemImage: "arrow.counterclockwise") {
                    curve = .neutral; UISelectionFeedbackGenerator().selectionChanged()
                }.font(.caption).frame(minHeight: 44).disabled(!curve.isActive)
            }
        }
        .background { if dragging != nil { Color.clear.homeGlass().allowsHitTesting(false) } }
        .onDisappear { dragging = nil; editingChanged(false) }
        .onChange(of: enabled) { _, enabled in if !enabled { dragging = nil; editingChanged(false) } }
    }
}
