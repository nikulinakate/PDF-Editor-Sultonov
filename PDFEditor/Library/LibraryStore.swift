import Foundation
import PDFKit
import PDFEditorCore
import UIKit

struct DocumentRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var modifiedAt: Date
    var pageCount: Int
    var isFavorite = false
    var isTrashed = false
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var records: [DocumentRecord] = []
    @Published var error: Message?
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFEditor", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                records = try JSONDecoder().decode([DocumentRecord].self, from: Data(contentsOf: indexURL))
            }
        } catch { self.error = Message(error) }
    }

    func url(for record: DocumentRecord) -> URL {
        directory(for: record.id).appendingPathComponent("working.pdf")
    }

    func originalURL(for record: DocumentRecord) -> URL {
        directory(for: record.id).appendingPathComponent("original.pdf")
    }

    func importPDF(from source: URL) throws -> DocumentRecord {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        return try add(data: data, name: source.deletingPathExtension().lastPathComponent)
    }

    @discardableResult
    func add(data: Data, name: String) throws -> DocumentRecord {
        guard let document = PDFDocument(data: data), document.isLocked || document.pageCount > 0 else {
            throw PDFEditorError.invalidDocument
        }
        let filename = try DocumentPolicy.filename(name)
        let record = DocumentRecord(id: UUID(), name: String(filename.dropLast(4)), modifiedAt: Date(), pageCount: document.pageCount)
        let folder = directory(for: record.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try data.write(to: url(for: record), options: [.atomic, .completeFileProtectionUnlessOpen])
            try data.write(to: originalURL(for: record), options: [.atomic, .completeFileProtectionUnlessOpen])
            try persist(records + [record])
            return record
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func createBlank() throws -> DocumentRecord {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 595.28, height: 841.89), for: .mediaBox)
        document.insert(page, at: 0)
        guard let data = document.dataRepresentation() else { throw PDFEditorError.exportFailed }
        return try add(data: data, name: L("document.untitled"))
    }

    func createFromImages(_ images: [UIImage]) throws -> DocumentRecord {
        let document = PDFDocument()
        for image in images {
            guard let page = PDFPage(image: image) else { throw PDFEditorError.invalidDocument }
            document.insert(page, at: document.pageCount)
        }
        guard document.pageCount > 0, let data = document.dataRepresentation() else { throw PDFEditorError.invalidDocument }
        return try add(data: data, name: L("document.scan"))
    }

    func rename(_ record: DocumentRecord, to name: String) throws {
        let filename = try DocumentPolicy.filename(name)
        try update(record) { $0.name = String(filename.dropLast(4)) }
    }

    func toggleFavorite(_ record: DocumentRecord) throws { try update(record) { $0.isFavorite.toggle() } }
    func trash(_ record: DocumentRecord) throws { try update(record) { $0.isTrashed = true } }
    func restore(_ record: DocumentRecord) throws { try update(record) { $0.isTrashed = false } }

    func didSave(_ record: DocumentRecord, pageCount: Int) throws {
        try update(record) { $0.pageCount = pageCount; $0.modifiedAt = Date() }
    }

    private func update(_ record: DocumentRecord, change: (inout DocumentRecord) -> Void) throws {
        var next = records
        guard let index = next.firstIndex(where: { $0.id == record.id }) else { return }
        change(&next[index])
        try persist(next)
    }

    private func persist(_ next: [DocumentRecord]) throws {
        try JSONEncoder().encode(next).write(to: indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        records = next
    }

    private func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
}
