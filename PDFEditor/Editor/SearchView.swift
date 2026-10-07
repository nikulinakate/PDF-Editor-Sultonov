import SwiftUI
import PDFKit
import PDFEditorCore

struct SearchView: View {
    @ObservedObject var session: PDFEditingSession
    let onSelect: (PDFSelection) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PDFSelection] = []
    @State private var searching = false
    var body: some View {
        NavigationStack {
            List {
                if searching { ProgressView() }
                ForEach(Array(results.enumerated()), id: \.offset) { _, selection in
                    Button {
                        onSelect(selection)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selection.string ?? "").foregroundStyle(.primary).lineLimit(3)
                            if let page = selection.pages.first {
                                Text(L("page") + " \(session.document.index(for: page) + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !query.isEmpty && results.isEmpty && !searching { Text(L("search.noResults")).foregroundStyle(.secondary) }
            }.navigationTitle(L("search"))
                .searchable(text: $query, prompt: L("search.placeholder"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("done")) { dismiss() } } }
                .task(id: query) {
                    guard !query.isEmpty else { results = []; searching = false; return }
                    searching = true
                    do {
                        try await Task.sleep(for: .milliseconds(350))
                        try Task.checkCancellation()
                        results = session.document.findString(query, withOptions: .caseInsensitive)
                        searching = false
                    } catch is CancellationError {} catch { searching = false }
                }
        }
    }
}

struct TextInspectorView: View {
    @ObservedObject var session: PDFEditingSession
    let pageIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [TextLineObservation] = []
    @State private var error: Message?
    @State private var summary: PDFStreamSummary?
    @State private var recognizing = false
    @State private var recognizedText: String?
    var body: some View {
        NavigationStack {
            List {
                Section { Text(L("inspect.hint")).font(.subheadline).foregroundStyle(.secondary) }
                Section {
                    Button {
                        Task { await recognize() }
                    } label: {
                        if recognizing { ProgressView() }
                        else { Label(L("ocr.recognize"), systemImage: "text.viewfinder") }
                    }.disabled(recognizing)
                    if let summary {
                        Text(L("inspect.commands") + " \(summary.textDrawingCommands)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if lines.isEmpty { Text(L("inspect.noText")) }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(line.text).textSelection(.enabled)
                        Text("X: \(Int(line.bounds.minX))  Y: \(Int(line.bounds.minY))  W: \(Int(line.bounds.width))  H: \(Int(line.bounds.height))")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle(L("inspect.text"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("done")) { dismiss() } } }
                .task {
                    do {
                        lines = try ContentAnalyzer.textLines(in: session.document, pageIndex: pageIndex)
                        if let page = session.document.page(at: pageIndex) { summary = try PDFStreamInspector.inspect(page: page) }
                    } catch { self.error = Message(error) }
                }
                .sheet(isPresented: Binding(get: { recognizedText != nil }, set: { if !$0 { recognizedText = nil } })) {
                    RecognizedTextView(text: recognizedText ?? "")
                }
                .errorAlert($error)
        }
    }

    @MainActor private func recognize() async {
        guard let page = session.document.page(at: pageIndex) else { return }
        recognizing = true; defer { recognizing = false }
        do {
            let text = try await OCRService.recognize(page: page)
            if text.isEmpty { error = Message(text: L("ocr.empty")) }
            else { recognizedText = text }
        } catch { self.error = Message(error) }
    }
}

private struct RecognizedTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var share: SharePayload?
    @State private var error: Message?
    var body: some View {
        NavigationStack {
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                .navigationTitle(L("ocr.result"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("done")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("share"), systemImage: "square.and.arrow.up") {
                            do {
                                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                let url = folder.appendingPathComponent("Recognized-text.txt")
                                try text.write(to: url, atomically: true, encoding: .utf8)
                                share = SharePayload(url: url)
                            } catch { self.error = Message(error) }
                        }
                    }
                }.sheet(item: $share) { ActivitySheet(items: [$0.url]) }.errorAlert($error)
        }
    }
}
