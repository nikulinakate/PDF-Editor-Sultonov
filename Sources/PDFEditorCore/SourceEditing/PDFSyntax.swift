import Foundation

struct PDFReference: Hashable {
    let object: Int
    let generation: Int
}

indirect enum PDFValue {
    case number(Double), name(String), string(Data), array([PDFValue]), dictionary([String: PDFValue])
    case reference(PDFReference), stream([String: PDFValue], Data), boolean(Bool), null, keyword(String)

    var number: Double? { if case .number(let n) = self { return n }; return nil }
    var name: String? { if case .name(let n) = self { return n }; return nil }
    var string: Data? { if case .string(let d) = self { return d }; return nil }
    var array: [PDFValue]? { if case .array(let a) = self { return a }; return nil }
    var dictionary: [String: PDFValue]? {
        if case .dictionary(let d) = self { return d }
        if case .stream(let d, _) = self { return d }
        return nil
    }
    var reference: PDFReference? { if case .reference(let r) = self { return r }; return nil }
}

/// Byte-based lexer: stream offsets and string escapes are never interpreted as UTF-8 offsets.
struct PDFLexer {
    let bytes: [UInt8]
    var position: Int
    init(_ data: Data, at: Int = 0) { bytes = Array(data); position = at }
    static func whitespace(_ byte: UInt8) -> Bool { [0, 9, 10, 12, 13, 32].contains(byte) }
    static func delimiter(_ byte: UInt8) -> Bool { whitespace(byte) || [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(byte) }
    mutating func skip() {
        while position < bytes.count {
            if Self.whitespace(bytes[position]) { position += 1 }
            else if bytes[position] == 37 {
                while position < bytes.count && ![10, 13].contains(bytes[position]) { position += 1 }
            } else { break }
        }
    }
    mutating func word() throws -> String {
        skip(); let start = position
        while position < bytes.count && !Self.delimiter(bytes[position]) { position += 1 }
        guard position > start else { throw PDFEditorError.invalidDocument }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }
    mutating func value(depth: Int = 0) throws -> PDFValue {
        guard depth < 80 else { throw PDFEditorError.sourceStructureUnsupported }
        skip(); guard position < bytes.count else { throw PDFEditorError.invalidDocument }
        switch bytes[position] {
        case 47:
            position += 1; var result: [UInt8] = []
            while position < bytes.count && !Self.delimiter(bytes[position]) {
                if bytes[position] == 35, position + 2 < bytes.count,
                   let code = UInt8(String(decoding: bytes[(position + 1)...(position + 2)], as: UTF8.self), radix: 16) {
                    result.append(code); position += 3
                } else { result.append(bytes[position]); position += 1 }
            }
            return .name(String(decoding: result, as: UTF8.self))
        case 40: return .string(try literalString())
        case 60:
            if position + 1 < bytes.count && bytes[position + 1] == 60 {
                position += 2; var result: [String: PDFValue] = [:]
                while true {
                    skip()
                    if position + 1 < bytes.count && bytes[position] == 62 && bytes[position + 1] == 62 {
                        position += 2; return .dictionary(result)
                    }
                    guard case .name(let key) = try value(depth: depth + 1), result[key] == nil else { throw PDFEditorError.invalidDocument }
                    result[key] = try value(depth: depth + 1)
                    guard result.count < 100_000 else { throw PDFEditorError.sourceStructureUnsupported }
                }
            }
            position += 1; var hex: [UInt8] = []
            while position < bytes.count && bytes[position] != 62 {
                if !Self.whitespace(bytes[position]) { hex.append(bytes[position]) }
                position += 1
            }
            guard position < bytes.count else { throw PDFEditorError.invalidDocument }
            position += 1
            if hex.count % 2 != 0 { hex.append(48) }
            var decoded = Data()
            for offset in stride(from: 0, to: hex.count, by: 2) {
                guard let n = UInt8(String(decoding: hex[offset...offset + 1], as: UTF8.self), radix: 16) else { throw PDFEditorError.invalidDocument }
                decoded.append(n)
            }
            return .string(decoded)
        case 91:
            position += 1; var items: [PDFValue] = []
            while true {
                skip(); guard position < bytes.count else { throw PDFEditorError.invalidDocument }
                if bytes[position] == 93 { position += 1; return .array(items) }
                items.append(try value(depth: depth + 1))
                guard items.count < 100_000 else { throw PDFEditorError.sourceStructureUnsupported }
            }
        default:
            let token = try word()
            if let number = Double(token), number.isFinite {
                let afterFirst = position
                if number >= 0, number.rounded() == number, number <= 200_000,
                   let generationToken = try? word(), let generation = Int(generationToken), (0...65535).contains(generation),
                   (try? word()) == "R" { return .reference(PDFReference(object: Int(number), generation: generation)) }
                position = afterFirst
                return .number(number)
            }
            switch token { case "true": return .boolean(true); case "false": return .boolean(false); case "null": return .null; default: return .keyword(token) }
        }
    }
    private mutating func literalString() throws -> Data {
        position += 1; var nested = 1; var output = Data()
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == 92 {
                guard position < bytes.count else { throw PDFEditorError.invalidDocument }
                let next = bytes[position]; position += 1
                switch next {
                case 110: output.append(10)
                case 114: output.append(13)
                case 116: output.append(9)
                case 98: output.append(8)
                case 102: output.append(12)
                case 10: break
                case 13: if position < bytes.count && bytes[position] == 10 { position += 1 }
                case 48...55:
                    var digits = [next]
                    while digits.count < 3 && position < bytes.count && (48...55).contains(bytes[position]) { digits.append(bytes[position]); position += 1 }
                    guard let n = UInt16(String(decoding: digits, as: UTF8.self), radix: 8) else { throw PDFEditorError.invalidDocument }
                    output.append(UInt8(n & 255))
                default: output.append(next)
                }
            } else if byte == 40 { nested += 1; output.append(byte) }
            else if byte == 41 {
                nested -= 1
                if nested == 0 { return output }
                output.append(byte)
            } else if byte == 13 {
                output.append(10)
                if position < bytes.count && bytes[position] == 10 { position += 1 }
            } else { output.append(byte) }
        }
        throw PDFEditorError.invalidDocument
    }
}

