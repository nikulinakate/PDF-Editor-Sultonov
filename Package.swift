// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFEditorCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PDFEditorCore", targets: ["PDFEditorCore"])],
    targets: [
        .target(name: "PDFCompression", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "PDFEditorCore", dependencies: ["PDFCompression"], resources: [.process("Resources")]),
        .testTarget(name: "PDFEditorCoreTests", dependencies: ["PDFEditorCore"])
    ]
)
