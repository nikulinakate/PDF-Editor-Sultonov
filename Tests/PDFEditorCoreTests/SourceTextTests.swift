import XCTest
@testable import PDFEditorCore

final class SourceTextTests: XCTestCase {
    func testLexerEscapesHexNamesAndReferences() throws {
        var lexer = PDFLexer(Data("(a\\050b\\051\\n\\101) <4142F> /F#31 12 0 R".utf8))
        XCTAssertEqual(try lexer.value().string, Data("a(b)\nA".utf8))
        XCTAssertEqual(try lexer.value().string, Data([65, 66, 240]))
        XCTAssertEqual(try lexer.value().name, "F1")
        XCTAssertEqual(try lexer.value().reference, PDFReference(object: 12, generation: 0))
    }

    func testRewriteRemovesOldOperatorsAndKeepsSharedPageAndResources() throws {
        let data = fixture("BT /F1 20 Tf 1 0 0 1 30 700 Tm (Old text) Tj ET", shared: true)
        let editor = try NativeContentEditor(data: data)
        let block = try XCTUnwrap(editor.textBlocks(onPage: 0).first)
        XCTAssertEqual(block.text, "Old text")
        XCTAssertEqual(block.baselineY, 700)
        let donor = fixture("BT /F1 20 Tf 1 0 0 1 0 0 Tm (New text) Tj ET")
        let result = try editor.replacing(block, withTextPDF: donor)
        let reopened = try NativeContentEditor(data: result)
        XCTAssertEqual(try reopened.textBlocks(onPage: 0).map(\.text), ["New text"])
        XCTAssertEqual(try reopened.textBlocks(onPage: 1).map(\.text), ["Old text"])
        let doc = try PDFObjectDocument(data: result), pages = try doc.pages()
        let content = try doc.pageContent(pages[0])
        XCTAssertFalse(String(decoding: content, as: UTF8.self).contains("Old text"))
        XCTAssertTrue(String(decoding: content, as: UTF8.self).contains("0 0 10 10 re f"))
        XCTAssertThrowsError(try editor.replacing(block, withTextPDF: donor))
    }

    func testReplacementCanBeEditedAgainAndEmptyTextDeletes() throws {
        let editor = try NativeContentEditor(data: fixture("BT /F1 20 Tf 30 700 Td (First) Tj ET"))
        let block = try XCTUnwrap(editor.textBlocks(onPage: 0).first)
        let next = try editor.replacing(block, withTextPDF: fixture("BT /F1 20 Tf 0 0 Td (Second) Tj ET"))
        let second = try NativeContentEditor(data: next)
        let replacement = try XCTUnwrap(second.textBlocks(onPage: 0).first)
        XCTAssertEqual(replacement.text, "Second")
        XCTAssertEqual(replacement.baselineX, 30)
        let empty = try second.replacing(replacement, withTextPDF: fixture(""))
        XCTAssertTrue(try NativeContentEditor(data: empty).textBlocks(onPage: 0).isEmpty)
        XCTAssertFalse(String(decoding: empty, as: UTF8.self).contains("First"))
        XCTAssertFalse(String(decoding: empty, as: UTF8.self).contains("Second"))
    }

    func testForeignSnapshotSelectionIsRejected() throws {
        let data = fixture("BT /F1 20 Tf 30 700 Td (Same) Tj ET")
        let a = try NativeContentEditor(data: data), b = try NativeContentEditor(data: data)
        let foreign = try XCTUnwrap(a.textBlocks(onPage: 0).first)
        _ = try b.textBlocks(onPage: 0)
        XCTAssertThrowsError(try b.replacing(foreign, withTextPDF: data)) {
            XCTAssertEqual($0 as? PDFEditorError, .staleSourceSelection)
        }
    }

    func testUnsafeTextObjectsAreNotOfferedForEditing() throws {
        for commands in [
            "BT /F1 20 Tf 30 700 Td (One) Tj 0 -24 Td (Two) Tj ET",
            "BT /F1 20 Tf 0 1 -1 0 30 700 Tm (Rotated) Tj ET",
            "BT /F1 20 Tf 7 Tr 30 700 Td (Clip) Tj ET",
            "/Span << /ActualText (Hidden) >> BDC BT /F1 20 Tf 30 700 Td (Tagged) Tj ET EMC",
            "0 0 200 200 re W n BT /F1 20 Tf 30 700 Td (Clipped) Tj ET"
        ] {
            XCTAssertTrue(try NativeContentEditor(data: fixture(commands)).textBlocks(onPage: 0).isEmpty, commands)
        }
    }

    func testMalformedOrIncrementalXrefIsRejected() {
        let valid = fixture("")
        XCTAssertThrowsError(try NativeContentEditor(data: Data(valid.dropLast(40))))
        let incremental = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "/Root 1 0 R", with: "/Prev 1 /Root 1 0 R").utf8)
        XCTAssertThrowsError(try NativeContentEditor(data: incremental))
    }

    func testToUnicodeDecodesCyrillicAndRanges() throws {
        let base = try PDFObjectDocument(data: fixture(""))
        let cmap = Data("1 beginbfchar <01> <041F> endbfchar 1 beginbfrange <02> <03> [<0440> <0438>] endbfrange".utf8)
        let ref = try base.add(.stream([:], cmap))
        let decoder = try PDFFontDecoder(document: base, value: .dictionary(["BaseFont": .name("Subset"), "ToUnicode": .reference(ref)]))
        XCTAssertEqual(try decoder.decode(Data([1, 2, 3])), "При")
        XCTAssertThrowsError(try decoder.decode(Data([4])))
    }

    func testWriterPreservesFractionPrecisionWithoutExponentNotation() throws {
        for value in [0.00000000012345, -0.000000002, 1.234567890123456, 1e20] {
            let encoded = pdfNumber(value)
            XCTAssertFalse(encoded.lowercased().contains("e"))
            XCTAssertEqual(Double(encoded), value)
        }
    }

    func testOversizedXrefCountFailsWithoutIntegerOverflow() {
        let data = Data("%PDF-1.7\nxref\n9223372036854775807 2\ntrailer\n<< /Root 1 0 R >>\nstartxref\n9\n%%EOF\n".utf8)
        XCTAssertThrowsError(try NativeContentEditor(data: data))
    }

    private func fixture(_ text: String, shared: Bool = false) -> Data {
        let stream = "0 0 10 10 re f\n" + text
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R\(shared ? " 6 0 R" : "")] /Count \(shared ? 2 : 1) /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
        ]
        if shared { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>") }
        var pdf = "%PDF-1.7\n", offsets: [Int] = []
        for (index, object) in objects.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
