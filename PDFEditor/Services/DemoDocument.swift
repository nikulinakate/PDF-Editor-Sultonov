import PDFKit
import UIKit

enum DemoDocument {
    static func make() -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<3 {
                context.beginPage()
                UIColor(red: 0.23, green: 0.29, blue: 0.86, alpha: 1).setFill()
                context.cgContext.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 12))
                draw(L("demo.title.\(index)"), at: CGRect(x: 48, y: 70, width: 500, height: 110), size: 30, bold: true)
                draw(L("demo.body.\(index)"), at: CGRect(x: 48, y: 190, width: 495, height: 280), size: 17)
                draw("PDF EDITOR  /  \(index + 1)", at: CGRect(x: 48, y: 780, width: 400, height: 25), size: 10)
            }
        }
        guard let document = PDFDocument(data: data), let page = document.page(at: 1) else { return data }
        let field = PDFAnnotation(bounds: CGRect(x: 48, y: 300, width: 360, height: 36), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = L("demo.field")
        field.backgroundColor = UIColor(white: 0.96, alpha: 1)
        field.font = .systemFont(ofSize: 17)
        field.fontColor = .black
        field.widgetStringValue = ""
        page.addAnnotation(field)
        return document.dataRepresentation() ?? data
    }

    private static func draw(_ text: String, at rect: CGRect, size: CGFloat, bold: Bool = false) {
        (text as NSString).draw(in: rect, withAttributes: [
            .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
            .foregroundColor: UIColor.black
        ])
    }
}
