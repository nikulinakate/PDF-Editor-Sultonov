import XCTest
import PDFKit
import PDFEditorCore
import UIKit
@testable import PDFEditor

@MainActor
final class PDFEngineTests: XCTestCase {
    func testAnnotationsSurviveSaveAndReopen() throws {
        let session = try makeSession()
        try session.addText("Привет PDF", pageIndex: 0, bounds: CGRect(x: 30, y: 400, width: 180, height: 40), color: .blue)
        try session.addInk(strokes: [[CGPoint(x: 30, y: 200), CGPoint(x: 120, y: 220)]], pageIndex: 0, color: .black)
        try session.save()
        let reopened = try XCTUnwrap(PDFDocument(url: session.sourceURL))
        let annotations = try XCTUnwrap(reopened.page(at: 0)).annotations
        XCTAssertTrue(annotations.contains { $0.contents == "Привет PDF" })
        XCTAssertTrue(annotations.contains { $0.type == "Ink" && !($0.paths ?? []).isEmpty })
        XCTAssertFalse(session.isDirty)
    }

    func testPageOperationsAndUndoKeepCorrectOrder() throws {
        let session = try makeSession()
        try session.duplicatePage(at: 0)
        XCTAssertEqual(session.document.pageCount, 3)
        try session.movePage(from: 2, to: 0)
        XCTAssertTrue(session.document.page(at: 0)?.string?.contains("Second page") == true)
        try session.rotatePage(at: 0)
        XCTAssertEqual(session.document.page(at: 0)?.rotation, 90)
        try session.undo()
        XCTAssertEqual(session.document.page(at: 0)?.rotation, 0)
        try session.redo()
        XCTAssertEqual(session.document.page(at: 0)?.rotation, 90)
        try session.save()
        XCTAssertEqual(PDFDocument(url: session.sourceURL)?.pageCount, 3)
    }

    func testCannotDeleteLastPage() throws {
        let session = try makeSession()
        try session.removePage(at: 1)
        XCTAssertThrowsError(try session.removePage(at: 0)) { XCTAssertEqual($0 as? PDFEditorError, .lastPage) }
        XCTAssertEqual(session.document.pageCount, 1)
    }

    func testExtractionPreservesRequestedPages() throws {
        let session = try makeSession()
        let extracted = try XCTUnwrap(PDFDocument(data: session.extractPages([1])))
        XCTAssertEqual(extracted.pageCount, 1)
        XCTAssertTrue(extracted.page(at: 0)?.string?.contains("Second page") == true)
        XCTAssertEqual(session.document.pageCount, 2)
        XCTAssertThrowsError(try session.extractPages([99]))
    }

    func testMergeAndBlankPageCanBeUndone() throws {
        let session = try makeSession()
        let second = try makeSession()
        try session.appendDocument(url: second.sourceURL)
        XCTAssertEqual(session.document.pageCount, 4)
        try session.insertBlankPage(at: 4)
        XCTAssertEqual(session.document.pageCount, 5)
        try session.undo(); try session.undo()
        XCTAssertEqual(session.document.pageCount, 2)
    }

    func testFormsArePersistedAndUndoable() throws {
        let session = try makeSession()
        let page = try session.page(at: 0)
        let widget = PDFAnnotation(bounds: CGRect(x: 30, y: 100, width: 200, height: 35), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text; widget.fieldName = "Customer"; widget.widgetStringValue = "Original"
        page.addAnnotation(widget)
        try session.fillTextField(widget, value: "Alice")
        let saved = try XCTUnwrap(PDFDocument(data: session.serialized()))
        XCTAssertEqual(saved.page(at: 0)?.annotations.first(where: { $0.fieldName == "Customer" })?.widgetStringValue, "Alice")
        try session.undo()
        XCTAssertEqual(session.document.page(at: 0)?.annotations.first(where: { $0.fieldName == "Customer" })?.widgetStringValue, "Original")
    }

    func testImportedOriginalIsUnchangedAfterEditing() throws {
        let session = try makeSession()
        let library = LibraryStore(root: session.sourceURL.deletingLastPathComponent().appendingPathComponent("Library"))
        let record = try library.importPDF(from: session.sourceURL)
        let before = try Data(contentsOf: library.originalURL(for: record))
        let editing = try PDFEditingSession(url: library.url(for: record))
        try editing.rotatePage(at: 0); try editing.save()
        XCTAssertEqual(try Data(contentsOf: library.originalURL(for: record)), before)
        XCTAssertNotEqual(try Data(contentsOf: library.url(for: record)), before)
        try library.trash(record); XCTAssertTrue(library.records[0].isTrashed)
        try library.restore(record); XCTAssertFalse(library.records[0].isTrashed)
    }

    func testContentInspectionFindsOriginalTextAndCommands() throws {
        let session = try makeSession()
        let lines = try ContentAnalyzer.textLines(in: session.document, pageIndex: 0)
        XCTAssertTrue(lines.contains { $0.text.contains("First page") })
        let summary = try PDFStreamInspector.inspect(page: session.page(at: 0))
        XCTAssertGreaterThan(summary.textDrawingCommands, 0)
    }

    func testInvalidImportDoesNotCreateLibraryRecord() throws {
        let session = try makeSession()
        let library = LibraryStore(root: session.sourceURL.deletingLastPathComponent().appendingPathComponent("Library"))
        XCTAssertThrowsError(try library.add(data: Data("invalid".utf8), name: "Broken"))
        XCTAssertTrue(library.records.isEmpty)
    }

    func testEncryptedDocumentRemainsReadOnlyAndEncrypted() throws {
        let session = try makeSession()
        let data = try XCTUnwrap(session.document.dataRepresentation(options: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        let url = session.sourceURL.deletingLastPathComponent().appendingPathComponent("Protected.pdf")
        try data.write(to: url)
        let protected = try PDFEditingSession(url: url)
        XCTAssertTrue(protected.document.isLocked)
        XCTAssertFalse(protected.unlock(password: "wrong"))
        XCTAssertTrue(protected.unlock(password: "secret"))
        XCTAssertFalse(protected.canAnnotate)
        XCTAssertThrowsError(try protected.rotatePage(at: 0))
        XCTAssertEqual(try protected.serialized(), data)
    }

    private func makeSession() throws -> PDFEditingSession {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Fixture.pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for text in ["First page — Первый", "Second page"] {
                context.beginPage()
                (text as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black])
            }
        }
        try data.write(to: url)
        return try PDFEditingSession(url: url)
    }
}
