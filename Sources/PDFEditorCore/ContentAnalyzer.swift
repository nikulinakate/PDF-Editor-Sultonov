#if canImport(UIKit) && canImport(PDFKit)
import PDFKit
import UIKit

public struct TextLineObservation: Identifiable {
    public let id = UUID()
    public let text: String
    public let bounds: CGRect
    public let pageIndex: Int
}

public enum ContentAnalyzer {
    /// Observations are for inspection, not writable content-stream object references.
    public static func textLines(in document: PDFDocument, pageIndex: Int) throws -> [TextLineObservation] {
        guard !document.isLocked, document.allowsCopying else { throw PDFEditorError.permissionDenied }
        guard let page = document.page(at: pageIndex), let text = page.string, !text.isEmpty else { return [] }
        guard let selection = page.selection(for: NSRange(location: 0, length: (text as NSString).length)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let value = line.string, !value.isEmpty else { return nil }
            return TextLineObservation(text: value, bounds: line.bounds(for: page), pageIndex: pageIndex)
        }
    }
}
#endif
