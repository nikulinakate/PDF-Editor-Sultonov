#if canImport(UIKit) && canImport(PDFKit)
import PDFKit
import UIKit

extension PDFEditingSession {
    public func rotatePage(at index: Int) throws {
        let page = try page(at: index)
        try mutate(allowed: canOrganize) { page.rotation = (page.rotation + 90) % 360 }
    }

    public func removePage(at index: Int) throws {
        _ = try page(at: index)
        guard document.pageCount > 1 else { throw PDFEditorError.lastPage }
        try mutate(allowed: canOrganize) { document.removePage(at: index) }
    }

    public func duplicatePage(at index: Int) throws {
        let source = try page(at: index)
        guard let copy = source.copy() as? PDFPage else { throw PDFEditorError.exportFailed }
        try mutate(allowed: canOrganize) { document.insert(copy, at: index + 1) }
    }

    public func movePage(from: Int, to: Int) throws {
        _ = try DocumentPolicy.movedOrder(count: document.pageCount, from: from, to: to)
        guard from != to else { return }
        let moved = try page(at: from)
        try mutate(allowed: canOrganize) {
            document.removePage(at: from)
            document.insert(moved, at: to)
        }
    }

    public func insertBlankPage(at index: Int) throws {
        guard (0...document.pageCount).contains(index) else { throw PDFEditorError.invalidPage }
        let blank = PDFPage()
        blank.setBounds(CGRect(x: 0, y: 0, width: 595.28, height: 841.89), for: .mediaBox)
        try mutate(allowed: canOrganize) { document.insert(blank, at: index) }
    }

    public func appendImages(_ images: [UIImage]) throws {
        let pages = images.compactMap { PDFPage(image: $0) }
        guard !pages.isEmpty, pages.count == images.count else { throw PDFEditorError.invalidDocument }
        try mutate(allowed: canOrganize) {
            for page in pages { document.insert(page, at: document.pageCount) }
        }
    }

    public func appendDocument(url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let other = PDFDocument(url: url), other.pageCount > 0 else { throw PDFEditorError.invalidDocument }
        guard !other.isLocked else { throw PDFEditorError.lockedDocument }
        guard !other.isEncrypted, other.allowsCopying else { throw PDFEditorError.permissionDenied }
        let pages = (0..<other.pageCount).compactMap { other.page(at: $0)?.copy() as? PDFPage }
        guard pages.count == other.pageCount else { throw PDFEditorError.exportFailed }
        try mutate(allowed: canOrganize) {
            for page in pages { document.insert(page, at: document.pageCount) }
        }
    }

    public func extractPages(_ indices: [Int]) throws -> Data {
        guard !indices.isEmpty else { throw PDFEditorError.emptySelection }
        guard !document.isLocked, !document.isEncrypted, document.allowsCopying else { throw PDFEditorError.permissionDenied }
        let output = PDFDocument()
        for index in indices {
            guard let copy = try page(at: index).copy() as? PDFPage else { throw PDFEditorError.exportFailed }
            output.insert(copy, at: output.pageCount)
        }
        guard let data = output.dataRepresentation(), PDFDocument(data: data)?.pageCount == indices.count else {
            throw PDFEditorError.exportFailed
        }
        return data
    }
}
#endif