func pdfNumber(_ value: Double) -> String {
    if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
    return String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
}

func pdfEncoded(_ value: PDFValue) throws -> Data {
    func text(_ value: String) -> Data { Data(value.utf8) }
    switch value {
    case .number(let n): guard n.isFinite else { throw PDFEditorError.invalidDocument }; return text(pdfNumber(n))
    case .name(let name):
        let safe = name.utf8.map { byte -> String in
            if byte < 33 || byte > 126 || PDFLexer.delimiter(byte) || byte == 35 { return String(format: "#%02X", byte) }
            return String(UnicodeScalar(byte))
        }.joined()
        return text("/" + safe)
    case .string(let data): return text("<" + data.map { String(format: "%02X", $0) }.joined() + ">")
    case .reference(let ref): return text("\(ref.object) \(ref.generation) R")
    case .boolean(let b): return text(b ? "true" : "false")
    case .null: return text("null")
    case .keyword: throw PDFEditorError.invalidDocument
    case .array(let values):
        var result = text("[")
        for v in values { result.append(try pdfEncoded(v)); result.append(32) }
        result.append(text("]")); return result
    case .dictionary(let dictionary):
        var result = text("<<")
        for key in dictionary.keys.sorted() { result.append(try pdfEncoded(.name(key))); result.append(32); result.append(try pdfEncoded(dictionary[key]!)); result.append(10) }
        result.append(text(">>")); return result
    case .stream(var dictionary, let data):
        dictionary["Length"] = .number(Double(data.count))
        var result = try pdfEncoded(.dictionary(dictionary)); result.append(text("\nstream\n")); result.append(data); result.append(text("\nendstream")); return result
    }
}
