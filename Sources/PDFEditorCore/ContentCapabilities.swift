import Foundation

public struct ContentCapabilities: Equatable {
    public let canAnnotate = true
    public let canOrganizePages = true
    public let canReplaceExistingText = false
    public let canReplaceExistingImages = false
    public let canPermanentlyRedact = false
    public init() {}
}

/// Contract for the next engine stage. No overlay is advertised as source-text editing.
public protocol PDFContentEditing {
    var capabilities: ContentCapabilities { get }
    func replaceExistingText(onPage: Int, range: NSRange, with text: String) throws
}

public struct NativeContentEditor: PDFContentEditing {
    public let capabilities = ContentCapabilities()
    public init() {}
    public func replaceExistingText(onPage: Int, range: NSRange, with text: String) throws {
        throw PDFEditorError.unsupportedContentEditing
    }
}
