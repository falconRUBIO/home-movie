import XCTest
@testable import HomeMovie

final class SceneEditHistoryTests: XCTestCase {
    private var initial: SceneEditState { SceneEditState(start: 0, end: 10, adjustments: .neutral, effects: .off) }
    func testEditorDeletionKeepsAnAdjacentClipOrAnEmptySession() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(SceneEditorSelection.afterDeleting(a, from: [a, b, c]), b)
        XCTAssertEqual(SceneEditorSelection.afterDeleting(b, from: [a, b, c]), c)
        XCTAssertEqual(SceneEditorSelection.afterDeleting(c, from: [a, b, c]), b)
        XCTAssertNil(SceneEditorSelection.afterDeleting(a, from: [a]))
        XCTAssertNil(SceneEditorSelection.afterDeleting(a, from: []))
    }
    func testFinishingInterruptedDragCapturesLatestValues() {
        var history = SceneEditHistory(initial), latest = initial
        history.begin(initial)
        latest.adjustments.exposure = -0.14
        latest.adjustments.brilliance = -0.24
        history.end(latest)
        XCTAssertFalse(history.isGrouping)
        XCTAssertEqual(history.current, latest)
        XCTAssertEqual(history.undo(), initial)
        XCTAssertEqual(history.redo(), latest)
    }
    func testDragIsOneUndoAndRedoRestoresCompleteRecipeWithoutObserverFeedback() {
        let original = initial
        var history = SceneEditHistory(original), changed = original
        history.begin(original)
        for i in 1...100 { changed.adjustments.contrast = Double(i) / 100; history.observe(changed) }
        XCTAssertFalse(history.canUndo)
        history.end(changed)
        XCTAssertEqual(history.undo(), original)
        history.observe(original) // SwiftUI delivers state observation after restoration.
        XCTAssertTrue(history.canRedo); XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(), changed)
        XCTAssertEqual(history.undo(), original); XCTAssertNil(history.undo())
    }
    func testNoOpDragPreservesRedoAndNewEditInvalidatesIt() {
        var history = SceneEditHistory(initial), next = initial
        next.adjustments.highlights = -0.5
        history.observe(next); _ = history.undo()
        history.begin(initial); history.end(initial)
        XCTAssertTrue(history.canRedo)
        next.adjustments.tint = 0.2; history.observe(next)
        XCTAssertFalse(history.canRedo)
    }
    func testUnobservedTransactionAndMixedTrimFXChangesRoundTrip() {
        var history = SceneEditHistory(initial), next = initial
        history.begin(initial)
        next.start = 2; next.end = 8
        next.effects.grainEnabled = true; next.effects.grainAmount = 0.6
        next.adjustments.hsl[.blue].saturation = -0.4
        history.end(next) // End may arrive before SwiftUI's change callback.
        history.observe(next)
        XCTAssertEqual(history.undo(), initial)
        XCTAssertEqual(history.redo(), next)
    }
    func testHistoryBoundAndIndependentSessions() {
        var history = SceneEditHistory(initial, limit: 3), state = initial
        for i in 1...5 { state.adjustments.brightness = Double(i) / 10; history.observe(state) }
        XCTAssertEqual(history.undo()?.adjustments.brightness, 0.4)
        XCTAssertEqual(history.undo()?.adjustments.brightness, 0.3)
        XCTAssertEqual(history.undo()?.adjustments.brightness, 0.2)
        XCTAssertNil(history.undo())
        let other = SceneEditHistory(initial)
        XCTAssertFalse(other.canUndo); XCTAssertFalse(other.canRedo)
    }
    func testSuggestedPastePreservesShotCorrectionsAndCopiesToneColorHSL() throws {
        var source = SceneAdjustments.neutral, target = SceneAdjustments.neutral
        source.exposure = 0.8; source.warmth = -0.4; source.tint = 0.7
        source.contrast = 0.3; source.fade = 0.2; source.curve.midtones = 0.6
        source.saturation = 0.6; source.hsl[.orange].hue = -0.2
        target.exposure = -0.3; target.warmth = 0.2; target.tint = -0.1
        let clipboard = try SceneAdjustmentClipboard(source: source, selection: .suggested)
        let pasted = try clipboard.applying(to: target)
        XCTAssertEqual(pasted.exposure, target.exposure); XCTAssertEqual(pasted.warmth, target.warmth); XCTAssertEqual(pasted.tint, target.tint)
        XCTAssertEqual(pasted.contrast, source.contrast); XCTAssertEqual(pasted.curve, source.curve)
        XCTAssertEqual(pasted.fade, source.fade); XCTAssertEqual(pasted.saturation, source.saturation); XCTAssertEqual(pasted.hsl, source.hsl)
        XCTAssertEqual(target.contrast, 0); XCTAssertEqual(source.exposure, 0.8)
        XCTAssertEqual(try JSONDecoder().decode(SceneAdjustments.self, from: JSONEncoder().encode(pasted)), pasted)
    }
    func testSelectivePasteCanExplicitlyIncludeExposureAndBalanceWithoutOtherEdits() throws {
        var source = SceneAdjustments.neutral, target = SceneAdjustments.neutral
        source.exposure = 0.5; source.warmth = -0.3; source.tint = 0.2; source.contrast = 0.9
        target.contrast = -0.2; target.hsl[.red].lightness = 0.4
        let pasted = try SceneAdjustmentClipboard(source: source, selection: [.exposure, .whiteBalance]).applying(to: target)
        XCTAssertEqual(pasted.exposure, 0.5); XCTAssertEqual(pasted.warmth, -0.3); XCTAssertEqual(pasted.tint, 0.2)
        XCTAssertEqual(pasted.contrast, target.contrast); XCTAssertEqual(pasted.hsl, target.hsl)
    }
    func testLegacyPasteNeverSilentlyChangesExistingProcessingAndRejectsInvalidCopy() throws {
        var old = SceneAdjustments.neutral, target = SceneAdjustments.neutral
        old.pipelineVersion = 1; old.contrast = 0.3
        let clipboard = try SceneAdjustmentClipboard(source: old, selection: .suggested)
        XCTAssertEqual(try clipboard.applying(to: target).pipelineVersion, 1)
        target.saturation = 0.2
        XCTAssertThrowsError(try clipboard.applying(to: target))
        XCTAssertThrowsError(try SceneAdjustmentClipboard(source: old, selection: []))
        old.contrast = .nan
        XCTAssertThrowsError(try SceneAdjustmentClipboard(source: old, selection: .suggested))
    }
}
