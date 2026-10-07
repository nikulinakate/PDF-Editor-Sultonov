import SwiftUI
import PDFEditorCore

struct EditorLoader: View {
    let record: DocumentRecord
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var session: PDFEditingSession?
    @State private var error: Message?

    var body: some View {
        Group {
            if let session { EditorView(record: record, session: session).environmentObject(library) }
            else {
                VStack(spacing: 18) {
                    if let error {
                        ContentUnavailableView(L("error.title"), systemImage: "exclamationmark.triangle", description: Text(error.text))
                        Button(L("close")) { dismiss() }
                    } else { ProgressView() }
                }
            }
        }.task {
            guard session == nil else { return }
            do { session = try PDFEditingSession(url: library.url(for: record)) }
            catch { self.error = Message(error) }
        }
    }
}
