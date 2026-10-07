import XCTest
@testable import PDFEditorCore

final class DocumentPolicyTests: XCTestCase {
    func testFilenamePreservesUnicodeAndNormalizesExtension() throws {
        XCTAssertEqual(try DocumentPolicy.filename("  Договор.PDF  "), "Договор.pdf")
        XCTAssertEqual(try DocumentPolicy.filename("Report"), "Report.pdf")
    }
    func testPathTraversalAndInvalidNamesAreRejected() {
        for value in ["../secret", "a/b", "a\\b", "a:b", "\n", "..", ".", "\0", String(repeating: "x", count: 181)] {
            XCTAssertThrowsError(try DocumentPolicy.filename(value), value)
        }
    }
    func testPageRangeDeduplicatesAndUsesZeroBasedIndices() throws {
        XCTAssertEqual(try DocumentPolicy.pageIndices("1, 3-5, 3", pageCount: 5), [0, 2, 3, 4])
    }
    func testInvalidPageRangesAreRejected() {
        for value in ["", "0", "6", "5-3", "1-", "-2", "1,,2", "1-2-3", "abc", "1, "] {
            XCTAssertThrowsError(try DocumentPolicy.pageIndices(value, pageCount: 5), value)
        }
    }
    func testReorderingUsesFinalDestinationIndex() throws {
        XCTAssertEqual(try DocumentPolicy.movedOrder(count: 4, from: 0, to: 3), [1, 2, 3, 0])
        XCTAssertEqual(try DocumentPolicy.movedOrder(count: 4, from: 3, to: 0), [3, 0, 1, 2])
        XCTAssertThrowsError(try DocumentPolicy.movedOrder(count: 4, from: 0, to: 4))
    }
    func testMalformedPDFCannotEnableSourceEditing() {
        XCTAssertTrue(ContentCapabilities().canReplaceExistingText)
        XCTAssertFalse(ContentCapabilities().canPermanentlyRedact)
        XCTAssertThrowsError(try NativeContentEditor(data: Data("invalid".utf8)))
    }
}
