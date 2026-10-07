#if canImport(UIKit) && canImport(PDFKit)
import Combine
import PDFKit
import UIKit

@MainActor
public final class PDFEditingSession: ObservableObject {
    @Published public private(set) var document: PDFDocument
    @Published public private(set) var revision = 0
    @Published public private(set) var isDirty = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    public let sourceURL: URL
    var sourceEditorSnapshot: (revision: Int, editor: NativeContentEditor)?
    public var canEditSourceText: Bool { !document.isLocked && !document.isEncrypted && document.allowsContentEditing }
    private var history = SnapshotHistory()

    public var canAnnotate: Bool { !document.isLocked && !document.isEncrypted && document.allowsCommenting }
    public var canOrganize: Bool { !document.isLocked && !document.isEncrypted && document.allowsDocumentAssembly }
    public var canFillForms: Bool { !document.isLocked && !document.isEncrypted && document.allowsFormFieldEntry }

    public init(url: URL) throws {
        guard let pdf = PDFDocument(url: url), pdf.isLocked || pdf.pageCount > 0 else {
            throw PDFEditorError.invalidDocument
        }
        sourceURL = url
        document = pdf
    }

    public func unlock(password: String) -> Bool {
        let success = document.unlock(withPassword: password)
        if success { revision += 1 }
        return success
    }

    public func page(at index: Int) throws -> PDFPage {
        guard !document.isLocked else { throw PDFEditorError.lockedDocument }
        guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
            throw PDFEditorError.invalidPage
        }
        return page
    }

    public func undo() throws {
        let current = try serialized()
        guard let data = history.undo(current: current), let restored = PDFDocument(data: data) else { return }
        document = restored
        changed()
    }

    public func redo() throws {
        let current = try serialized()
        guard let data = history.redo(current: current), let restored = PDFDocument(data: data) else { return }
        document = restored
        changed()
    }

    public func serialized() throws -> Data {
        guard !document.isLocked else { throw PDFEditorError.lockedDocument }
        if document.isEncrypted { return try Data(contentsOf: sourceURL) }
        guard let data = document.dataRepresentation(), let reopened = PDFDocument(data: data),
              reopened.pageCount == document.pageCount, reopened.pageCount > 0 else {
            throw PDFEditorError.exportFailed
        }
        return data
    }

    public func save() throws {
        guard isDirty else { return }
        let data = try serialized()
        // The app only edits private imported copies. Atomic replacement preserves the previous file on failure.
        try data.write(to: sourceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        isDirty = false
    }

    public func export(to url: URL) throws {
        try serialized().write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func mutate(allowed: Bool, _ operation: () throws -> Void) throws {
        guard !document.isLocked else { throw PDFEditorError.lockedDocument }
        guard allowed else { throw PDFEditorError.permissionDenied }
        let before = try serialized()
        do {
            try operation()
            _ = try serialized()
            history.record(before)
            changed()
        } catch {
            if let restored = PDFDocument(data: before) { document = restored; revision += 1 }
            throw error
        }
    }

    func replaceSourceDocument(_ replacement: PDFDocument) throws {
        try mutate(allowed: canEditSourceText) { document = replacement }
    }

    private func changed() {
        isDirty = true
        canUndo = history.canUndo
        canRedo = history.canRedo
        revision += 1
    }
}
#endif
