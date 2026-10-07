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
        for block in raw.sorted(by: { $0.baselineX < $1.baselineX }) where pending.contains(block.id) {
            var members = [block]
            var union = try sourceTextBounds(block)
            for other in raw.sorted(by: { $0.baselineX < $1.baselineX }) where pending.contains(other.id) && other.id != block.id {
                guard abs(other.baselineY - block.baselineY) <= 0.5,
                      abs(other.fontSize - block.fontSize) <= 0.5,
                      other.baselineX >= block.baselineX,
                      other.baselineX <= union.maxX + max(6, block.fontSize * 0.5) else { continue }
                let nextBounds = try sourceTextBounds(other)
                // Do not join superimposed objects or separate table columns.
                guard nextBounds.minX >= union.maxX - max(6, block.fontSize * 0.5) else { continue }
                members.append(other); union = union.union(nextBounds)
            }
            if members.count > 1, let displayed = page.selection(for: union)?.string,
               normalized(members.map(\.text).joined()) == normalized(displayed) {
                let text = displayed.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
                blocks.append(try editor.combining(members, text: text))
                for member in members { pending.remove(member.id) }
            } else { blocks.append(block); pending.remove(block.id) }
        }
        sourceEditorSnapshot?.blocks[index] = blocks
        return blocks
    }

    public func sourceTextBounds(_ block: SourceTextBlock) throws -> CGRect {
        let page = try page(at: block.pageIndex)
        let sought = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = page.string, !sought.isEmpty {
            let string = text as NSString
            var remaining = NSRange(location: 0, length: string.length)
            var attempts = 0
            while remaining.length > 0 && attempts < 2_000 {
                let range = string.range(of: sought, options: [], range: remaining)
                if range.location == NSNotFound { break }
                if let bounds = page.selection(for: range)?.bounds(for: page),
                   abs(bounds.minX - block.baselineX) <= max(4, block.fontSize * 0.25),
                   bounds.insetBy(dx: -3, dy: -3).contains(CGPoint(x: block.baselineX + 1, y: block.baselineY + block.fontSize * 0.3)) {
                    return bounds.insetBy(dx: -2, dy: -2)
                }
                let next = NSMaxRange(range)
                remaining = NSRange(location: next, length: string.length - next); attempts += 1
            }
        }
        let font = Self.replacementFont(for: block)
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(Self.sourceAttributedText(block.text, font: font, color: .black, block: block)), nil, nil, nil)
        return CGRect(x: block.baselineX - 3, y: block.baselineY + Double(font.descender) - 3,
                      width: Double(width) + 6, height: Double(font.lineHeight) + 6)
    }

    public static func replacementFont(for block: SourceTextBlock) -> UIFont {
        let name = block.fontName.split(separator: "+").last.map(String.init) ?? block.fontName
        return UIFont(name: name, size: block.fontSize) ?? UIFont.systemFont(ofSize: block.fontSize)
    }

    private static func sourceAttributedText(_ text: String, font: UIFont, color: UIColor, block: SourceTextBlock) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let scale = Double(font.pointSize) / block.fontSize
        let tracking = block.letterSpacing * scale
        if abs(tracking) > 0.0001 { attributes[.kern] = tracking }
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        if abs(block.wordSpacing) > 0.0001 {
            let utf16 = Array(text.utf16)
            for (index, character) in utf16.enumerated() where character == 32 {
                result.addAttribute(.kern, value: tracking + block.wordSpacing * scale, range: NSRange(location: index, length: 1))
            }
        }
        return result
    }

    public func replaceSourceText(_ block: SourceTextBlock, with text: String, fontSize: Double, color: UIColor) throws {
        guard let snapshot = sourceEditorSnapshot, snapshot.revision == revision else { throw PDFEditorError.staleSourceSelection }
        guard text.count <= 2_000, !text.contains(where: { $0.isNewline }),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (3...200).contains(fontSize) else { throw PDFEditorError.sourceTextUnsupported }
        let page = try page(at: block.pageIndex), crop = page.bounds(for: .cropBox)
        let font = Self.replacementFont(for: block).withSize(fontSize)
        let attributed = Self.sourceAttributedText(text, font: font, color: color, block: block)
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            .offsetBy(dx: block.baselineX, dy: block.baselineY)
        guard width <= crop.maxX - block.baselineX, text.isEmpty || crop.insetBy(dx: -0.5, dy: -0.5).contains(glyphBounds) else {
            throw PDFEditorError.sourceTextOverflow
        }
        // Reject overlap with another editable source object; no silent reflow.
        for other in try sourceTextBlocks(onPage: block.pageIndex) where !other.operands.allSatisfy({ block.operands.contains($0) }) {
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
