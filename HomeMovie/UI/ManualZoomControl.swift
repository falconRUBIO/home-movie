import SwiftUI
import UIKit

/// A lens strip owns the entire touch, even when the dial appears above it.
/// UIKit arbitrates tap/hold/pan so releasing a scrub never also taps a lens.
struct ManualZoomControl: View {
    let options: CameraOptions
    let enabled: Bool
    let onLens: (CGFloat) -> Void
    let onBegin: (UUID) -> Void
    let onZoom: (CGFloat, Double, UUID) -> Void
    let onEnd: (UUID) -> Void
    @State private var sessionID = UUID()
    @State private var expanded = false
    @State private var touching = false
    @State private var dismissal = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        touchStrip(lenses: options.lenses)
            .frame(width: CGFloat(options.lenses.count) * 50 - 6, height: 44)
            .overlay(alignment: .bottom) {
                if expanded {
                    ZoomArc(zoom: Double(options.zoom), minimum: Double(options.minimum),
                        maximum: Double(options.maximum), multiplier: Double(options.multiplier),
                        stops: options.lenses.map { Double($0.factor) })
                        .frame(width: 274, height: 104)
                        // Keep the original strip's touch, and allow regrabbing the visible wheel.
                        .overlay { touchStrip(lenses: []) }
                        .cameraControlRegion().offset(y: -52).accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: expanded)
            .task(id: dismissal) {
                guard expanded, !touching else { return }
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled, !touching else { return }
                expanded = false
            }
            .onChange(of: enabled) { _, allowed in
                if !allowed { expanded = false }
            }
    }
    private func touchStrip(lenses: [LensChoice]) -> some View {
        LensZoomTouchStrip(lenses: lenses, zoom: options.zoom,
            multiplier: options.multiplier, minimum: options.minimum, maximum: options.maximum,
            enabled: enabled, onLens: onLens,
            onBegin: {
                touching = true; expanded = true; dismissal = UUID(); onBegin(sessionID)
            }, onZoom: { factor, time in onZoom(factor, time, sessionID) }, onEnd: {
                touching = false; dismissal = UUID(); onEnd(sessionID)
            })
    }

}

