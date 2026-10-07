import SwiftUI

enum Theme {
    static let accent = Color(red: 0.23, green: 0.29, blue: 0.86)
    static let canvas = Color(uiColor: .systemGroupedBackground)
}

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

struct Message: Identifiable {
    let id = UUID()
    let text: String
    init(_ error: Error) { text = error.localizedDescription }
    init(text: String) { self.text = text }
}

extension View {
    func errorAlert(_ message: Binding<Message?>) -> some View {
        alert(L("error.title"), isPresented: Binding(get: { message.wrappedValue != nil }, set: {
            if !$0 { message.wrappedValue = nil }
        })) {
            Button(L("ok"), role: .cancel) { message.wrappedValue = nil }
        } message: { Text(message.wrappedValue?.text ?? "") }
    }
}
