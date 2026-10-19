import SwiftUI
import AVFoundation
import UIKit

struct PiPMeteringHit: Equatable {
    let front: Bool
    let point: CGPoint
}
enum PiPMeteringGeometry {
    static func hit(at point: CGPoint, canvas: CGSize, source: CGSize, angle: CGFloat,
                    panel: CGRect, zoom: CGFloat, front: Bool) -> PiPMeteringHit? {
        guard canvas.width > 0, canvas.height > 0, source.width > 0, source.height > 0,
              !panel.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
        let rect = CGRect(x: panel.minX * canvas.width, y: panel.minY * canvas.height,
            width: panel.width * canvas.width, height: panel.height * canvas.height)
        guard rect.contains(point) else { return nil }
        let local = CGPoint(x: point.x - rect.minX, y: rect.height - (point.y - rect.minY))
        let scale = PiPLayout.clampedZoom(zoom)
        let transform = LiveLookGeometry.transform(source: source, target: rect.size, angle: angle, front: false)
            .concatenating(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                tx: rect.width * (1 - scale) / 2, ty: rect.height * (1 - scale) / 2))
        let sensor = local.applying(transform.inverted())
        guard sensor.x.isFinite, sensor.y.isFinite else { return nil }
        return PiPMeteringHit(front: front, point: CGPoint(x: min(1, max(0, sensor.x / source.width)),
            y: min(1, max(0, 1 - sensor.y / source.height))))
    }
}

// Reuse the native focus square and sun-drag control. This surface has no capture
// session; it routes gestures to the camera underneath the touched composition.
struct PiPMeteringView: UIViewRepresentable {
    let frames: LiveFrames
    let presentation: PiPPresentation
    let front: CameraMetering?
    let rear: CameraMetering?
    var protectedRegions: [CGRect]
    let onFocus: (CGPoint, Bool, Bool) -> Bool
    let onExposure: (Float, Bool) -> Void
    let onMove: (CGPoint, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(frame: .zero)
        view.isOpaque = false; view.backgroundColor = .clear
        view.layer.backgroundColor = UIColor.clear.cgColor
        context.coordinator.view = view
        let move = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.move(_:)))
        move.minimumPressDuration = 0.35; move.delegate = context.coordinator
        for gesture in view.gestureRecognizers ?? [] where gesture is UILongPressGestureRecognizer { gesture.require(toFail: move) }
        view.addGestureRecognizer(move)
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.protectedRegions = protectedRegions
        view.meteringConversion = { point, size in
            guard let hit = coordinator.resolve(point, canvas: size) else { return nil }
            coordinator.selectedFront = hit.front
            coordinator.applyCapabilities()
            return hit.point
        }
        view.onFocus = { point, locked in onFocus(point, locked, coordinator.selectedFront) }
        view.onExposure = { bias in onExposure(bias, coordinator.selectedFront) }
        coordinator.applyCapabilities()
    }
    static func dismantleUIView(_ view: PreviewUIView, coordinator: Coordinator) { view.detachPreview() }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PiPMeteringView
        weak var view: PreviewUIView?
        var selectedFront = false
        private var moveStart: CGPoint?
        private var initialCenter: CGPoint?
        init(_ parent: PiPMeteringView) { self.parent = parent }
        func applyCapabilities() {
            guard let view, let options = selectedFront ? parent.front : parent.rear else { return }
            view.exposureBias = options.bias; view.exposureRange = options.range; view.locked = options.locked
        }
        func resolve(_ point: CGPoint, canvas: CGSize) -> PiPMeteringHit? {
            guard let snapshot = parent.frames.snapshot() else { return nil }
            let state = snapshot.pip?.presentation ?? parent.presentation
            guard state.opacity > 0.001 else { return nil }
            let presenter = state.composition == .inset ? state.rect : state.composition.presenterRect(swapped: state.splitSwapped) ?? state.rect
            let unit = CGPoint(x: point.x / max(1, canvas.width), y: point.y / max(1, canvas.height))
            let isFront = presenter.contains(unit)
            let panel = isFront ? presenter : state.composition == .inset ? CGRect(x: 0, y: 0, width: 1, height: 1) :
                state.composition.presenterRect(swapped: !state.splitSwapped) ?? .zero
            guard let buffer = isFront ? snapshot.pip?.presenter : snapshot.buffer else { return nil }
            let angle = isFront ? snapshot.pip?.presenterAngle ?? 90 : snapshot.pip?.backgroundAngle ?? snapshot.angle ?? 90
            return PiPMeteringGeometry.hit(at: point, canvas: canvas,
                source: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                angle: angle, panel: panel, zoom: isFront ? state.zoom : 1, front: isFront)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view, parent.presentation.composition == .inset,
                  view.permitsPreviewInteraction(at: touch.location(in: view)) else { return false }
            return resolve(touch.location(in: view), canvas: view.bounds.size)?.front == true
        }
        @objc func move(_ gesture: UILongPressGestureRecognizer) {
            guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let location = gesture.location(in: view)
            if gesture.state == .began {
                moveStart = location; initialCenter = CGPoint(x: parent.presentation.rect.midX, y: parent.presentation.rect.midY)
                view.resetMeteringIndicator(); UISelectionFeedbackGenerator().selectionChanged()
            }
            guard let moveStart, let initialCenter else { return }
            let point = CGPoint(x: initialCenter.x + (location.x - moveStart.x) / view.bounds.width,
                y: initialCenter.y + (location.y - moveStart.y) / view.bounds.height)
            let finished = gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed
            parent.onMove(point, finished)
            if finished { self.moveStart = nil; self.initialCenter = nil }
        }
    }
}
