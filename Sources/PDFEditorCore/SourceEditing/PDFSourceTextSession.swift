#if canImport(UIKit) && canImport(PDFKit)
import Foundation
import CoreText
import PDFKit
import UIKit

@MainActor
extension PDFEditingSession {
    public func sourceTextBlocks(onPage index: Int) throws -> [SourceTextBlock] {
        guard canEditSourceText else { throw PDFEditorError.permissionDenied }
        if sourceEditorSnapshot?.revision != revision {
            sourceEditorSnapshot = (revision, try NativeContentEditor(data: serialized()), [:])
        }
        if let cached = sourceEditorSnapshot?.blocks[index] { return cached }
        let editor = sourceEditorSnapshot!.editor
        let raw = try editor.textBlocks(onPage: index), page = try page(at: index)
        var pending = Set(raw.map(\.id)), blocks: [SourceTextBlock] = []
        func normalized(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }
        for block in raw where pending.contains(block.id) {
            let point = CGPoint(x: block.baselineX + 1, y: block.baselineY + block.fontSize * 0.3)
            if let line = page.selectionForLine(at: point), let lineText = line.string {
                let bounds = line.bounds(for: page).insetBy(dx: -2, dy: -2)
                let members = raw.filter {
                    pending.contains($0.id) && abs($0.baselineY - block.baselineY) <= 0.5 &&
                    bounds.contains(CGPoint(x: $0.baselineX + 1, y: $0.baselineY + $0.fontSize * 0.3))
                }.sorted { $0.baselineX < $1.baselineX }
                if members.count > 1, normalized(members.map(\.text).joined()) == normalized(lineText) {
                    blocks.append(try editor.combining(members, text: lineText.trimmingCharacters(in: .newlines)))
                    for member in members { pending.remove(member.id) }
                    continue
                }
            }
            blocks.append(block); pending.remove(block.id)
        }
        sourceEditorSnapshot?.blocks[index] = blocks
        return blocks
    }

    public func sourceTextBounds(_ block: SourceTextBlock) throws -> CGRect {
        let font = Self.replacementFont(for: block)
        let width = (block.text as NSString).size(withAttributes: [.font: font]).width
        return CGRect(x: block.baselineX - 3, y: block.baselineY + Double(font.descender) - 3,
                      width: Double(width) + 6, height: Double(font.lineHeight) + 6)
    }

    public static func replacementFont(for block: SourceTextBlock) -> UIFont {
        let name = block.fontName.split(separator: "+").last.map(String.init) ?? block.fontName
        return UIFont(name: name, size: block.fontSize) ?? UIFont.systemFont(ofSize: block.fontSize)
    }

    public func replaceSourceText(_ block: SourceTextBlock, with text: String, fontSize: Double, color: UIColor) throws {
        guard let snapshot = sourceEditorSnapshot, snapshot.revision == revision else { throw PDFEditorError.staleSourceSelection }
        guard text.count <= 2_000, !text.contains(where: { $0.isNewline }),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (3...200).contains(fontSize) else { throw PDFEditorError.sourceTextUnsupported }
        let page = try page(at: block.pageIndex), crop = page.bounds(for: .cropBox)
        let font = Self.replacementFont(for: block).withSize(fontSize)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            .offsetBy(dx: block.baselineX, dy: block.baselineY)
        guard width <= crop.maxX - block.baselineX, text.isEmpty || crop.insetBy(dx: -0.5, dy: -0.5).contains(glyphBounds) else {
            throw PDFEditorError.sourceTextOverflow
        }
        // Reject overlap with another editable source object; no silent reflow.
        for other in try sourceTextBlocks(onPage: block.pageIndex) where other.id != block.id {
            if !text.isEmpty {
                if glyphBounds.intersects(try sourceTextBounds(other)) { throw PDFEditorError.sourceTextOverflow }
            }
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
        let donor = renderer.pdfData { context in
            context.beginPage()
            let cg = context.cgContext
            cg.translateBy(x: 0, y: 1_000); cg.scaleBy(x: 1, y: -1)
            cg.textMatrix = .identity; cg.textPosition = CGPoint(x: 20, y: 200)
            CTLineDraw(line, cg)
        }
        do {
            let result = try snapshot.editor.replacing(block, withTextPDF: donor, donorBaselineX: 20, donorBaselineY: 200)
            guard let replacement = PDFDocument(data: result), replacement.pageCount == document.pageCount else { throw PDFEditorError.exportFailed }
            try replaceSourceDocument(replacement)
        } catch {
            sourceEditorSnapshot = nil
            throw error
        }
    }
}
#endif
