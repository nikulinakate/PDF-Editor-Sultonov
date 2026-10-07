import SwiftUI
import PDFKit
import PDFEditorCore
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable {
    case browse, text, ink, signature, shape, eraser
    var icon: String {
        switch self {
        case .browse: return "hand.draw"
        case .text: return "textformat"
        case .ink: return "pencil.tip"
        case .signature: return "signature"
        case .shape: return "square.on.circle"
        case .eraser: return "eraser"
        }
    }
}

struct TextPlacement: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let bounds: CGRect
    var annotation: PDFAnnotation?
}

struct FormPlacement: Identifiable {
    let id = UUID()
    let annotation: PDFAnnotation
}

struct EditorView: View {
    let record: DocumentRecord
    @ObservedObject var session: PDFEditingSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var tool = EditorTool.browse
    @State private var pageIndex = 0
    @State private var color = Color(red: 0.12, green: 0.20, blue: 0.65)
    @State private var textPlacement: TextPlacement?
    @State private var formPlacement: FormPlacement?
    @State private var signaturePlacement: TextPlacement?
    @State private var pages = false
    @State private var searching = false
    @State private var inspecting = false
    @State private var password = ""
    @State private var incorrectPassword = false
    @State private var error: Message?
    @State private var share: SharePayload?
    @State private var controller = PDFViewControllerBridge()
    @State private var showDiscard = false
    @State private var saveFailureOnClose = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.document.isLocked { lockedView }
                else {
                    if session.document.isEncrypted {
                        Text(L("editor.encryptedReadOnly")).font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                    PDFCanvas(session: session, tool: tool, inkColor: UIColor(color), bridge: controller,
                              onPageChanged: { pageIndex = $0 }, onTap: handleTap,
                              onError: { error = Message($0) })
                        .background(Color(uiColor: .secondarySystemBackground))
                    toolBar
                }
            }
            .navigationTitle(record.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { navigationTools }
            .sheet(isPresented: $pages) {
                PageOrganizer(session: session, currentPage: pageIndex) { index in controller.go(to: index); pages = false }
            }
            .sheet(isPresented: $searching) { SearchView(session: session) { selection in controller.select(selection); searching = false } }
            .sheet(isPresented: $inspecting) { TextInspectorView(session: session, pageIndex: pageIndex) }
            .sheet(item: $textPlacement) { placement in
                TextAnnotationSheet(placement: placement, color: color) { text, size, selectedColor, bounds in
                    perform {
                        if let annotation = placement.annotation {
                            try session.updateTextAnnotation(annotation, text: text, fontSize: size, color: UIColor(selectedColor), bounds: bounds)
                        } else {
                            try session.addText(text, pageIndex: placement.pageIndex, bounds: bounds, fontSize: size, color: UIColor(selectedColor))
                        }
                    }
                }
            }
            .sheet(item: $formPlacement) { placement in
                FormFieldSheet(annotation: placement.annotation) { value in
                    perform { try session.fillTextField(placement.annotation, value: value) }
                }
            }
            .sheet(item: $signaturePlacement) { placement in
                SignatureSheet { strokes, size in
                    let bounds = placement.bounds
                    let points = strokes.map { $0.map { CGPoint(x: bounds.minX + $0.x / size.width * bounds.width,
                                                               y: bounds.maxY - $0.y / size.height * bounds.height) } }
                    perform { try session.addInk(strokes: points, pageIndex: placement.pageIndex, color: .black, width: 1.8) }
                }
            }
            .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
            .errorAlert($error)
            .confirmationDialog(L("editor.unsaved"), isPresented: $showDiscard, titleVisibility: .visible) {
                Button(L("editor.retrySave")) { close() }
                Button(L("editor.discard"), role: .destructive) { dismiss() }
                Button(L("cancel"), role: .cancel) {}
            } message: { Text(L("editor.unsavedHint")) }
            .onChange(of: session.revision) { _, _ in pageIndex = min(pageIndex, max(0, session.document.pageCount - 1)) }
            .task(id: session.revision) {
                guard session.isDirty else { return }
                do {
                    try await Task.sleep(for: .seconds(1.2))
                    try Task.checkCancellation()
                    try save()
                } catch is CancellationError {} catch { self.error = Message(error) }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { perform { try save() } } }
        }.interactiveDismissDisabled(session.isDirty)
    }

    private var lockedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.doc").font(.system(size: 52)).foregroundStyle(Theme.accent)
            Text(L("password.title")).font(.title2.bold())
            SecureField(L("password.placeholder"), text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
            if incorrectPassword { Text(L("password.incorrect")).foregroundStyle(.red) }
            Button(L("password.unlock")) {
                incorrectPassword = !session.unlock(password: password)
                if !incorrectPassword { password = "" }
            }.buttonStyle(.borderedProminent).disabled(password.isEmpty)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    @ToolbarContentBuilder private var navigationTools: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { Button(L("done")) { close() } }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { perform { try session.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.canUndo).accessibilityLabel(L("undo"))
            Button { perform { try session.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.canRedo).accessibilityLabel(L("redo"))
            Menu {
                Button(L("search"), systemImage: "magnifyingglass") { searching = true }.disabled(session.document.isLocked)
                Button(L("organize"), systemImage: "square.grid.2x2") { pages = true }.disabled(session.document.isLocked)
                Button(L("inspect.text"), systemImage: "text.magnifyingglass") { inspecting = true }.disabled(!session.document.allowsCopying || session.document.isLocked)
                Button(L("share"), systemImage: "square.and.arrow.up") { export() }.disabled(session.document.isLocked)
                Button(L("print"), systemImage: "printer") { printDocument() }.disabled(session.document.isLocked || !session.document.allowsPrinting)
                Button(L("share.original"), systemImage: "doc") { share = SharePayload(url: library.originalURL(for: record)) }
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel(L("more"))
        }
    }

    private var toolBar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(pageIndex + 1) / \(session.document.pageCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if tool != .browse && tool != .eraser { ColorPicker(L("color"), selection: $color, supportsOpacity: false).labelsHidden() }
                Text(L("tool.hint.\(tool.rawValue)")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button { pages = true } label: { Image(systemName: "square.grid.2x2") }.accessibilityLabel(L("organize"))
            }.padding(.horizontal, 16).padding(.vertical, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EditorTool.allCases, id: \.self) { item in
                        Button { tool = item } label: {
                            VStack(spacing: 5) { Image(systemName: item.icon).font(.title3); Text(L("tool.\(item.rawValue)")).font(.caption2) }
                                .frame(minWidth: 62, minHeight: 54)
                                .background(tool == item ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }.disabled(item != .browse && !session.canAnnotate)
                    }
                    Menu {
                        Button(L("highlight")) { mark(.highlight) }
                        Button(L("underline")) { mark(.underline) }
                        Button(L("strikeOut")) { mark(.strikeOut) }
                    } label: {
                        VStack(spacing: 5) { Image(systemName: "highlighter").font(.title3); Text(L("markup")).font(.caption2) }
                            .frame(minWidth: 62, minHeight: 54)
                    }.disabled(!session.canAnnotate)
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
        }.background(.bar)
    }

    private func handleTap(_ point: CGPoint, page: PDFPage, annotation: PDFAnnotation?) {
        let index = session.document.index(for: page)
        let crop = page.bounds(for: .cropBox)
        let width = min(CGFloat(220), crop.width)
        let height: CGFloat = tool == .signature ? min(90, crop.height) : min(70, crop.height)
        let bounds = CGRect(x: max(crop.minX, min(point.x, crop.maxX - width)),
                            y: max(crop.minY, min(point.y - height, crop.maxY - height)), width: width, height: height)
        switch tool {
        case .text:
            textPlacement = TextPlacement(pageIndex: index, bounds: bounds)
        case .signature:
            signaturePlacement = TextPlacement(pageIndex: index, bounds: bounds)
        case .shape:
            perform { try session.addShape(pageIndex: index, bounds: CGRect(x: bounds.minX, y: bounds.minY, width: min(100, crop.width), height: min(70, crop.height)), circle: false, color: UIColor(color)) }
        case .eraser:
            if let annotation { perform { try session.removeAnnotation(annotation) } }
        case .browse:
            if let annotation, annotation.type == "FreeText", session.canAnnotate {
                textPlacement = TextPlacement(pageIndex: index, bounds: annotation.bounds, annotation: annotation)
            } else if let annotation, annotation.type == "Widget", annotation.widgetFieldType == .text,
                      !annotation.isReadOnly, session.canFillForms {
                formPlacement = FormPlacement(annotation: annotation)
            }
        case .ink: break
        }
    }

    private func mark(_ kind: MarkupKind) {
        guard let selection = controller.view?.currentSelection else { error = Message(text: L("markup.selectHint")); return }
        perform { try session.addMarkup(selection: selection, kind: kind, color: kind == .highlight ? .systemYellow : UIColor(color)) }
        controller.view?.clearSelection()
    }

    private func save() throws {
        let wasDirty = session.isDirty
        try session.save()
        if wasDirty { try library.didSave(record, pageCount: session.document.pageCount) }
    }

    private func close() {
        do { try save(); dismiss() }
        catch { error = Message(error); saveFailureOnClose = true }
        // The recovery dialog is shown only after the error alert is dismissed.
        if saveFailureOnClose { showDiscard = true; saveFailureOnClose = false; error = nil }
    }

    private func export() {
        perform {
            try save()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(try DocumentPolicy.filename(record.name))
            try session.export(to: target)
            share = SharePayload(url: target)
        }
    }

    private func printDocument() {
        perform {
            let printController = UIPrintInteractionController.shared
            printController.printingItem = try session.serialized()
            let info = UIPrintInfo(dictionary: nil); info.jobName = record.name; info.outputType = .general
            printController.printInfo = info
            if let view = controller.view, UIDevice.current.userInterfaceIdiom == .pad {
                printController.present(from: CGRect(x: view.bounds.midX, y: 0, width: 1, height: 1), in: view, animated: true, completionHandler: nil)
            } else { printController.present(animated: true, completionHandler: nil) }
        }
    }

    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = Message(error) } }
}
