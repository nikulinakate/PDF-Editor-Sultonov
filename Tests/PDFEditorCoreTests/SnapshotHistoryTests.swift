import XCTest
@testable import PDFEditorCore

final class SnapshotHistoryTests: XCTestCase {
    func testUndoRedoRoundTrip() {
        var history = SnapshotHistory()
        history.record(Data([1])); history.record(Data([2]))
        XCTAssertEqual(history.undo(current: Data([3])), Data([2]))
        XCTAssertEqual(history.undo(current: Data([2])), Data([1]))
        XCTAssertEqual(history.redo(current: Data([1])), Data([2]))
        XCTAssertEqual(history.redo(current: Data([2])), Data([3]))
    }
    func testNewEditClearsRedoBranch() {
        var history = SnapshotHistory()
        history.record(Data([1])); _ = history.undo(current: Data([2]))
        history.record(Data([1]))
        XCTAssertFalse(history.canRedo)
        XCTAssertNil(history.redo(current: Data([4])))
    }
    func testHistoryHonorsCountAndByteLimits() {
        var history = SnapshotHistory(maximumEntries: 2, maximumBytes: 5)
        history.record(Data([1, 1])); history.record(Data([2, 2])); history.record(Data([3, 3]))
        XCTAssertEqual(history.undoEntries, [Data([2, 2]), Data([3, 3])])
        history.record(Data(repeating: 4, count: 10))
        XCTAssertEqual(history.undoEntries.count, 1)
        XCTAssertEqual(history.undo(current: Data([5])), Data(repeating: 4, count: 10))
    }
    func testEmptyHistoryIsSafe() {
        var history = SnapshotHistory(maximumEntries: 0, maximumBytes: 0)
        XCTAssertNil(history.undo(current: Data()))
        XCTAssertNil(history.redo(current: Data()))
        history.record(Data([1])); history.clear()
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }
}
