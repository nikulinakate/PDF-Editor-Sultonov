import SwiftUI
import PDFKit
import PDFEditorCore

@MainActor
final class PDFViewControllerBridge {
    weak var view: PDFView?
    func go(to index: Int) { if let page = view?.document?.page(at: index) { view?.go(to: page) } }
    func select(_ selection: PDFSelection) { view?.setCurrentSelection(selection, animate: true); view?.go(to: selection) }
}

struct PDFCanvas: UIViewRepresentable {
    @ObservedObject var session: PDFEditingSession
    var tool: EditorTool
    var inkColor: UIColor
    var bridge: PDFViewControllerBridge
    var onPageChanged: (Int) -> Void
    var onTap: (CGPoint, PDFPage, PDFAnnotation?) -> Void
    var onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CanvasContainer {
        let container = CanvasContainer()
        let pdf = container.pdf
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.backgroundColor = .secondarySystemBackground
        pdf.document = session.document
        bridge.view = pdf
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdf, queue: .main) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let page = coordinator.container?.pdf.currentPage else { return }
                let document = coordinator.parent.session.document
                let index = document.index(for: page)
                if index != NSNotFound { coordinator.parent.onPageChanged(index) }
            }
        }
        context.coordinator.container = container
        configure(container)
        return container
    }

    func updateUIView(_ container: CanvasContainer, context: Context) {
        context.coordinator.parent = self
        if container.pdf.document !== session.document {
            let oldIndex = container.pdf.currentPage.flatMap { container.pdf.document?.index(for: $0) } ?? 0
            container.pdf.document = session.document
            if let page = session.document.page(at: min(oldIndex, max(0, session.document.pageCount - 1))) { container.pdf.go(to: page) }
        }
        configure(container)
        if context.coordinator.revision != session.revision {
            context.coordinator.revision = session.revision
            container.pdf.layoutDocumentView()
            container.pdf.setNeedsDisplay()
            container.pdf.documentView?.setNeedsDisplay()
        }
    }

    private func configure(_ container: CanvasContainer) {
        container.overlay.tool = tool
        container.overlay.inkColor = inkColor
        container.overlay.onTap = onTap
        container.overlay.onInk = { points, page in
            do { try session.addInk(strokes: [points], pageIndex: session.document.index(for: page), color: inkColor) }
            catch { onError(error) }
        }
    }

    static func dismantleUIView(_ view: CanvasContainer, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
    }

    @MainActor final class Coordinator {
        var parent: PDFCanvas
        weak var container: CanvasContainer?
        var observer: NSObjectProtocol?
        var revision = -1
        init(_ parent: PDFCanvas) { self.parent = parent }
    }
}

final class CanvasContainer: UIView {
    let pdf = PDFView()
    let overlay = ToolOverlay()
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(pdf); addSubview(overlay); overlay.pdf = pdf
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); pdf.frame = bounds; overlay.frame = bounds }
}

final class ToolOverlay: UIView {
    weak var pdf: PDFView?
    var tool = EditorTool.browse
    var inkColor = UIColor.systemBlue
    var onTap: ((CGPoint, PDFPage, PDFAnnotation?) -> Void)?
    var onInk: (([CGPoint], PDFPage) -> Void)?
    private let preview = CAShapeLayer()
    private var activePage: PDFPage?
    private var points: [CGPoint] = []
    private var displayPoints: [CGPoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        preview.fillColor = nil; preview.lineCap = .round; preview.lineJoin = .round
        layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point), let pdf else { return nil }
        if tool != .browse { return self }
        guard let page = pdf.page(for: point, nearest: false) else { return nil }
        let annotation = annotation(at: pdf.convert(point, to: page), page: page)
        // Widgets are filled through the tracked sheet, so native PDFView edits cannot bypass Undo/autosave.
        if annotation?.type == "Widget" || annotation?.type == "FreeText" { return self }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        clear()
        guard event?.allTouches?.count == 1, let touch = touches.first, let pdf,
              let page = pdf.page(for: touch.location(in: self), nearest: false) else { return }
        activePage = page
        if tool == .ink { append(touch.location(in: self)) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tool == .ink, event?.allTouches?.count == 1, let touch = touches.first else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] { append(sample.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        defer { clear() }
        guard let page = activePage, let touch = touches.first, let pdf else { return }
        if tool == .ink { append(touch.location(in: self)); onInk?(points, page) }
        else {
            let point = pdf.convert(touch.location(in: self), to: page)
            guard page.bounds(for: .cropBox).contains(point) else { return }
            onTap?(point, page, annotation(at: point, page: page))
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { clear() }

    private func append(_ location: CGPoint) {
        guard let page = activePage, let pdf else { return }
        let point = pdf.convert(location, to: page)
        guard page.bounds(for: .cropBox).contains(point) else { return }
        points.append(point); displayPoints.append(location)
        let path = UIBezierPath()
        if let first = displayPoints.first {
            path.move(to: first)
            for value in displayPoints.dropFirst() { path.addLine(to: value) }
        }
        preview.path = path.cgPath
        preview.strokeColor = inkColor.cgColor
        preview.lineWidth = 2 * pdf.scaleFactor
    }

    private func annotation(at point: CGPoint, page: PDFPage) -> PDFAnnotation? {
        page.annotations.reversed().first { annotation in
            guard annotation.bounds.contains(point) else { return false }
            guard annotation.type == "Ink", let paths = annotation.paths else { return true }
            let local = CGPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
            return paths.contains {
                $0.cgPath.copy(strokingWithWidth: max(12, annotation.border?.lineWidth ?? 2), lineCap: .round, lineJoin: .round, miterLimit: 1).contains(local)
            }
        }
    }

    private func clear() { activePage = nil; points.removeAll(); displayPoints.removeAll(); preview.path = nil }
}
