import SwiftUI
import UIKit

/// One persistent UIKit surface owns touch recognition AND the visible wheel.
/// Opening/rendering the dial never waits for a SwiftUI layout or a camera event.
struct ManualZoomControl: UIViewRepresentable {
    let options: CameraOptions
    let enabled: Bool
    let reservedTrailingWidth: CGFloat
    let onLens: (CGFloat) -> Void
    let onBegin: (UUID) -> Void
    let onZoom: (CGFloat, Double, UUID) -> Void
    let onEnd: (UUID) -> Void
    let onVisibilityChanged: (Bool) -> Void
    func makeUIView(context: Context) -> ZoomDialControlView { ZoomDialControlView() }
    func updateUIView(_ view: ZoomDialControlView, context: Context) {
        view.configure(lenses: options.lenses, zoom: options.zoom, multiplier: options.multiplier,
            minimum: options.minimum, maximum: options.maximum, enabled: enabled,
            reservedTrailingWidth: reservedTrailingWidth, onLens: onLens, onBegin: onBegin,
            onZoom: onZoom, onEnd: onEnd, onVisibilityChanged: onVisibilityChanged)
    }
    static func dismantleUIView(_ view: ZoomDialControlView, coordinator: ()) { view.cancelInput() }
}

final class ZoomDialControlView: UIView, UIGestureRecognizerDelegate {
    static let height: CGFloat = 104
    private let sessionID = UUID()
    private let stack = UIStackView()
    private let wheel = ZoomWheelView()
    private var buttons: [UIButton] = []
    private var factors: [CGFloat] = []
    private var zoom: CGFloat = 1, multiplier: CGFloat = 1, minimum: CGFloat = 1, maximum: CGFloat = 1
    private var reservedTrailingWidth: CGFloat = 100
    private var drag: ManualZoomDrag?
    private var previousValue: Double?
    private var hideWork: DispatchWorkItem?
    private var lastFeedback = 0.0
    private let feedback = UISelectionFeedbackGenerator()
    private var onLens: (CGFloat) -> Void = { _ in }
    private var onBegin: (UUID) -> Void = { _ in }
    private var onZoom: (CGFloat, Double, UUID) -> Void = { _, _, _ in }
    private var onEnd: (UUID) -> Void = { _ in }
    private var onVisibilityChanged: (Bool) -> Void = { _ in }
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
    var isDialVisible: Bool { !wheel.isHidden }
    var dialFrame: CGRect { wheel.frame }
    var lensFrame: CGRect { stack.frame }
    var displayedZoom: Double { wheel.zoom }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false; clipsToBounds = false
        stack.axis = .horizontal; stack.spacing = 4; stack.distribution = .fillEqually
        addSubview(wheel); addSubview(stack)
        wheel.isHidden = true; wheel.isUserInteractionEnabled = false
        pan.maximumNumberOfTouches = 1; pan.delegate = self
        pan.cancelsTouchesInView = true; pan.delaysTouchesBegan = false
        hold.minimumPressDuration = 0.2; hold.allowableMovement = 12; hold.delegate = self
        hold.cancelsTouchesInView = true; hold.delaysTouchesBegan = false
        addGestureRecognizer(pan); addGestureRecognizer(hold)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        wheel.frame = bounds
        let available = max(1, bounds.width - reservedTrailingWidth - 8)
        let stripWidth = min(available, max(44, CGFloat(factors.count) * 48 - 4))
        stack.frame = CGRect(x: 4 + (available - stripWidth) / 2, y: bounds.height - 48,
            width: stripWidth, height: 44)
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, bounds.contains(point) else { return false }
        // Leave the separate Dolly/PiP buttons, and clear preview above the closed row, alone.
        if point.y >= bounds.height - 52 && point.x >= bounds.width - reservedTrailingWidth { return false }
        return isDialVisible || stack.frame.insetBy(dx: -4, dy: -4).contains(point)
    }
    func configure(lenses: [LensChoice], zoom: CGFloat, multiplier: CGFloat, minimum: CGFloat, maximum: CGFloat,
                   enabled: Bool, reservedTrailingWidth: CGFloat,
                   onLens: @escaping (CGFloat) -> Void, onBegin: @escaping (UUID) -> Void,
                   onZoom: @escaping (CGFloat, Double, UUID) -> Void, onEnd: @escaping (UUID) -> Void,
                   onVisibilityChanged: @escaping (Bool) -> Void) {
        self.onLens = onLens; self.onBegin = onBegin; self.onZoom = onZoom
        self.onEnd = onEnd; self.onVisibilityChanged = onVisibilityChanged
        self.zoom = zoom; self.multiplier = multiplier; self.minimum = minimum; self.maximum = maximum
        self.reservedTrailingWidth = reservedTrailingWidth
        if !enabled { cancelInput() }
        isUserInteractionEnabled = enabled; alpha = enabled ? 1 : 0.45
        let canScrub = enabled && maximum > minimum
        if pan.isEnabled != canScrub { pan.isEnabled = canScrub }
        if hold.isEnabled != canScrub { hold.isEnabled = canScrub }
        if factors != lenses.map(\.factor) {
            cancelInput(); factors = lenses.map(\.factor)
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
            button.accessibilityHint = "Tap to switch lens. Hold or slide to zoom."
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
            button.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Zoom in") { [weak self] _ in self?.adjust(1); return true },
                UIAccessibilityCustomAction(name: "Zoom out") { [weak self] _ in self?.adjust(-1); return true }
            ]
        }
        wheel.minimum = Double(minimum); wheel.maximum = Double(maximum)
        wheel.multiplier = Double(multiplier); wheel.stops = factors.map(Double.init)
        if drag == nil && !isDialVisible { wheel.zoom = Double(zoom) }
        wheel.setNeedsDisplay(); setNeedsLayout()
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Zoom in") { [weak self] _ in self?.adjust(1); return true },
            UIAccessibilityCustomAction(name: "Zoom out") { [weak self] _ in self?.adjust(-1); return true }
        ]
    }
    @objc private func tapped(_ button: UIButton) {
        guard drag == nil, factors.indices.contains(button.tag) else { return }
        hideDial(); onLens(factors[button.tag])
    }
    /// Shared by real pan/hold actions and native view regression tests.
    func beginScrub() {
        guard drag == nil, isUserInteractionEnabled, maximum > minimum else { return }
        hideWork?.cancel(); hideWork = nil
        drag = ManualZoomDrag(start: Double(zoom)); previousValue = Double(zoom)
        wheel.zoom = Double(zoom)
        // Synchronous UIKit visibility: this happens before the first zoom callback.
        wheel.isHidden = false; stack.layer.opacity = 0; wheel.setNeedsDisplay(); layoutIfNeeded()
        onVisibilityChanged(true); feedback.prepare(); onBegin(sessionID)
    }
    func scrub(translation: Double) {
        guard var current = drag else { return }
        let value = current.update(translation: translation, minimum: Double(minimum), maximum: Double(maximum))
        drag = current
        // Draw from the finger's position during input, never delayed camera publications.
        wheel.zoom = value; wheel.setNeedsDisplay()
        let now = ProcessInfo.processInfo.systemUptime
        onZoom(CGFloat(value), now, sessionID)
        if let previousValue, factors.contains(where: {
            let stop = Double($0)
            return (previousValue < stop && value >= stop) || (previousValue > stop && value <= stop)
        }), now - lastFeedback > 0.08 {
            feedback.selectionChanged(); lastFeedback = now
        }
        previousValue = value
    }
    func endScrub() {
        guard drag != nil else { return }
        drag = nil; onEnd(sessionID)
        let work = DispatchWorkItem { [weak self] in self?.hideDial() }
        hideWork?.cancel(); hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
    func cancelInput() {
        let wasDragging = drag != nil
        drag = nil
        hideWork?.cancel(); hideWork = nil
        let wasVisible = isDialVisible
        wheel.isHidden = true; stack.layer.opacity = 1
        // Teardown/updateUIView callbacks must not mutate SwiftUI during its update.
        let end = onEnd, visibility = onVisibilityChanged, id = sessionID
        if wasDragging || wasVisible {
            DispatchQueue.main.async {
                if wasDragging { end(id) }
                if wasVisible { visibility(false) }
            }
        }
    }
    private func hideDial() {
        hideWork?.cancel(); hideWork = nil
        guard drag == nil else { return }
        wheel.isHidden = true; stack.layer.opacity = 1; onVisibilityChanged(false)
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { beginScrub() }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            if pan.state != .began && pan.state != .changed { endScrub() }
        }
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        handlePan(state: gesture.state, translation: Double(gesture.translation(in: self).x))
    }
    func handlePan(state: UIGestureRecognizer.State, translation: Double) {
        switch state {
        case .began: beginScrub(); scrub(translation: translation)
        case .changed: scrub(translation: translation)
        case .ended: scrub(translation: translation); endScrub()
        case .cancelled, .failed: endScrub()
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === pan && otherGestureRecognizer === hold) ||
            (gestureRecognizer === hold && otherGestureRecognizer === pan)
    }
    private func adjust(_ direction: Double) {
        beginScrub(); scrub(translation: -direction * ManualZoomScale.pointsPerDoubling / 10); endScrub()
    }
}

