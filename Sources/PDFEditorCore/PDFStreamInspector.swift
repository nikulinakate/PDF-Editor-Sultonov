#if canImport(CoreGraphics) && canImport(UIKit)
import CoreGraphics
import PDFKit

public struct PDFStreamSummary: Equatable {
    public let textDrawingCommands: Int
    public let externalObjectDrawingCommands: Int
}

private final class StreamCounter {
    var text = 0
    var externalObjects = 0
}

/// First low-level analysis stage: walks source operators without rewriting or flattening the page.
public enum PDFStreamInspector {
    public static func inspect(page: PDFPage) throws -> PDFStreamSummary {
        guard let document = page.document, !document.isLocked, document.allowsCopying,
              let reference = page.pageRef,
              let stream = CGPDFContentStreamCreateWithPage(reference),
              let table = CGPDFOperatorTableCreate() else { throw PDFEditorError.permissionDenied }
        let counter = StreamCounter()
        let pointer = Unmanaged.passUnretained(counter).toOpaque()
        CGPDFOperatorTableSetCallback(table, "Tj", countTextCommand)
        CGPDFOperatorTableSetCallback(table, "TJ", countTextCommand)
        CGPDFOperatorTableSetCallback(table, "'", countTextCommand)
        CGPDFOperatorTableSetCallback(table, "\"", countTextCommand)
        CGPDFOperatorTableSetCallback(table, "Do", countExternalObjectCommand)
        guard let scanner = CGPDFScannerCreate(stream, table, pointer), CGPDFScannerScan(scanner) else {
            throw PDFEditorError.invalidDocument
        }
        return PDFStreamSummary(textDrawingCommands: counter.text, externalObjectDrawingCommands: counter.externalObjects)
    }
}

private func countTextCommand(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<StreamCounter>.fromOpaque(info).takeUnretainedValue().text += 1
}

private func countExternalObjectCommand(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    Unmanaged<StreamCounter>.fromOpaque(info).takeUnretainedValue().externalObjects += 1
}
#endif
