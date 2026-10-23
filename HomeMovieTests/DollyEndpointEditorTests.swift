import XCTest
@testable import HomeMovie

final class DollyEndpointEditorTests: XCTestCase {
    func testLensSelectionEditsOnlyTheChosenPointAndOnlyStartRequestsPreview() {
        var editor = DollyEndpointEditor(start: 1, end: 4)
        XCTAssertEqual(editor.selected, .end)
        XCTAssertNil(editor.edit(8, endpoint: editor.selected, minimum: 0.5, maximum: 24))
        XCTAssertEqual(editor.start, 1); XCTAssertEqual(editor.end, 8)
        editor.selected = .start
        XCTAssertEqual(editor.start, 1, "Selecting Start must not move or rewrite it")
        XCTAssertEqual(editor.edit(2, endpoint: editor.selected, minimum: 0.5, maximum: 24), 2)
        XCTAssertEqual(editor.start, 2); XCTAssertEqual(editor.end, 8)
        XCTAssertNil(editor.edit(0.5, endpoint: .end, minimum: 0.5, maximum: 24))
        XCTAssertEqual(editor.start, 2); XCTAssertEqual(editor.end, 0.5, "Zoom-out endpoints must not be sorted or swapped")
    }
    func testEndScrubbingPreviewsEachValueAndReturnsToStartOnce() {
        var editor = DollyEndpointEditor(start: 2, end: 8)
        for value in [4.0, 12.0, 0.5] {
            XCTAssertEqual(editor.edit(value, endpoint: .end, minimum: 0.5, maximum: 24, isScrubbing: true), value)
            XCTAssertEqual(editor.start, 2)
        }
        XCTAssertEqual(editor.finishScrubbing(), 2)
        XCTAssertEqual(editor.end, 0.5)
        XCTAssertNil(editor.finishScrubbing(), "Release and gesture cancellation must not restore twice")
    }
    func testStartScrubbingKeepsNewFramingOnRelease() {
        var editor = DollyEndpointEditor(start: 1, end: 8)
        XCTAssertEqual(editor.edit(3, endpoint: .start, minimum: 0.5, maximum: 24, isScrubbing: true), 3)
        XCTAssertNil(editor.finishScrubbing())
        XCTAssertEqual(editor.start, 3)
        XCTAssertEqual(editor.end, 8)
    }
    func testTrackTapSelectsWithoutChangingValuesAndOverlapsKeepExplicitSelection() {
        var editor = DollyEndpointEditor(start: 1, end: 8)
        editor.selectNearest(position: 0.15, startPosition: 0.1, endPosition: 0.9)
        XCTAssertEqual(editor.selected, .start)
        XCTAssertEqual(editor.start, 1); XCTAssertEqual(editor.end, 8)
        editor.selectNearest(position: 0.85, startPosition: 0.1, endPosition: 0.9)
        XCTAssertEqual(editor.selected, .end)
        for selected in DollyEndpoint.allCases {
            editor.selected = selected
            editor.selectNearest(position: 0.5, startPosition: 0.5, endPosition: 0.5)
            XCTAssertEqual(editor.selected, selected)
            editor.selectNearest(position: 0.5, startPosition: 0.1, endPosition: 0.9)
            XCTAssertEqual(editor.selected, selected)
        }
        XCTAssertEqual(editor.start, 1); XCTAssertEqual(editor.end, 8)
    }
    func testDeviceBoundsAndInvalidInputNeverCorruptTheOtherEndpoint() {
        var editor = DollyEndpointEditor(start: 2, end: 16)
        XCTAssertNil(editor.edit(.nan, endpoint: .start, minimum: 1, maximum: 48))
        XCTAssertNil(editor.edit(0, endpoint: .end, minimum: 1, maximum: 48))
        XCTAssertNil(editor.edit(4, endpoint: .start, minimum: 8, maximum: 1))
        editor.selectNearest(position: .infinity, startPosition: 0, endPosition: 1)
        XCTAssertEqual(editor.start, 2); XCTAssertEqual(editor.end, 16); XCTAssertEqual(editor.selected, .end)
        XCTAssertNil(editor.edit(100, endpoint: .end, minimum: 1, maximum: 48))
        XCTAssertEqual(editor.end, 48); XCTAssertEqual(editor.start, 2)
        XCTAssertEqual(editor.edit(0.5, endpoint: .start, minimum: 1, maximum: 48), 1)
        XCTAssertEqual(editor.end, 48)
    }
}
