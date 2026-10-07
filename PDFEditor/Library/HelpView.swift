import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section(L("help.start")) {
                    Label(L("help.import"), systemImage: "square.and.arrow.down")
                    Label(L("help.annotate"), systemImage: "pencil.tip")
                    Label(L("help.pages"), systemImage: "square.grid.2x2")
                    Label(L("help.share"), systemImage: "square.and.arrow.up")
                }
                Section(L("help.saving")) { Text(L("help.savingHint")) }
                Section(L("help.available")) { Text(L("help.availableHint")) }
                Section(L("help.limits")) { Text(L("help.limitsHint")) }
                Section(L("help.privacy")) { Text(L("help.privacyHint")) }
            }.navigationTitle(L("help.title"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("done")) { dismiss() } } }
        }
    }
}
