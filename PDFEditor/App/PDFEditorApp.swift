import SwiftUI

@main
struct PDFEditorApp: App {
    @StateObject private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(library).tint(Theme.accent)
        }
    }
}
