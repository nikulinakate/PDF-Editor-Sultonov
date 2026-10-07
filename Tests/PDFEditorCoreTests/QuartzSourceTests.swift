#if os(macOS)
import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import PDFEditorCore

final class QuartzSourceTests: XCTestCase {
    func testQuartzAndPDFKitSerializedSourceCanBeEdited() throws {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes as CFMutableData))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "First page — Первый", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]))
        context.textPosition = CGPoint(x: 30, y: 760)
        CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        let source = bytes as Data
        let pdf = try XCTUnwrap(PDFDocument(data: source))
        let serialized = try XCTUnwrap(pdf.dataRepresentation())
        for data in [source, serialized] {
            do {
                let editor = try NativeContentEditor(data: data)
                let blocks = try editor.textBlocks(onPage: 0)
                XCTAssertFalse(blocks.isEmpty)
            } catch {
                print("QUARTZ_FIXTURE_BASE64=" + data.base64EncodedString())
                throw error
            }
        }
    }
}
#endif
