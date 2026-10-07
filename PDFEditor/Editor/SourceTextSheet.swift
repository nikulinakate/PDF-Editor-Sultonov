import SwiftUI
import PDFEditorCore

struct SourceTextSheet: View {
    @ObservedObject var session: PDFEditingSession
    let block: SourceTextBlock
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var size: Double
    @State private var color = Color.black
    @State private var error: Message?

    init(session: PDFEditingSession, block: SourceTextBlock) {
        self.session = session; self.block = block
        _text = State(initialValue: block.text); _size = State(initialValue: block.fontSize)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("source.original")) { Text(block.text).textSelection(.enabled) }
                Section(L("source.replacement")) {
                    TextField(L("source.replacement"), text: $text).textInputAutocapitalization(.sentences)
                    HStack { Text(L("text.size")); Spacer(); Text("\(Int(size))"); Stepper("", value: $size, in: 3...200).labelsHidden() }
                    ColorPicker(L("color"), selection: $color, supportsOpacity: false)
                }
                Section {
                    Text(L("source.font") + ": " + PDFEditingSession.replacementFont(for: block).fontName)
                    Text(L("source.hint")).foregroundStyle(.secondary)
                    Text(L("source.deleteHint")).foregroundStyle(.secondary)
                }.font(.caption)
            }
            .navigationTitle(L("source.title")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) {
                        do { try session.replaceSourceText(block, with: text, fontSize: size, color: UIColor(color)); dismiss() }
                        catch { self.error = Message(error) }
                    }
                }
            }
            .errorAlert($error)
        }
    }
}
