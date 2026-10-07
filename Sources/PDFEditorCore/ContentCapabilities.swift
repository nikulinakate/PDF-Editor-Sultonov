import Foundation

public struct ContentCapabilities: Equatable {
    public let canAnnotate = true
    public let canOrganizePages = true
    /// Available for supported source text objects; inspect the document before enabling a selection.
    public let canReplaceExistingText = true
    public let canReplaceExistingImages = false
    public let canPermanentlyRedact = false
    public init() {}
}
