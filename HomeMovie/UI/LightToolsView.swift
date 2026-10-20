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
    private let inset: CGFloat = 22
    private func name(_ index: Int) -> String {
        index == 0 ? "Black" : index == curve.controlPoints.count - 1 ? "White" : "Point \(index)"
    }
    private var caption: String {
        guard let dragging, curve.controlPoints.indices.contains(dragging) else { return "Tap the curve to add a point. Drag to adjust." }
        return "\(name(dragging)) · \(Int((curve.controlPoints[dragging].y * 100).rounded()))"
    }
    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                graph(width: max(1, geometry.size.width - inset * 2), height: max(1, geometry.size.height - inset * 2))
            }.frame(height: 180)
            HStack {
                Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Curve", systemImage: "arrow.counterclockwise") {
                    curve = .neutral; UISelectionFeedbackGenerator().selectionChanged()
                }.font(.caption).frame(minHeight: 44).disabled(!curve.isActive)
            }
        }
        .background { if dragging != nil { Color.clear.homeGlass().allowsHitTesting(false) } }
        .onDisappear { endEditing() }
        .onChange(of: enabled) { _, enabled in if !enabled { endEditing() } }
    }
    private func graph(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Canvas { context, _ in draw(&context, width: width, height: height) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    let x = Double((tap.location.x - inset) / width)
                    guard (0...1).contains(x) else { return }
                    let y = curve.output(at: x)
                    guard abs(tap.location.y - (inset + CGFloat(1 - y) * height)) <= 24 else { return }
                    editingChanged(true)
                    if curve.add(at: x, y: y) != nil { UISelectionFeedbackGenerator().selectionChanged() }
                    editingChanged(false)
                })
                .accessibilityLabel("Curve")
                .accessibilityAction(named: "Add Point") {
                    let points = curve.controlPoints
                    let gap = (0..<(points.count - 1)).max { points[$0 + 1].x - points[$0].x < points[$1 + 1].x - points[$1].x } ?? 0
                    let x = (points[gap].x + points[gap + 1].x) / 2
                    editingChanged(true); curve.add(at: x, y: curve.output(at: x)); editingChanged(false)
                }
            ForEach(curve.controlPoints.indices, id: \.self) { index in handle(index, width: width, height: height) }
        }.coordinateSpace(name: "lightCurve")
    }
    private func draw(_ context: inout GraphicsContext, width: CGFloat, height: CGFloat) {
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
            let y = CGFloat(1 - curve.output(at: x))
            let point = CGPoint(x: inset + CGFloat(x) * width, y: inset + y * height)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(.orange), lineWidth: 2)
    }
    private func handle(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        let diameter: CGFloat = dragging == index ? 16 : 12
        let value = curve.controlPoints[index]
        let point = CGPoint(x: inset + CGFloat(value.x) * width, y: inset + CGFloat(1 - value.y) * height)
        return Circle().fill(.background).overlay { Circle().stroke(.orange, lineWidth: 2) }
            .frame(width: diameter, height: diameter)
            .frame(width: 44, height: 44).contentShape(Rectangle()).position(point)
            .gesture(drag(index, width: width, height: height))
            .contextMenu {
                if index > 0 && index < curve.controlPoints.count - 1 {
                    Button("Delete Point", systemImage: "minus.circle", role: .destructive) {
                        editingChanged(true); curve.removePoint(index); editingChanged(false)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name(index)) curve point")
            .accessibilityValue("\(Int((curve.controlPoints[index].y * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: curve.movePoint(index, x: value.x, y: value.y + 0.01)
                case .decrement: curve.movePoint(index, x: value.x, y: value.y - 0.01)
                @unknown default: return
                }
                UISelectionFeedbackGenerator().selectionChanged()
            }
            .accessibilityAction(named: "Move Left") { curve.movePoint(index, x: value.x - 0.01, y: value.y) }
            .accessibilityAction(named: "Move Right") { curve.movePoint(index, x: value.x + 0.01, y: value.y) }
            .accessibilityAction(named: "Reset Point") { curve.movePoint(index, x: value.x, y: value.x) }
    }
    private func drag(_ index: Int, width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("lightCurve"))
            .onChanged { gesture in move(index, x: gesture.location.x, y: gesture.location.y, width: width, height: height) }
            .onEnded { _ in endEditing() }
    }
    private func move(_ index: Int, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        if dragging != index {
            dragging = index; snap = AdjustmentDetent()
            feedback.begin(value: curve.controlPoints[index].y, step: 0.01); editingChanged(true)
        }
        let normalized = (y - inset) / height
        let raw = 1.0 - Double(normalized)
        let input = min(1, max(0, Double((x - inset) / width)))
        let neutral = input
        let quantized = (raw * 100.0).rounded() / 100.0
        let level = snap.value(quantized, neutral: neutral, step: 0.01)
        curve.movePoint(index, x: input, y: level)
        feedback.changed(value: curve.controlPoints[index].y, step: 0.01, neutral: neutral)
    }
    private func endEditing() { dragging = nil; editingChanged(false) }
}