private struct ZoomArc: View {
    let zoom: Double
    let minimum: Double
    let maximum: Double
    let multiplier: Double
    let stops: [Double]
    var body: some View {
        VStack(spacing: 0) {
            Text(ManualZoomScale.label(zoom * multiplier))
                .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(.yellow).padding(.top, 8)
            Canvas { context, size in
                guard minimum.isFinite, maximum.isFinite, zoom.isFinite, minimum > 0, maximum > minimum, zoom > 0 else { return }
                let center = CGPoint(x: size.width / 2, y: size.height + 110)
                let radius: CGFloat = 158
                let tickCount = Int(ceil(log2(maximum / minimum) * 12))
                // Equal visual space per doubling, independent of device zoom range.
                for tick in 0...min(240, tickCount) {
                    let factor = minimum * pow(2, Double(tick) / 12)
                    guard factor <= maximum * 1.00001 else { continue }
                    drawTick(context: &context, center: center, radius: radius,
                        factor: factor, major: false, label: nil)
                }
                let labels = Array(Set(stops + [minimum, maximum])).sorted()
                for factor in labels {
                    drawTick(context: &context, center: center, radius: radius,
                        factor: factor, major: true,
                        label: ManualZoomScale.label(factor * multiplier))
                }
                var indicator = Path()
                indicator.move(to: CGPoint(x: center.x, y: 1))
                indicator.addLine(to: CGPoint(x: center.x, y: 12))
                context.stroke(indicator, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }.clipped()
        }.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
    private func drawTick(context: inout GraphicsContext, center: CGPoint, radius: CGFloat,
                          factor: Double, major: Bool, label: String?) {
        let angle = log2(factor / zoom) * 0.53
        guard abs(angle) < 0.94 else { return }
        let alpha = max(0, min(1, (0.94 - abs(angle)) / 0.18))
        func point(_ r: CGFloat) -> CGPoint {
            CGPoint(x: center.x + CGFloat(sin(angle)) * r, y: center.y - CGFloat(cos(angle)) * r)
        }
        var path = Path(); path.move(to: point(radius)); path.addLine(to: point(radius - (major ? 14 : 7)))
        context.stroke(path, with: .color(.white.opacity(alpha * (major ? 0.95 : 0.45))), lineWidth: major ? 1.5 : 1)
        if let label {
            context.draw(Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(alpha)),
                at: point(radius - 27))
        }
    }
}

private struct LensZoomTouchStrip: UIViewRepresentable {
    let lenses: [LensChoice]
    let zoom: CGFloat
    let multiplier: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let enabled: Bool
    let onLens: (CGFloat) -> Void
    let onBegin: () -> Void
    let onZoom: (CGFloat, Double) -> Void
    let onEnd: () -> Void
    func makeUIView(context: Context) -> ZoomLensStripView { ZoomLensStripView() }
    func updateUIView(_ view: ZoomLensStripView, context: Context) {
        view.configure(lenses: lenses, zoom: zoom, multiplier: multiplier,
            minimum: minimum, maximum: maximum, enabled: enabled,
            onLens: onLens, onBegin: onBegin, onZoom: onZoom, onEnd: onEnd)
    }
    static func dismantleUIView(_ view: ZoomLensStripView, coordinator: ()) { view.finish(deferred: true) }
}

private final class ZoomLensStripView: UIView, UIGestureRecognizerDelegate {
    private let stack = UIStackView()
    private var buttons: [UIButton] = []
    private var factors: [CGFloat] = []
    private var zoom: CGFloat = 1, multiplier: CGFloat = 1, minimum: CGFloat = 1, maximum: CGFloat = 1
    private var base: Double?
    private var previousValue: Double?
    private var lastFeedback = 0.0
    private let feedback = UISelectionFeedbackGenerator()
    private var onLens: (CGFloat) -> Void = { _ in }
    private var onBegin: () -> Void = {}
    private var onZoom: (CGFloat, Double) -> Void = { _, _ in }
    private var onEnd: () -> Void = {}
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal; stack.spacing = 6; stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        hold.minimumPressDuration = 0.28; hold.allowableMovement = 12; hold.delegate = self
        addGestureRecognizer(pan); addGestureRecognizer(hold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(lenses: [LensChoice], zoom: CGFloat, multiplier: CGFloat, minimum: CGFloat, maximum: CGFloat,
                   enabled: Bool, onLens: @escaping (CGFloat) -> Void, onBegin: @escaping () -> Void,
                   onZoom: @escaping (CGFloat, Double) -> Void, onEnd: @escaping () -> Void) {
        self.onLens = onLens; self.onBegin = onBegin; self.onZoom = onZoom; self.onEnd = onEnd
        self.zoom = zoom; self.multiplier = multiplier; self.minimum = minimum; self.maximum = maximum
        if !enabled { finish(deferred: true) }
        isUserInteractionEnabled = enabled; alpha = enabled ? 1 : 0.45
        pan.isEnabled = enabled && maximum > minimum; hold.isEnabled = pan.isEnabled
        if factors != lenses.map(\.factor) {
            finish(deferred: true); factors = lenses.map(\.factor)
            for button in buttons { stack.removeArrangedSubview(button); button.removeFromSuperview() }
            buttons = lenses.enumerated().map { index, _ in
                let button = UIButton(type: .custom); button.tag = index
                button.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                button.layer.cornerRadius = 22
                button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
                stack.addArrangedSubview(button); return button
            }
        }
        let closest = factors.indices.min { abs(log2(factors[$0] / zoom)) < abs(log2(factors[$1] / zoom)) }
        for (index, button) in buttons.enumerated() {
            let selected = closest == index
            button.setTitle(selected ? ManualZoomScale.label(Double(zoom * multiplier)) : lenses[index].label, for: .normal)
            button.setTitleColor(selected ? .systemYellow : .white, for: .normal)
            button.backgroundColor = selected ? UIColor.systemYellow.withAlphaComponent(0.15) : .clear
            button.accessibilityLabel = "\(lenses[index].label) lens"
            button.accessibilityValue = selected ? "Current zoom \(ManualZoomScale.label(Double(zoom * multiplier)))" : nil
            button.accessibilityHint = "Tap to switch lens. Hold and slide to zoom."
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
            button.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Zoom in") { [weak self] _ in self?.adjust(1); return true },
                UIAccessibilityCustomAction(name: "Zoom out") { [weak self] _ in self?.adjust(-1); return true }
            ]
        }
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Zoom in", target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: "Zoom out", target: self, selector: #selector(zoomOut))]
    }
    @objc private func tapped(_ button: UIButton) { guard base == nil else { return }; onLens(factors[button.tag]) }
    private func begin() {
        guard base == nil else { return }
        base = Double(zoom); previousValue = Double(zoom); feedback.prepare(); onBegin()
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { begin() }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            if pan.state != .began && pan.state != .changed { finish() }
        }
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began: begin(); update(gesture)
        case .changed: update(gesture)
        case .ended: update(gesture); finish()
        case .cancelled, .failed: finish()
        default: break
        }
    }
    private func update(_ gesture: UIPanGestureRecognizer) {
        guard let base else { return }
        let value = ManualZoomScale.factor(start: base, translation: Double(gesture.translation(in: self).x),
            minimum: Double(minimum), maximum: Double(maximum))
        let now = ProcessInfo.processInfo.systemUptime
        onZoom(CGFloat(value), now)
        if let previousValue, factors.contains(where: {
            let stop = Double($0)
            return (previousValue < stop && value >= stop) || (previousValue > stop && value <= stop)
        }), now - lastFeedback > 0.08 {
            feedback.selectionChanged(); lastFeedback = now
        }
        previousValue = value
    }
    func finish(deferred: Bool = false) {
        guard base != nil else { return }
        base = nil
        let end = onEnd
        // updateUIView/dismantleUIView must not synchronously mutate SwiftUI state.
        if deferred { DispatchQueue.main.async { end() } } else { end() }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pan && otherGestureRecognizer === hold) ||
            (gestureRecognizer === hold && otherGestureRecognizer === pan)
    }
    // A real adjustable element also gives VoiceOver users continuous zoom.
    override func accessibilityIncrement() { adjust(1) }
    override func accessibilityDecrement() { adjust(-1) }
    @objc private func zoomIn() -> Bool { adjust(1); return true }
    @objc private func zoomOut() -> Bool { adjust(-1); return true }
    private func adjust(_ direction: Double) {
        guard isUserInteractionEnabled else { return }
        begin()
        onZoom(CGFloat(ManualZoomScale.factor(start: Double(zoom), translation: -direction * 12,
            minimum: Double(minimum), maximum: Double(maximum))), ProcessInfo.processInfo.systemUptime)
        finish()
    }
}
