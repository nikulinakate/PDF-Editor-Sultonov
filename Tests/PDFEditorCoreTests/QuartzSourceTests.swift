#if os(macOS)
import XCTest
import CoreGraphics
import CoreText
import PDFKit
import AppKit
@testable import PDFEditorCore

final class QuartzSourceTests: XCTestCase {
    func testQuartzAndPDFKitSerializedSourceCanBeEdited() throws {
        let source = try quartz("First page — Первый", at: CGPoint(x: 30, y: 760))
        let pdf = try XCTUnwrap(PDFDocument(data: source))
        let serialized = try XCTUnwrap(pdf.dataRepresentation())
        for data in [source, serialized] {
            let editor = try NativeContentEditor(data: data)
            let blocks = try editor.textBlocks(onPage: 0)
            XCTAssertFalse(blocks.isEmpty)
            let block = try editor.combining(blocks, text: "First page — Первый")
            let donor = try quartz("Новый текст PDF", at: CGPoint(x: 20, y: 200))
            let result = try editor.replacing(block, withTextPDF: donor, donorBaselineX: 20, donorBaselineY: 200)
            let reopened = try XCTUnwrap(PDFDocument(data: result))
            let text = try XCTUnwrap(reopened.string)
            XCTAssertTrue(text.contains("Новый текст PDF"), text)
            XCTAssertFalse(text.contains("First page"), text)
            XCTAssertFalse(text.contains("Первый"), text)
            let next = try NativeContentEditor(data: result)
            let nextBlocks = try next.textBlocks(onPage: 0)
            XCTAssertFalse(nextBlocks.isEmpty, "Replacement must remain editable")
            XCTAssertEqual(nextBlocks.first?.baselineX ?? 0, 30, accuracy: 0.01)
            XCTAssertEqual(nextBlocks.first?.baselineY ?? 0, 760, accuracy: 0.01)
        }
    }

    func testSystemFontTextDrawingCanBeSelected() throws {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: 842); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        ("First page — Первый" as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        let data = bytes as Data, editor = try NativeContentEditor(data: data)
        let blocks = try editor.textBlocks(onPage: 0)
        XCTAssertFalse(blocks.isEmpty)
    }

    private func quartz(_ text: String, at point: CGPoint) throws -> Data {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]))
        context.textPosition = point; CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        return bytes as Data
    }
}
#endif
