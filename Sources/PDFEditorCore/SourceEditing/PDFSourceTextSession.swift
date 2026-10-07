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
            sourceEditorSnapshot = (revision, try NativeContentEditor(data: serialized()))
        }
        return try sourceEditorSnapshot!.editor.textBlocks(onPage: index)
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
            cg.textMatrix = .identity; cg.textPosition = .zero
            CTLineDraw(line, cg)
        }
        do {
            let result = try snapshot.editor.replacing(block, withTextPDF: donor)
            guard let replacement = PDFDocument(data: result), replacement.pageCount == document.pageCount else { throw PDFEditorError.exportFailed }
            try replaceSourceDocument(replacement)
        } catch {
            sourceEditorSnapshot = nil
            throw error
        }
    }
}
#endif
