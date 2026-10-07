import SwiftUI
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var filter = LibraryFilter.all
    @State private var selected: DocumentRecord?
    @State private var importing = false
    @State private var scanning = false
    @State private var scannedRecord: DocumentRecord?
    @State private var showingHelp = false
    @State private var renaming: DocumentRecord?
    @State private var name = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var busy = false
    enum LibraryFilter: String, CaseIterable { case all, favorites, trash }

    private var visible: [DocumentRecord] {
        library.records.filter {
            (filter == .trash ? $0.isTrashed : !$0.isTrashed) &&
            (filter != .favorites || $0.isFavorite) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if filter != .trash { quickActions }
                    Picker(L("library.filter"), selection: $filter) {
                        ForEach(LibraryFilter.allCases, id: \.self) { Text(L("library.\($0.rawValue)")).tag($0) }
                    }.pickerStyle(.segmented)
                    if visible.isEmpty {
                        ContentUnavailableView(L(query.isEmpty ? "library.empty" : "library.noResults"),
                                               systemImage: filter == .trash ? "trash" : "doc.richtext",
                                               description: Text(L("library.emptyHint")))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                            ForEach(visible) { record in
                                Button { if !record.isTrashed { selected = record } } label: {
                                    DocumentCard(record: record, url: library.url(for: record))
                                }.buttonStyle(.plain)
                                .contextMenu { recordMenu(record) }
                            }
                        }
                    }
                }.padding(20)
            }
            .background(Theme.canvas)
            .navigationTitle(L("library.title"))
            .searchable(text: $query, prompt: L("library.search"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingHelp = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel(L("help.title"))
                }
            }
            .overlay { if busy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                perform {
                    let urls = try result.get()
                    var last: DocumentRecord?
                    for url in urls { last = try library.importPDF(from: url) }
                    selected = last
                }
            }
            .fullScreenCover(item: $selected) { record in EditorLoader(record: record).environmentObject(library) }
            .sheet(isPresented: $scanning, onDismiss: {
                if let scannedRecord { selected = scannedRecord; self.scannedRecord = nil }
            }) {
                ScannerView { images in perform { scannedRecord = try library.createFromImages(images) }; scanning = false }
                    onError: { error in scanning = false; library.error = Message(error) }
                    onCancel: { scanning = false }
            }
            .sheet(isPresented: $showingHelp) { HelpView() }
            .alert(L("rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L("document.name"), text: $name)
                Button(L("cancel"), role: .cancel) { renaming = nil }
                Button(L("save")) { if let record = renaming { perform { try library.rename(record, to: name) } }; renaming = nil }
            }
            .errorAlert($library.error)
            .onChange(of: photos) { _, items in Task { await importPhotos(items) } }
            .onOpenURL { url in perform { selected = try library.importPDF(from: url) } }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("library.hero")).font(.title2.bold())
                    Text(L("library.heroHint")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.text.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 10) {
                actionButton("import", icon: "plus") { importing = true }
                actionButton("scan", icon: "viewfinder") { scanning = true }
                    .disabled(!ScannerView.isSupported)
                PhotosPicker(selection: $photos, maxSelectionCount: 30, matching: .images) {
                    VStack(spacing: 7) { Image(systemName: "photo.on.rectangle"); Text(L("photos")).font(.caption.weight(.semibold)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.plain).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Button(L("new.blank"), systemImage: "doc.badge.plus") { perform { selected = try library.createBlank() } }
                Spacer()
                Button(L("new.demo"), systemImage: "sparkles") { perform { selected = try library.add(data: DemoDocument.make(), name: L("demo.name")) } }
            }.font(.subheadline)
        }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private func actionButton(_ key: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) { Image(systemName: icon); Text(L(key)).font(.caption.weight(.semibold)) }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
        }.buttonStyle(.plain).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func recordMenu(_ record: DocumentRecord) -> some View {
        if record.isTrashed {
            Button(L("restore"), systemImage: "arrow.uturn.backward") { perform { try library.restore(record) } }
        } else {
            Button(L("rename"), systemImage: "pencil") { name = record.name; renaming = record }
            Button(L(record.isFavorite ? "favorite.remove" : "favorite.add"), systemImage: "star") { perform { try library.toggleFavorite(record) } }
            Button(L("duplicate"), systemImage: "doc.on.doc") {
                perform { _ = try library.add(data: Data(contentsOf: library.url(for: record)), name: record.name + " " + L("copy")) }
            }
            Button(L("trash"), systemImage: "trash", role: .destructive) { perform { try library.trash(record) } }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { library.error = Message(error) }
    }

    @MainActor private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        busy = true
        defer { busy = false; photos = [] }
        do {
            var images: [UIImage] = []
            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                images.append(image)
            }
            selected = try library.createFromImages(images)
        } catch { library.error = Message(error) }
    }
}

private struct DocumentCard: View {
    let record: DocumentRecord
    let url: URL
    @State private var thumbnail: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12).fill(Color(uiColor: .tertiarySystemGroupedBackground))
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().padding(12) }
                else { Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(Theme.accent) }
                if record.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(10) }
            }.frame(height: 180)
            Text(record.name).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
            HStack {
                Text(record.pageCount == 0 ? L("document.locked") : "\(record.pageCount) " + L("pages"))
                Spacer()
                Text(record.modifiedAt, style: .date)
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .task(id: record.modifiedAt) {
            // Use an independent PDFDocument so thumbnail rendering cannot race the editor's document.
            thumbnail = await Task.detached(priority: .utility) {
                PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 220, height: 300), for: .cropBox)
            }.value
        }
    }
}
