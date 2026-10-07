import SwiftUI
import PDFKit

struct TextAnnotationSheet: View {
    let placement: TextPlacement
    var onSave: (String, CGFloat, Color, CGRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var fontSize: Double
    @State private var color: Color
    @State private var x: Double
    @State private var y: Double
    @State private var width: Double
    @State private var height: Double

    init(placement: TextPlacement, color: Color, onSave: @escaping (String, CGFloat, Color, CGRect) -> Void) {
        self.placement = placement; self.onSave = onSave
        _text = State(initialValue: placement.annotation?.contents ?? "")
        _fontSize = State(initialValue: Double(placement.annotation?.font?.pointSize ?? 18))
        _color = State(initialValue: (placement.annotation?.fontColor).map { Color(uiColor: $0) } ?? color)
        _x = State(initialValue: placement.bounds.minX); _y = State(initialValue: placement.bounds.minY)
        _width = State(initialValue: placement.bounds.width); _height = State(initialValue: placement.bounds.height)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("text.content")) { TextEditor(text: $text).frame(minHeight: 140).font(.system(size: fontSize)) }
                Section(L("text.appearance")) {
                    Stepper("\(L("text.size")): \(Int(fontSize))", value: $fontSize, in: 8...72)
                    ColorPicker(L("color"), selection: $color, supportsOpacity: false)
                }
                Section(L("text.position")) {
                    numberField("X", value: $x); numberField("Y", value: $y)
                    numberField(L("width"), value: $width); numberField(L("height"), value: $height)
                }
                Section { Text(L("text.overlayHint")).font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(L(placement.annotation == nil ? "text.add" : "text.edit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("save")) {
                        onSave(text, fontSize, color, CGRect(x: x, y: y, width: width, height: height)); dismiss()
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || width <= 0 || height <= 0 || ![x, y, width, height].allSatisfy(\.isFinite))
                }
            }
        }
    }
    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width: 120) }
    }
}

struct FormFieldSheet: View {
    let annotation: PDFAnnotation
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    var body: some View {
        NavigationStack {
            Form {
                Section(annotation.fieldName ?? L("form.field")) {
                    if annotation.isPasswordField { SecureField(L("form.value"), text: $value) }
                    else { TextEditor(text: $value).frame(minHeight: 120) }
                }
            }.navigationTitle(L("form.fill"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L("save")) { onSave(value); dismiss() } }
                }.onAppear { value = annotation.widgetStringValue ?? "" }
        }
    }
}
