import PDFKit
import Vision
import UIKit
import PDFEditorCore

enum OCRService {
    @MainActor static func recognize(page: PDFPage) async throws -> String {
        guard let document = page.document, !document.isLocked, document.allowsCopying else {
            throw PDFEditorError.permissionDenied
        }
        let bounds = page.bounds(for: .cropBox)
        let scale = min(3, 2_000 / max(bounds.width, bounds.height))
        let rendered = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
        guard let image = rendered.cgImage else { throw PDFEditorError.invalidDocument }
        let text = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            let preferred = ["en-US", "ru-RU"].filter { supported.contains($0) }
            if !preferred.isEmpty { request.recognitionLanguages = preferred }
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
        try Task.checkCancellation()
        return text
    }
}
