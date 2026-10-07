import Foundation

public enum PDFEditorError: Error, LocalizedError, Equatable {
    case invalidDocument, lockedDocument, permissionDenied, invalidPage
    case lastPage, emptySelection, exportFailed, invalidName, unsupportedContentEditing

    public var errorDescription: String? {
        NSLocalizedString("error.\(self)", bundle: .module, comment: "PDF editor error")
    }
}

public enum DocumentPolicy {
    public static func filename(_ proposed: String) throws -> String {
        var name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".pdf") { name.removeLast(4) }
        let illegal = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
        guard !name.isEmpty, name != ".", name != "..",
              name.rangeOfCharacter(from: illegal) == nil, name.utf8.count <= 180 else {
            throw PDFEditorError.invalidName
        }
        return name + ".pdf"
    }

    /// Parses human page numbers such as "1, 3-5" into unique zero-based indices.
    public static func pageIndices(_ expression: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw PDFEditorError.invalidDocument }
        var selected = Set<Int>()
        let parts = expression.split(separator: ",", omittingEmptySubsequences: false)
        for part in parts {
            let range = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(range.count),
                  let first = Int(range[0].trimmingCharacters(in: .whitespaces)), first >= 1,
                  first <= pageCount else { throw PDFEditorError.invalidPage }
            let last: Int
            if range.count == 2 {
                guard let parsed = Int(range[1].trimmingCharacters(in: .whitespaces)),
                      parsed >= first, parsed <= pageCount else { throw PDFEditorError.invalidPage }
                last = parsed
            } else { last = first }
            for page in first...last { selected.insert(page - 1) }
        }
        guard !selected.isEmpty else { throw PDFEditorError.emptySelection }
        return selected.sorted()
    }

    public static func movedOrder(count: Int, from: Int, to: Int) throws -> [Int] {
        guard (0..<count).contains(from), (0..<count).contains(to) else { throw PDFEditorError.invalidPage }
        var order = Array(0..<count)
        order.insert(order.remove(at: from), at: to)
        return order
    }
}
