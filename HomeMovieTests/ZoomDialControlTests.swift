import XCTest
import UIKit
@testable import HomeMovie

@MainActor final class ZoomDialControlTests: XCTestCase {
    private let lenses = [LensChoice(factor: 0.5, displayed: 0.5), LensChoice(factor: 1, displayed: 1),
        LensChoice(factor: 2, displayed: 2), LensChoice(factor: 4, displayed: 4), LensChoice(factor: 8, displayed: 8)]
    private func configure(_ view: ZoomDialControlView, zoom: CGFloat = 1, enabled: Bool = true,
                           onBegin: @escaping (UUID) -> Void = { _ in },
                           onZoom: @escaping (CGFloat, Double, UUID) -> Void = { _, _, _ in },
                           onEnd: @escaping (UUID) -> Void = { _ in }) {
        view.configure(lenses: lenses, zoom: zoom, multiplier: 1, minimum: 0.5, maximum: 24,
            enabled: enabled, reservedTrailingWidth: 100, onLens: { _ in },
            onBegin: onBegin, onZoom: onZoom, onEnd: onEnd, onVisibilityChanged: { _ in })
        view.layoutIfNeeded()
    }
    func testFirstDragRevealsAndUpdatesNativeWheelBeforeReleaseOrCameraPublication() {
        let view = ZoomDialControlView(frame: CGRect(x: 0, y: 0, width: 360, height: 104))
        var samples: [CGFloat] = []
        var beganWhileVisible = false
        configure(view, onBegin: { _ in beganWhileVisible = view.isDialVisible },
            onZoom: { value, _, _ in
                XCTAssertTrue(view.isDialVisible)
                samples.append(value)
            })
        XCTAssertFalse(view.isDialVisible)
        view.handlePan(state: .began, translation: -6)
        XCTAssertTrue(beganWhileVisible)
        XCTAssertTrue(view.isDialVisible)
        XCTAssertEqual(samples.count, 1)
        view.handlePan(state: .changed, translation: -48)
        XCTAssertEqual(view.displayedZoom, 2, accuracy: 0.00001)
        // A slower measured camera update cannot move the wheel away from the finger.
        configure(view, zoom: 1)
        XCTAssertEqual(view.displayedZoom, 2, accuracy: 0.00001)
        view.handlePan(state: .ended, translation: -48)
        XCTAssertTrue(view.isDialVisible)
        view.cancelInput()
    }
    func testDialIsCenteredAndFitsWithoutAnOffsetOrLayoutChange() {
        for width: CGFloat in [300, 360] {
            let view = ZoomDialControlView(frame: CGRect(x: 0, y: 0, width: width, height: 104))
            configure(view)
            let original = view.lensFrame
            XCTAssertFalse(view.point(inside: CGPoint(x: width / 2, y: 10), with: nil))
            view.beginScrub()
            XCTAssertEqual(view.dialFrame.midX, view.bounds.midX)
            XCTAssertEqual(view.dialFrame, view.bounds)
            XCTAssertEqual(view.lensFrame, original)
            XCTAssertTrue(view.point(inside: CGPoint(x: width / 2, y: 30), with: nil))
            // Do not steal the separate Dolly/PiP controls.
            XCTAssertFalse(view.point(inside: CGPoint(x: width - 20, y: 80), with: nil))
            view.cancelInput()
        }
    }
    func testHoldDoesNotChangeZoomAndCancellationEndsOnlyOnce() async {
        let view = ZoomDialControlView(frame: CGRect(x: 0, y: 0, width: 360, height: 104))
        var starts = 0, ends = 0, samples = 0
        configure(view, zoom: 4, onBegin: { _ in starts += 1 }, onZoom: { _, _, _ in samples += 1 }, onEnd: { _ in ends += 1 })
        view.beginScrub(); view.beginScrub()
        XCTAssertEqual(starts, 1); XCTAssertEqual(samples, 0)
        XCTAssertEqual(view.displayedZoom, 4)
        view.cancelInput(); view.cancelInput()
        XCTAssertFalse(view.isDialVisible)
        await Task.yield()
        // Drain the main-queue teardown callback.
        let done = expectation(description: "Cancellation delivered")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(ends, 1)
        configure(view, enabled: false)
        view.handlePan(state: .began, translation: -48)
        XCTAssertFalse(view.isDialVisible)
    }
    func testCompactTravelAndImmediateReversalAtBothRangeLimits() {
        var drag = ManualZoomDrag(start: 1)
        XCTAssertEqual(drag.update(translation: -144, minimum: 0.5, maximum: 24), 8, accuracy: 0.00001)
        XCTAssertEqual(drag.update(translation: -1000, minimum: 0.5, maximum: 24), 24, accuracy: 0.00001)
        XCTAssertLessThan(drag.update(translation: -999, minimum: 0.5, maximum: 24), 24)
        XCTAssertEqual(drag.update(translation: 1000, minimum: 0.5, maximum: 24), 0.5, accuracy: 0.00001)
        XCTAssertGreaterThan(drag.update(translation: 999, minimum: 0.5, maximum: 24), 0.5)
    }
}
