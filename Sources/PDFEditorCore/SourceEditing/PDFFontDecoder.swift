import Foundation

struct PDFFontDecoder {
    let name: String
    private let unicode: [Data: String]
    private let codeLengths: [Int]
    private let simple: Bool

    init(document: PDFObjectDocument, value: PDFValue) throws {
        let font = try document.dictionary(value)
        guard font["Subtype"]?.name != "Type3", font["Encoding"]?.name != "Identity-V" else { throw PDFEditorError.sourceTextUnsupported }
        name = font["BaseFont"]?.name ?? "Unknown"
        if let cmap = font["ToUnicode"] {
            unicode = try Self.readCMap(document.decodedStream(cmap))
            codeLengths = Set(unicode.keys.map(\.count)).sorted(by: >)
            simple = false
            guard !unicode.isEmpty else { throw PDFEditorError.sourceTextUnsupported }
        } else {
            guard font["Subtype"]?.name != "Type0", font["Subtype"]?.name != "Type3" else { throw PDFEditorError.sourceTextUnsupported }
            if let encoding = font["Encoding"] {
                guard try document.resolved(encoding).name == "WinAnsiEncoding" else { throw PDFEditorError.sourceTextUnsupported }
            } else {
                guard ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic", "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique"].contains(name) else { throw PDFEditorError.sourceTextUnsupported }
            }
            unicode = [:]; codeLengths = [1]; simple = true
        }
    }

    func decode(_ bytes: Data) throws -> String {
        if simple {
            guard let text = String(data: bytes, encoding: .windowsCP1252) else { throw PDFEditorError.sourceTextUnsupported }
            return text
        }
        var text = ""; var position = 0
        while position < bytes.count {
            var found = false
            for length in codeLengths where position + length <= bytes.count {
                if let value = unicode[bytes.subdata(in: position..<(position + length))] {
                    text += value; position += length; found = true; break
                }
            }
            guard found else { throw PDFEditorError.sourceTextUnsupported }
        }
        return text
    }

    private static func readCMap(_ data: Data) throws -> [Data: String] {
        var lexer = PDFLexer(data); var mapping: [Data: String] = [:]
        func decoded(_ bytes: Data) throws -> String {
            guard bytes.count % 2 == 0, let string = String(data: bytes, encoding: .utf16BigEndian) else { throw PDFEditorError.sourceTextUnsupported }
            return string
        }
        func increment(_ data: Data, by value: Int) throws -> Data {
            guard !data.isEmpty, data.count <= 4 else { throw PDFEditorError.sourceTextUnsupported }
            var number = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } + UInt64(value)
            guard number < (UInt64(1) << (data.count * 8)) else { throw PDFEditorError.sourceTextUnsupported }
            var result = [UInt8](repeating: 0, count: data.count)
            for index in result.indices.reversed() { result[index] = UInt8(number & 255); number >>= 8 }
            return Data(result)
        }
        while lexer.position < lexer.bytes.count {
            lexer.skip(); if lexer.position == lexer.bytes.count { break }
            let token = try lexer.value()
            guard case .keyword(let command) = token else { continue }
            if command == "beginbfchar" {
                while true {
                    let key = try lexer.value()
                    if case .keyword("endbfchar") = key { break }
                    guard let source = key.string, let target = try lexer.value().string, !source.isEmpty, source.count <= 4 else { throw PDFEditorError.sourceTextUnsupported }
                    mapping[source] = try decoded(target)
                    guard mapping.count <= 65_536 else { throw PDFEditorError.sourceTextUnsupported }
                }
            } else if command == "beginbfrange" {
                while true {
                    let key = try lexer.value()
                    if case .keyword("endbfrange") = key { break }
                    guard let first = key.string, let last = try lexer.value().string,
                          first.count == last.count, !first.isEmpty, first.count <= 4 else { throw PDFEditorError.sourceTextUnsupported }
                    let low = first.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    let high = last.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    guard high >= low, high - low < 65_536 else { throw PDFEditorError.sourceTextUnsupported }
                    let target = try lexer.value()
                    for offset in 0...Int(high - low) {
                        let value: Data
                        if let array = target.array {
                            guard offset < array.count, let string = array[offset].string else { throw PDFEditorError.sourceTextUnsupported }
                            value = string
                        } else {
                            guard let string = target.string else { throw PDFEditorError.sourceTextUnsupported }
                            value = try increment(string, by: offset)
                        }
                        mapping[try increment(first, by: offset)] = try decoded(value)
                    }
                    guard mapping.count <= 65_536 else { throw PDFEditorError.sourceTextUnsupported }
                }
            }
        }
        return mapping
    }
}