private final class ZoomWheelView: UIView {
    var zoom = 1.0, minimum = 1.0, maximum = 24.0, multiplier = 1.0
    var stops: [Double] = []
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), zoom.isFinite, zoom > 0,
              minimum > 0, maximum.isFinite, maximum > minimum else { return }
        let radius: CGFloat = 154
        let center = CGPoint(x: bounds.midX, y: 166)
        let cap = UIBezierPath(ovalIn: CGRect(x: center.x - radius - 8, y: 4,
            width: (radius + 8) * 2, height: (radius + 8) * 2))
        UIColor.black.withAlphaComponent(0.86).setFill(); cap.fill()
        let anglePerDoubling = ManualZoomScale.pointsPerDoubling / Double(radius)
        func point(_ factor: Double, radius r: CGFloat) -> CGPoint {
            let angle = log2(factor / zoom) * anglePerDoubling
            return CGPoint(x: center.x + CGFloat(sin(angle)) * r, y: center.y - CGFloat(cos(angle)) * r)
        }
        func tick(_ factor: Double, major: Bool, label: Bool) {
            let angle = log2(factor / zoom) * anglePerDoubling
            guard abs(angle) < 1.05 else { return }
            let alpha = max(0, min(1, (1.05 - abs(angle)) / 0.2))
            context.setStrokeColor(UIColor.white.withAlphaComponent(alpha * (major ? 0.95 : 0.4)).cgColor)
            context.setLineWidth(major ? 1.5 : 1)
            context.move(to: point(factor, radius: radius)); context.addLine(to: point(factor, radius: radius - (major ? 12 : 6)))
            context.strokePath()
            if label {
                let value = ManualZoomScale.label(factor * multiplier)
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(alpha)]
                let size = value.size(withAttributes: attrs), position = point(factor, radius: radius - 27)
                value.draw(at: CGPoint(x: position.x - size.width / 2, y: position.y - size.height / 2), withAttributes: attrs)
            }
        }
        let count = min(240, Int(ceil(log2(maximum / minimum) * 12)))
        for index in 0...count {
            let value = minimum * pow(2, Double(index) / 12)
            if value <= maximum { tick(value, major: false, label: false) }
        }
        for value in Set(stops + [minimum, maximum]).sorted() { tick(value, major: true, label: true) }
        context.setStrokeColor(UIColor.systemYellow.cgColor); context.setLineWidth(2); context.setLineCap(.round)
        context.move(to: CGPoint(x: bounds.midX, y: 5)); context.addLine(to: CGPoint(x: bounds.midX, y: 19)); context.strokePath()
        let value = ManualZoomScale.label(zoom * multiplier)
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.systemYellow]
        let size = value.size(withAttributes: attrs)
        value.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: 70), withAttributes: attrs)
    }
}
