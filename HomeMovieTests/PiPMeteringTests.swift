import XCTest
import UIKit
import CoreImage
import MetalKit
@testable import HomeMovie

final class PiPMeteringTests: XCTestCase {
    @MainActor func testInsetDragStartsWithoutHoldingAndKeepsItsOriginalAnchor() throws {
        let canvas = CGSize(width: 390, height: 844)
        let view = PreviewUIView(frame: CGRect(origin: .zero, size: canvas))
        let state = PiPPresentation(rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.2), opacity: 1, enabled: true)
        var moves: [(CGPoint, Bool)] = []
        func surface(_ presentation: PiPPresentation) -> PiPMeteringView {
            PiPMeteringView(frames: LiveFrames(), presentation: presentation, useLivePresentation: false,
                front: nil, rear: nil, protectedRegions: [], onFocus: { _, _, _ in true },
                onExposure: { _, _ in }, onMove: { moves.append(($0, $1)) })
        }
        let coordinator = surface(state).makeCoordinator(); coordinator.view = view
        let center = CGPoint(x: state.rect.midX * canvas.width, y: state.rect.midY * canvas.height)
        XCTAssertTrue(coordinator.canBeginMove(at: center, canvas: canvas))
        XCTAssertTrue(coordinator.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
        coordinator.handleMove(state: .began, translation: CGPoint(x: -8, y: -3), canvas: canvas)
        XCTAssertEqual(moves.count, 1) // First pan updates immediately, with no timer/hold.
        var newer = state; newer.rect.origin = CGPoint(x: 0.4, y: 0.4)
        coordinator.parent = surface(newer)
        coordinator.handleMove(state: .changed, translation: CGPoint(x: -180, y: -350), canvas: canvas)
        let point = try XCTUnwrap(moves.last?.0)
        XCTAssertEqual(point.x, state.rect.midX - 180 / canvas.width, accuracy: 0.0001)
        XCTAssertEqual(point.y, state.rect.midY - 350 / canvas.height, accuracy: 0.0001)
        coordinator.handleMove(state: .ended, translation: CGPoint(x: -180, y: -350), canvas: canvas)
        XCTAssertEqual(moves.last?.1, true)
        let count = moves.count
        coordinator.handleMove(state: .cancelled, translation: .zero, canvas: canvas)
        XCTAssertEqual(moves.count, count)
        view.detachPreview()
    }

