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
    var presenterFrames: LiveFrames? = nil
    var backgroundFrames: LiveFrames? = nil
    var useLivePresentation = true
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
        let move = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.move(_:)))
        move.maximumNumberOfTouches = 1; move.delegate = context.coordinator
        for gesture in view.gestureRecognizers ?? [] where gesture is UITapGestureRecognizer { gesture.require(toFail: move) }
        view.addGestureRecognizer(move)
        return view
    }
    func updateUIView(_ view: PreviewUIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        view.protectedRegions = protectedRegions
        view.insetDragHitTest = { [weak view, weak coordinator] point in
            guard let view else { return false }
            return coordinator?.canBeginMove(at: point, canvas: view.bounds.size) == true
        }
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
        private var initialCenter: CGPoint?
        private let moveFeedback = UISelectionFeedbackGenerator()
        init(_ parent: PiPMeteringView) { self.parent = parent }
        func applyCapabilities() {
            guard let view, let options = selectedFront ? parent.front : parent.rear else { return }
            view.exposureBias = options.bias; view.exposureRange = options.range; view.locked = options.locked
        }
        func resolve(_ point: CGPoint, canvas: CGSize) -> PiPMeteringHit? {
            guard let snapshot = parent.backgroundFrames?.snapshot() ?? parent.frames.snapshot() else { return nil }
            let state = parent.useLivePresentation ? snapshot.pip?.presentation ?? parent.presentation : parent.presentation
            guard state.opacity > 0.001 else { return nil }
            let presenter = state.composition == .inset ? state.rect : state.composition.presenterRect(swapped: state.splitSwapped) ?? state.rect
            let unit = CGPoint(x: point.x / max(1, canvas.width), y: point.y / max(1, canvas.height))
            let isFront = presenter.contains(unit)
            let panel = isFront ? presenter : state.composition == .inset ? CGRect(x: 0, y: 0, width: 1, height: 1) :
                state.composition.presenterRect(swapped: !state.splitSwapped) ?? .zero
            let presenterSnapshot = parent.presenterFrames?.snapshot()
            guard let buffer = isFront ? (snapshot.pip?.presenter ?? presenterSnapshot?.buffer) : snapshot.buffer else { return nil }
            let observed = isFront ? presenterSnapshot?.angle ?? 90 : snapshot.angle ?? 90
            let fallbackAngle = (MovieFormat.captureFormat(angle: observed) ?? .portrait).recordingAngle(observed: observed)
            let angle = isFront ? snapshot.pip?.presenterAngle ?? fallbackAngle : snapshot.pip?.backgroundAngle ?? fallbackAngle
            return PiPMeteringGeometry.hit(at: point, canvas: canvas,
                source: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                angle: angle, panel: panel, zoom: isFront ? state.zoom : 1, front: isFront)
        }
        private var currentPresentation: PiPPresentation {
            parent.useLivePresentation ? parent.frames.snapshot()?.pip?.presentation ?? parent.presentation : parent.presentation
        }
        func canBeginMove(at point: CGPoint, canvas: CGSize) -> Bool {
            let state = currentPresentation
            guard state.enabled, state.opacity > 0.001, state.composition == .inset,
                  canvas.width > 0, canvas.height > 0, let view,
                  view.permitsPreviewInteraction(at: point), !view.isExposureHandle(at: point) else { return false }
            return state.rect.contains(CGPoint(x: point.x / canvas.width, y: point.y / canvas.height))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view else { return false }
            return canBeginMove(at: touch.location(in: view), canvas: view.bounds.size)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // This pan moves an inset, independent of the preview's exposure-pan heuristic.
            let state = currentPresentation
            return state.enabled && state.opacity > 0.001 && state.composition == .inset
        }
        @objc func move(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            handleMove(state: gesture.state, translation: gesture.translation(in: view), canvas: view.bounds.size)
        }
        // The UIKit pan and regression tests share the same drag lifecycle.
        func handleMove(state: UIGestureRecognizer.State, translation: CGPoint, canvas: CGSize) {
            guard canvas.width > 0, canvas.height > 0 else { initialCenter = nil; return }
            if state == .began {
                let presentation = currentPresentation
                guard presentation.enabled, presentation.composition == .inset else { return }
                initialCenter = CGPoint(x: presentation.rect.midX, y: presentation.rect.midY)
                view?.resetMeteringIndicator(); moveFeedback.prepare()
            }
            guard let initialCenter else { return }
            let point = CGPoint(x: initialCenter.x + translation.x / canvas.width,
                y: initialCenter.y + translation.y / canvas.height)
            let finished = state == .ended || state == .cancelled || state == .failed
            parent.onMove(point, finished)
            if finished {
                if state == .ended { moveFeedback.selectionChanged() }
                self.initialCenter = nil
            }
        }
    }
}
