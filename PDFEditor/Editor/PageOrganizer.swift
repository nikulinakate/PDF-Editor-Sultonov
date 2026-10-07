import SwiftUI
import PDFKit
import PDFEditorCore
import PhotosUI
import UniformTypeIdentifiers

struct PageOrganizer: View {
    @ObservedObject var session: PDFEditingSession
    let currentPage: Int
    let onSelect: (Int) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var extracting = false
    @State private var range = ""
    @State private var deleteIndex: Int?
    @State private var error: Message?
    @State private var extracted = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<session.document.pageCount, id: \.self) { index in
                    HStack(spacing: 16) {
                        PageThumbnail(page: session.document.page(at: index), revision: session.revision)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("page") + " \(index + 1)").font(.headline)
                            if index == currentPage { Text(L("page.current")).font(.caption).foregroundStyle(Theme.accent) }
                        }
                        Spacer()
                        Menu {
                            Button(L("rotate"), systemImage: "rotate.right") { perform { try session.rotatePage(at: index) } }
                            Button(L("duplicate"), systemImage: "doc.on.doc") { perform { try session.duplicatePage(at: index) } }
                            Button(L("delete"), systemImage: "trash", role: .destructive) { deleteIndex = index }
                                .disabled(session.document.pageCount <= 1)
                        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                            .disabled(!session.canOrganize).accessibilityLabel(L("page.actions"))
                    }.contentShape(Rectangle()).onTapGesture { onSelect(index) }
                }.onMove { indices, destination in
                    guard let from = indices.first else { return }
                    perform { try session.movePage(from: from, to: destination > from ? destination - 1 : destination) }
                }.moveDisabled(!session.canOrganize)
            }
            .navigationTitle(L("organize"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("done")) { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton().disabled(!session.canOrganize)
                    Menu {
                        Button(L("page.blank"), systemImage: "doc.badge.plus") { perform { try session.insertBlankPage(at: session.document.pageCount) } }
                        Button(L("page.merge"), systemImage: "doc.on.doc") { importing = true }
                    } label: { Image(systemName: "plus") }.disabled(!session.canOrganize).accessibilityLabel(L("page.add"))
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    PhotosPicker(selection: $photos, maxSelectionCount: 30, matching: .images) { Label(L("page.images"), systemImage: "photo") }
                        .disabled(!session.canOrganize || busy)
                    Spacer()
                    Button(L("page.extract"), systemImage: "square.and.arrow.up") { range = "\(currentPage + 1)"; extracting = true }
                        .disabled(session.document.isEncrypted || !session.document.allowsCopying)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                perform { try session.appendDocument(url: result.get()) }
            }
            .alert(L("page.extract"), isPresented: $extracting) {
                TextField(L("page.range"), text: $range).keyboardType(.numbersAndPunctuation)
                Button(L("cancel"), role: .cancel) {}
                Button(L("save")) {
                    perform {
                        let indices = try DocumentPolicy.pageIndices(range, pageCount: session.document.pageCount)
                        let data = try session.extractPages(indices)
                        _ = try library.add(data: data, name: L("document.extracted"))
                        extracted = true
                    }
                }
            } message: { Text(L("page.rangeHint")) }
            .alert(L("page.extracted"), isPresented: $extracted) { Button(L("ok"), role: .cancel) {} }
            .confirmationDialog(L("page.deleteConfirm"), isPresented: Binding(get: { deleteIndex != nil }, set: { if !$0 { deleteIndex = nil } }), titleVisibility: .visible) {
                Button(L("delete"), role: .destructive) { if let index = deleteIndex { perform { try session.removePage(at: index) } }; deleteIndex = nil }
                Button(L("cancel"), role: .cancel) { deleteIndex = nil }
            }
            .errorAlert($error)
            .overlay { if busy { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .onChange(of: photos) { _, items in Task { await appendImages(items) } }
        }
    }

    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = Message(error) } }

    @MainActor private func appendImages(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        busy = true; defer { busy = false; photos = [] }
        do {
            var images: [UIImage] = []
            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                images.append(image)
            }
            try session.appendImages(images)
        } catch { self.error = Message(error) }
    }
}

private struct PageThumbnail: View {
    let page: PDFPage?
    let revision: Int
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { RoundedRectangle(cornerRadius: 4).fill(.quaternary).overlay { Image(systemName: "doc") } }
        }.frame(width: 64, height: 90).task(id: revision) { image = page?.thumbnail(of: CGSize(width: 128, height: 180), for: .cropBox) }
    }
}
