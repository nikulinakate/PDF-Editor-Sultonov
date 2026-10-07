import XCTest
import PDFKit
@testable import PDFEditorCore
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

    func testMarkupAndAnnotationDeletionAreUndoable() throws {
        let session = try makeSession()
        let page = try session.page(at: 0)
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 5)))
        try session.addMarkup(selection: selection, kind: .highlight, color: .yellow)
        let annotation = try XCTUnwrap(page.annotations.first(where: { $0.type == "Highlight" }))
        try session.removeAnnotation(annotation)
        XCTAssertTrue(page.annotations.isEmpty)
        try session.undo()
        let reopened = try XCTUnwrap(PDFDocument(data: session.serialized()))
        XCTAssertTrue(reopened.page(at: 0)?.annotations.contains { $0.type == "Highlight" } == true)
    }

    func testFailedExportDoesNotReplaceWorkingFile() throws {
        let session = try makeSession()
        let before = try Data(contentsOf: session.sourceURL)
        try session.rotatePage(at: 0)
        XCTAssertThrowsError(try session.export(to: session.sourceURL.deletingLastPathComponent()))
        XCTAssertEqual(try Data(contentsOf: session.sourceURL), before)
        XCTAssertTrue(session.isDirty)
    }

    func testOnDeviceOCRRecognizesRenderedPage() async throws {
        let session = try makeSession()
        let text = try await OCRService.recognize(page: session.page(at: 0))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("First page"), text)
    }

    func testInvalidImportDoesNotCreateLibraryRecord() throws {
        let session = try makeSession()
        let library = LibraryStore(root: session.sourceURL.deletingLastPathComponent().appendingPathComponent("Library"))
        XCTAssertThrowsError(try library.add(data: Data("invalid".utf8), name: "Broken"))
        XCTAssertTrue(library.records.isEmpty)
    }

    func testCorruptIndexCannotBeOverwrittenByNewImport() throws {
        let session = try makeSession()
        let root = session.sourceURL.deletingLastPathComponent().appendingPathComponent("CorruptLibrary")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("index.json")
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: index)
        let library = LibraryStore(root: root)
        XCTAssertNotNil(library.error)
        XCTAssertThrowsError(try library.importPDF(from: session.sourceURL))
        XCTAssertEqual(try Data(contentsOf: index), corrupt)
    }

    func testEncryptedDocumentRemainsReadOnlyAndEncrypted() throws {
        let session = try makeSession()
        let data = try XCTUnwrap(session.document.dataRepresentation(options: [
            PDFDocumentWriteOption.userPasswordOption: "secret",
            PDFDocumentWriteOption.ownerPasswordOption: "owner"
        ]))
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

    func testSourceReplacementRemovesOriginalAndSurvivesUndoRedoSave() throws {
        let session = try makeSession()
        let original = try XCTUnwrap(session.document.page(at: 0)?.string)
        let block = try XCTUnwrap(session.sourceTextBlocks(onPage: 0).first)
        XCTAssertTrue(block.text.contains("First page"), block.text)
        try session.addText("Keep annotation", pageIndex: 0, bounds: CGRect(x: 30, y: 300, width: 180, height: 40), color: .blue)
        XCTAssertThrowsError(try session.replaceSourceText(block, with: "stale", fontSize: 20, color: .black))
        let fresh = try XCTUnwrap(session.sourceTextBlocks(onPage: 0).first)
        let otherBefore = session.document.page(at: 1)?.string
        try session.replaceSourceText(fresh, with: "Новый текст PDF", fontSize: 20, color: .blue)
        let edited = try XCTUnwrap(session.document.page(at: 0)?.string)
        XCTAssertFalse(edited.contains("First page"), edited)
        XCTAssertFalse(edited.contains("Первый"), edited)
        XCTAssertTrue(edited.contains("Новый текст PDF"), edited)
        XCTAssertEqual(session.document.page(at: 1)?.string, otherBefore)
        XCTAssertTrue(session.document.page(at: 0)?.annotations.contains { $0.contents == "Keep annotation" } == true)
        try session.undo()
        XCTAssertTrue(session.document.page(at: 0)?.string?.contains(original.trimmingCharacters(in: .whitespacesAndNewlines)) == true)
        try session.redo(); try session.save()
        let reopened = try XCTUnwrap(PDFDocument(url: session.sourceURL))
        XCTAssertTrue(reopened.page(at: 0)?.string?.contains("Новый текст PDF") == true)
        XCTAssertFalse(reopened.page(at: 0)?.string?.contains("First page") == true)
        let again = try XCTUnwrap(session.sourceTextBlocks(onPage: 0).first)
        try session.replaceSourceText(again, with: "Again", fontSize: 18, color: .black)
        XCTAssertTrue(session.document.page(at: 0)?.string?.contains("Again") == true)
        XCTAssertFalse(session.document.page(at: 0)?.string?.contains("Новый текст") == true)
    }

    func testSourceOverflowAndMultilineLeaveDocumentUnchanged() throws {
        let session = try makeSession()
        try logSource(session.serialized())
        let block = try XCTUnwrap(session.sourceTextBlocks(onPage: 0).first)
        let before = session.document.page(at: 0)?.string
        XCTAssertThrowsError(try session.replaceSourceText(block, with: String(repeating: "W", count: 150), fontSize: 50, color: .black))
        XCTAssertThrowsError(try session.replaceSourceText(block, with: "First\nSecond", fontSize: 20, color: .black))
        XCTAssertEqual(session.document.page(at: 0)?.string, before)
        XCTAssertFalse(session.canUndo)
        try session.replaceSourceText(block, with: "", fontSize: 20, color: .black)
        XCTAssertFalse(session.document.page(at: 0)?.string?.contains("First page") == true)
        try session.undo()
        XCTAssertEqual(session.document.page(at: 0)?.string, before)
    }

    func testSourceRewritePreservesImageFormAndPixelsOutsideText() throws {
        let session = try makeSession()
        let widget = PDFAnnotation(bounds: CGRect(x: 200, y: 200, width: 180, height: 32), forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text; widget.fieldName = "Unchanged"; widget.widgetStringValue = "Keep field"
        session.document.page(at: 0)?.addAnnotation(widget)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.blue.setFill(); context.fill(CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        // A separate photo page exercises stream/resource preservation through the full writer.
        try session.appendImages([image])
        let before = try renderedPixels(session.page(at: 0))
        let imageBefore = try renderedPixels(session.page(at: 2))
        let block = try XCTUnwrap(session.sourceTextBlocks(onPage: 0).first)
        try session.replaceSourceText(block, with: "Visible replacement", fontSize: 20, color: .black)
        let after = try renderedPixels(session.page(at: 0))
        XCTAssertNotEqual(before, after, "Replacement must affect rendered pixels")
        // Bitmap rows below the header are unaffected, including the field appearance.
        XCTAssertEqual(before.subdata(in: 200 * 595 * 4..<600 * 595 * 4), after.subdata(in: 200 * 595 * 4..<600 * 595 * 4))
        XCTAssertEqual(try renderedPixels(session.page(at: 2)), imageBefore)
        let reopened = try XCTUnwrap(PDFDocument(data: session.serialized()))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first(where: { $0.fieldName == "Unchanged" })?.widgetStringValue, "Keep field")
    }

    private func renderedPixels(_ page: PDFPage) throws -> Data {
        let width = 595, height = 842
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(UIColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            page.draw(with: .mediaBox, to: context)
        }
        return pixels
    }

    private func logSource(_ data: Data) throws {
        let object = try PDFObjectDocument(data: data), page = try XCTUnwrap(object.pages().first)
        print("IOS_CONTENT=" + (try object.pageContent(page)).base64EncodedString())
        let resources = try object.dictionary(try XCTUnwrap(object.inherited("Resources", page: page)))
        let fonts = try object.dictionary(try XCTUnwrap(resources["Font"]))
        for (key, value) in fonts {
            let font = try object.dictionary(value)
            print("IOS_FONT \(key) \(font["BaseFont"]?.name ?? "-") \(font["Subtype"]?.name ?? "-") encoding=\(String(describing: font["Encoding"]))")
            if let cmap = font["ToUnicode"] { print("IOS_CMAP=" + (try object.decodedStream(cmap)).base64EncodedString()) }
        }
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