    @MainActor func testInsetDragLeavesControlsExposureHandleAndSplitPanelsAlone() {
        let canvas = CGSize(width: 390, height: 844)
        let view = PreviewUIView(frame: CGRect(origin: .zero, size: canvas))
        let state = PiPPresentation(rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.2), opacity: 1, enabled: true)
        func surface(_ state: PiPPresentation) -> PiPMeteringView {
            PiPMeteringView(frames: LiveFrames(), presentation: state, useLivePresentation: false,
                front: nil, rear: nil, protectedRegions: [], onFocus: { _, _, _ in true },
                onExposure: { _, _ in }, onMove: { _, _ in })
        }
        let coordinator = surface(state).makeCoordinator(); coordinator.view = view
        let center = CGPoint(x: state.rect.midX * canvas.width, y: state.rect.midY * canvas.height)
        XCTAssertTrue(coordinator.canBeginMove(at: center, canvas: canvas))
        XCTAssertFalse(coordinator.canBeginMove(at: CGPoint(x: 20, y: 20), canvas: canvas))
        view.protectedRegions = [CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)]
        XCTAssertFalse(coordinator.canBeginMove(at: center, canvas: canvas))
        view.protectedRegions = []
        view.meteringConversion = { _, _ in CGPoint(x: 0.5, y: 0.5) }
        view.onFocus = { _, _ in true }
        view.requestFocus(at: center, locked: false)
        let sun = CGPoint(x: center.x + 50, y: center.y)
        XCTAssertTrue(view.isExposureHandle(at: sun))
        XCTAssertFalse(coordinator.canBeginMove(at: sun, canvas: canvas))
        var off = state; off.enabled = false
        coordinator.parent = surface(off)
        XCTAssertFalse(coordinator.canBeginMove(at: center, canvas: canvas))
        var split = state; split.composition = .sideBySide
        coordinator.parent = surface(split)
        XCTAssertFalse(coordinator.canBeginMove(at: center, canvas: canvas))
        view.detachPreview()
    }

    func testTouchMappingInvertsTheActualCropRotationAndFramingZoom() throws {
        let canvas = CGSize(width: 390, height: 844), source = CGSize(width: 128, height: 72)
        for panel in [CGRect(x: 0.65, y: 0.6, width: 0.3, height: 0.25), CGRect(x: 0, y: 0, width: 0.5, height: 1)] {
            let rect = CGRect(x: panel.minX * canvas.width, y: panel.minY * canvas.height,
                width: panel.width * canvas.width, height: panel.height * canvas.height)
            for angle: CGFloat in [0, 90, 180, 270] {
                for zoom: CGFloat in [1, 2] {
                    let sensor = CGPoint(x: 0.49, y: 0.51)
                    let transform = LiveLookGeometry.transform(source: source, target: rect.size, angle: angle, front: false)
                        .concatenating(CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                            tx: rect.width * (1 - zoom) / 2, ty: rect.height * (1 - zoom) / 2))
                    let local = CGPoint(x: sensor.x * source.width, y: (1 - sensor.y) * source.height).applying(transform)
                    let touch = CGPoint(x: rect.minX + local.x, y: rect.minY + rect.height - local.y)
                    let hit = try XCTUnwrap(PiPMeteringGeometry.hit(at: touch, canvas: canvas, source: source,
                        angle: angle, panel: panel, zoom: zoom, front: true))
                    XCTAssertTrue(hit.front)
                    XCTAssertEqual(hit.point.x, sensor.x, accuracy: 0.00001)
                    XCTAssertEqual(hit.point.y, sensor.y, accuracy: 0.00001)
                }
            }
            XCTAssertNil(PiPMeteringGeometry.hit(at: CGPoint(x: -1, y: -1), canvas: canvas, source: source,
                angle: 90, panel: panel, zoom: 1, front: true))
        }
    }
    @MainActor func testSettingsPreviewRoutesBothCamerasInInsetAndSwappedSplits() throws {
        let rear = LiveFrames(), front = LiveFrames()
        let buffer = try XCTUnwrap(PiPFrameRenderer().render(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)), canvas: CGSize(width: 64, height: 64)))
        rear.push(buffer, angle: 90); front.push(buffer, angle: 0)
        let canvas = CGSize(width: 390, height: 844)
        for composition: PiPComposition in [.inset, .sideBySide, .topAndBottom] {
            for swapped in [false, true] {
                let state = PiPPresentation(composition: composition, splitSwapped: swapped,
                    rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.3), opacity: 1, enabled: true)
                let surface = PiPMeteringView(frames: rear, presentation: state, presenterFrames: front,
                    backgroundFrames: rear, useLivePresentation: false, front: nil, rear: nil, protectedRegions: [],
                    onFocus: { _, _, _ in true }, onExposure: { _, _ in }, onMove: { _, _ in })
                let coordinator = surface.makeCoordinator()
                let frontRect: CGRect
                if composition == .inset { frontRect = state.rect }
                else { frontRect = try XCTUnwrap(composition.presenterRect(swapped: swapped)) }
                let frontPoint = CGPoint(x: frontRect.midX * canvas.width, y: frontRect.midY * canvas.height)
                XCTAssertEqual(coordinator.resolve(frontPoint, canvas: canvas)?.front, true)
                let rearRect: CGRect
                if composition == .inset { rearRect = CGRect(x: 0, y: 0, width: 0.5, height: 0.5) }
                else { rearRect = try XCTUnwrap(composition.presenterRect(swapped: !swapped)) }
                let rearPoint = CGPoint(x: rearRect.midX * canvas.width, y: rearRect.midY * canvas.height)
                XCTAssertEqual(coordinator.resolve(rearPoint, canvas: canvas)?.front, false)
            }
        }
    }
    @MainActor func testOffPreviewMetersRearAcrossTheFullCanvasForEverySavedLayout() throws {
        let rear = LiveFrames(), front = LiveFrames()
        let buffer = try XCTUnwrap(PiPFrameRenderer().render(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)), canvas: CGSize(width: 64, height: 64)))
        rear.push(buffer, angle: 90); front.push(buffer, angle: 90)
        let canvas = CGSize(width: 390, height: 844)
        for composition in PiPComposition.allCases {
            for swapped in [false, true] {
                let layout = PiPLayout(composition: composition, splitSwapped: swapped)
                for opacity: CGFloat in [0, 0.5] {
                    var state = layout.previewPresentation(enabled: false, canvas: canvas)
                    state.opacity = opacity // Off must also target rear during the fade-out.
                    let surface = PiPMeteringView(frames: rear, presentation: state,
                        presenterFrames: front, useLivePresentation: false,
                        front: nil, rear: nil, protectedRegions: [], onFocus: { _, _, _ in true },
                        onExposure: { _, _ in }, onMove: { _, _ in })
                    let coordinator = surface.makeCoordinator()
                    for point in [CGPoint(x: 30, y: 30), CGPoint(x: 195, y: 422), CGPoint(x: 360, y: 800)] {
                        let hit = try XCTUnwrap(coordinator.resolve(point, canvas: canvas))
                        XCTAssertFalse(hit.front)
                    }
                }
            }
        }
    }

    @MainActor func testLiveDragRecipeAndPanelChangesKeepMeteringInSync() throws {
        let frames = LiveFrames()
        let rear = try XCTUnwrap(PiPFrameRenderer().render(CIImage(color: .blue), canvas: CGSize(width: 64, height: 64)))
        let front = try XCTUnwrap(PiPFrameRenderer().render(CIImage(color: .red), canvas: CGSize(width: 64, height: 64)))
        let canvas = CGSize(width: 390, height: 844)
        let original = PiPPresentation(rect: CGRect(x: 0.6, y: 0.6, width: 0.3, height: 0.2), opacity: 1, enabled: true)
        var moved = original; moved.rect.origin = CGPoint(x: 0.1, y: 0.1)
        frames.push(rear, angle: 90, pip: LivePiPFrame(presenter: front, backgroundAngle: 90,
            presenterAngle: 90, presentation: moved))
        func surface(_ state: PiPPresentation) -> PiPMeteringView {
            PiPMeteringView(frames: frames, presentation: state,
                front: nil, rear: nil, protectedRegions: [], onFocus: { _, _, _ in true },
                onExposure: { _, _ in }, onMove: { _, _ in })
        }
        let view = PreviewUIView(frame: CGRect(origin: .zero, size: canvas))
        let coordinator = surface(original).makeCoordinator(); coordinator.view = view
        // A moving live recipe wins over a slower layout publication, as in the settings sheet.
        let newCenter = CGPoint(x: moved.rect.midX * canvas.width, y: moved.rect.midY * canvas.height)
        let oldCenter = CGPoint(x: original.rect.midX * canvas.width, y: original.rect.midY * canvas.height)
        XCTAssertEqual(coordinator.resolve(newCenter, canvas: canvas)?.front, true)
        XCTAssertEqual(coordinator.resolve(oldCenter, canvas: canvas)?.front, false)
        coordinator.selectedFront = true
        var off = moved; off.enabled = false; off.opacity = 0
        coordinator.updateParent(surface(off))
        XCTAssertFalse(coordinator.selectedFront)
        frames.push(rear, angle: 90, pip: LivePiPFrame(presenter: front, backgroundAngle: 90,
            presenterAngle: 90, presentation: off))
        XCTAssertEqual(coordinator.resolve(newCenter, canvas: canvas)?.front, false)
        var split = moved; split.composition = .sideBySide
        coordinator.updateParent(surface(split)); coordinator.selectedFront = true
        split.splitSwapped = true
        coordinator.updateParent(surface(split))
        XCTAssertFalse(coordinator.selectedFront)
        view.detachPreview()
    }

    @MainActor func testCustomMeteringUsesRoutedCoordinatesAndHonorsProtectedControls() {
        let view = PreviewUIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        var calls = 0
        view.meteringConversion = { _, _ in CGPoint(x: 0.25, y: 0.75) }
        view.onFocus = { point, locked in
            calls += 1; XCTAssertEqual(point, CGPoint(x: 0.25, y: 0.75)); XCTAssertFalse(locked); return true
        }
        view.requestFocus(at: CGPoint(x: 300, y: 600), locked: false)
        XCTAssertEqual(calls, 1)
        view.protectedRegions = [CGRect(x: 0, y: 0, width: 390, height: 100)]
        view.requestFocus(at: CGPoint(x: 100, y: 40), locked: false)
        XCTAssertEqual(calls, 1)
        view.detachPreview()
    }
    @MainActor func testSampleAndPiPPreviewsApplySelectedLookOnceAndOriginalStaysLog() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(LiveLookRenderer(device: device))
        var data: [Float] = []
        for b in 0...1 { for g in 0...1 { for r in 0...1 { data += [Float(r) * 0.5, Float(g) * 0.5, Float(b) * 0.5, 1] } } }
        let cube = data.withUnsafeBytes { ColorCube(name: "Half", dimension: 2, rgba: Data($0)) }
        let frames = LiveFrames(), context = CIContext(options: LogPiPColor.contextOptions())
        func frame(_ value: CGFloat) throws -> CVPixelBuffer {
            try XCTUnwrap(PiPFrameRenderer(profile: .appleLog).render(
                CIImage(color: CIColor(red: value, green: value, blue: value)), canvas: CGSize(width: 64, height: 64)))
        }
        func sample(_ image: CIImage, x: Int) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: x, y: 32, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
            return pixel[0]
        }
        let rear = try frame(0.4), front = try frame(0.8)
        let state = PiPPresentation(composition: .sideBySide, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), opacity: 1, enabled: true)
        let pip = LivePiPFrame(presenter: front, backgroundAngle: 0, presenterAngle: 0, presentation: state)
        renderer.configure(frames: frames, cube: cube, active: true, passthrough: true, logSource: true)
        let graded = try renderer.previewImage(rear, to: CGSize(width: 128, height: 64), pip: pip)
        XCTAssertEqual(sample(graded, x: 32), 0.2, accuracy: 0.02)
        XCTAssertEqual(sample(graded, x: 96), 0.4, accuracy: 0.02)
        let single = try renderer.previewImage(rear, to: CGSize(width: 64, height: 64), pip: nil)
        XCTAssertEqual(sample(single, x: 32), 0.2, accuracy: 0.02)
        renderer.configure(frames: frames, cube: nil, active: true, passthrough: true, logSource: true)
        let original = try renderer.previewImage(rear, to: CGSize(width: 128, height: 64), pip: pip)
        XCTAssertEqual(sample(original, x: 32), 0.4, accuracy: 0.02)
        XCTAssertEqual(sample(original, x: 96), 0.8, accuracy: 0.02)
        XCTAssertEqual(sample(CIImage(cvPixelBuffer: rear, options: [.colorSpace: NSNull()]), x: 32), 0.4, accuracy: 0.02)
        XCTAssertTrue(LogPiPColor.isLog(rear)); XCTAssertTrue(LogPiPColor.isLog(front))
    }
}
