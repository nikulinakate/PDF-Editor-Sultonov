#if canImport(UIKit) && canImport(PDFKit)
import PDFKit
import UIKit

public enum MarkupKind { case highlight, underline, strikeOut }

extension PDFEditingSession {
    public func addText(_ text: String, pageIndex: Int, bounds: CGRect,
                        fontSize: CGFloat = 18, color: UIColor = .label) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let target = try page(at: pageIndex)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = .systemFont(ofSize: fontSize)
        annotation.fontColor = color
        annotation.color = .clear
        annotation.border = PDFBorder()
        annotation.border?.lineWidth = 0
        annotation.alignment = .left
        try mutate(allowed: canAnnotate) { target.addAnnotation(annotation) }
    }

    public func addInk(strokes: [[CGPoint]], pageIndex: Int, color: UIColor, width: CGFloat = 2) throws {
        let target = try page(at: pageIndex)
        let valid = strokes.filter { $0.count > 1 }
        guard !valid.isEmpty else { return }
        // Full page coordinates avoid flipped or misplaced strokes after save/reopen.
        let bounds = target.bounds(for: .mediaBox)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        annotation.color = color
        let border = PDFBorder(); border.lineWidth = width; annotation.border = border
        for points in valid {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
            }
            annotation.add(path)
        }
        try mutate(allowed: canAnnotate) { target.addAnnotation(annotation) }
    }

    public func addMarkup(selection: PDFSelection, kind: MarkupKind, color: UIColor) throws {
        let lines = selection.selectionsByLine()
        guard !lines.isEmpty else { throw PDFEditorError.emptySelection }
        let subtype: PDFAnnotationSubtype
        switch kind { case .highlight: subtype = .highlight; case .underline: subtype = .underline; case .strikeOut: subtype = .strikeOut }
        try mutate(allowed: canAnnotate) {
            for line in lines {
                for page in line.pages {
                    let rect = line.bounds(for: page)
                    guard !rect.isEmpty, !rect.isInfinite else { continue }
                    let annotation = PDFAnnotation(bounds: rect, forType: subtype, withProperties: nil)
                    annotation.color = color
                    page.addAnnotation(annotation)
                }
            }
        }
    }

    public func addShape(pageIndex: Int, bounds: CGRect, circle: Bool, color: UIColor) throws {
        let target = try page(at: pageIndex)
        let annotation = PDFAnnotation(bounds: bounds, forType: circle ? .circle : .square, withProperties: nil)
        annotation.color = color
        let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
        try mutate(allowed: canAnnotate) { target.addAnnotation(annotation) }
    }

    public func removeAnnotation(_ annotation: PDFAnnotation) throws {
        guard let page = annotation.page, annotation.type != "Widget", annotation.type != "Link" else {
            throw PDFEditorError.permissionDenied
        }
        try mutate(allowed: canAnnotate) { page.removeAnnotation(annotation) }
    }

    public func updateTextAnnotation(_ annotation: PDFAnnotation, text: String, fontSize: CGFloat,
                                     color: UIColor, bounds: CGRect) throws {
        guard annotation.page != nil, annotation.type == "FreeText" else { throw PDFEditorError.permissionDenied }
        try mutate(allowed: canAnnotate) {
            annotation.contents = text
            annotation.font = .systemFont(ofSize: fontSize)
            annotation.fontColor = color
            annotation.bounds = bounds
        }
    }

    public func fillTextField(_ annotation: PDFAnnotation, value: String) throws {
        guard annotation.page != nil, annotation.type == "Widget", annotation.widgetFieldType == .text,
              !annotation.isReadOnly else { throw PDFEditorError.permissionDenied }
        try mutate(allowed: canFillForms) {
            annotation.widgetStringValue = annotation.maximumLength > 0 ? String(value.prefix(annotation.maximumLength)) : value
        }
    }
}
#endif
