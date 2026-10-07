import Foundation
import PDFCompression

/// Conservative classic-xref reader. Unsupported encodings fail before any file is changed.
final class PDFObjectDocument {
    let data: Data
    private(set) var trailer: [String: PDFValue] = [:]
    private var offsets: [PDFReference: Int] = [:]
    private var loading = Set<PDFReference>()
    var objects: [PDFReference: PDFValue] = [:]
    var nextObject = 1

    init(data: Data) throws {
        guard data.count <= 64 * 1_024 * 1_024, data.starts(with: Data("%PDF-".utf8)),
              let marker = data.range(of: Data("startxref".utf8), options: .backwards) else { throw PDFEditorError.sourceStructureUnsupported }
        self.data = data
        var end = PDFLexer(data, at: marker.upperBound)
        guard let offset = Int(try end.word()), offset > 0, offset < data.count else { throw PDFEditorError.invalidDocument }
        var lexer = PDFLexer(data, at: offset)
        guard (try? lexer.word()) == "xref" else { throw PDFEditorError.sourceStructureUnsupported }
        while true {
            let token = try lexer.word()
            if token == "trailer" { break }
            guard let first = Int(token), let count = Int(try lexer.word()), first >= 0, count >= 0,
                  first <= 200_000, count <= 200_000 - first, offsets.count + count <= 100_000 else { throw PDFEditorError.sourceStructureUnsupported }
            for number in first..<(first + count) {
                guard let position = Int(try lexer.word()), let generation = Int(try lexer.word()),
                      (0...65535).contains(generation) else { throw PDFEditorError.invalidDocument }
                let state = try lexer.word()
                if state == "n" {
                    guard number > 0, position > 0, position < data.count else { throw PDFEditorError.invalidDocument }
                    let ref = PDFReference(object: number, generation: generation)
                    guard offsets[ref] == nil else { throw PDFEditorError.invalidDocument }
                    offsets[ref] = position
                } else if state != "f" { throw PDFEditorError.invalidDocument }
            }
        }
        guard case .dictionary(let dictionary) = try lexer.value(), dictionary["Root"]?.reference != nil else { throw PDFEditorError.invalidDocument }
        guard dictionary["Encrypt"] == nil, dictionary["Prev"] == nil, dictionary["XRefStm"] == nil else { throw PDFEditorError.sourceStructureUnsupported }
        trailer = dictionary
        nextObject = (offsets.keys.map(\.object).max() ?? 0) + 1
    }

    func object(_ ref: PDFReference) throws -> PDFValue {
        if let cached = objects[ref] { return cached }
        guard !loading.contains(ref), let offset = offsets[ref] else { throw PDFEditorError.invalidDocument }
        loading.insert(ref); defer { loading.remove(ref) }
        var lexer = PDFLexer(data, at: offset)
        guard Int(try lexer.word()) == ref.object, Int(try lexer.word()) == ref.generation,
              try lexer.word() == "obj" else { throw PDFEditorError.invalidDocument }
        var value = try lexer.value()
        lexer.skip()
        if case .dictionary(let dictionary) = value {
            let start = lexer.position
            if (try? lexer.word()) == "stream" {
                guard lexer.position < lexer.bytes.count else { throw PDFEditorError.invalidDocument }
                if lexer.bytes[lexer.position] == 13 { lexer.position += 1; if lexer.position < lexer.bytes.count && lexer.bytes[lexer.position] == 10 { lexer.position += 1 } }
                else if lexer.bytes[lexer.position] == 10 { lexer.position += 1 }
                else { throw PDFEditorError.invalidDocument }
                guard let lengthValue = dictionary["Length"], let length = try resolved(lengthValue).number,
                      length >= 0, length.rounded() == length, length <= Double(data.count),
                      lexer.position + Int(length) <= data.count else { throw PDFEditorError.invalidDocument }
                let bytes = Data(lexer.bytes[lexer.position..<(lexer.position + Int(length))])
                lexer.position += Int(length)
                guard try lexer.word() == "endstream" else { throw PDFEditorError.invalidDocument }
                value = .stream(dictionary, bytes)
            } else { lexer.position = start }
        }
        guard try lexer.word() == "endobj" else { throw PDFEditorError.invalidDocument }
        objects[ref] = value
        return value
    }

    func resolved(_ value: PDFValue, depth: Int = 0) throws -> PDFValue {
        guard depth < 80 else { throw PDFEditorError.invalidDocument }
        if case .reference(let ref) = value { return try resolved(object(ref), depth: depth + 1) }
        return value
    }

    func dictionary(_ value: PDFValue) throws -> [String: PDFValue] {
        guard let dictionary = try resolved(value).dictionary else { throw PDFEditorError.invalidDocument }
        return dictionary
    }

    func pages() throws -> [PDFReference] {
        let root = try dictionary(trailer["Root"]!)
        guard let pages = root["Pages"]?.reference else { throw PDFEditorError.invalidDocument }
        var visited = Set<PDFReference>()
        func walk(_ ref: PDFReference, depth: Int) throws -> [PDFReference] {
            guard depth < 80, visited.insert(ref).inserted else { throw PDFEditorError.invalidDocument }
            let node = try dictionary(.reference(ref))
            if node["Type"]?.name == "Page" { return [ref] }
            guard node["Type"]?.name == "Pages", let children = node["Kids"],
                  let kids = try resolved(children).array else { throw PDFEditorError.invalidDocument }
            return try kids.flatMap { value -> [PDFReference] in
                guard let ref = value.reference else { throw PDFEditorError.invalidDocument }
                return try walk(ref, depth: depth + 1)
            }
        }
        let result = try walk(pages, depth: 0)
        guard !result.isEmpty else { throw PDFEditorError.invalidDocument }
        return result
    }

    func inherited(_ key: String, page: PDFReference) throws -> PDFValue? {
        var current: PDFReference? = page; var seen = Set<PDFReference>()
        while let ref = current {
            guard seen.insert(ref).inserted, seen.count < 80 else { throw PDFEditorError.invalidDocument }
            let node = try dictionary(.reference(ref))
            if let value = node[key] { return value }
            current = node["Parent"]?.reference
        }
        return nil
    }

    func pageContent(_ page: PDFReference) throws -> Data {
        let dictionary = try self.dictionary(.reference(page))
        guard let contents = dictionary["Contents"] else { return Data() }
        let resolvedContents = try resolved(contents)
        let streams = resolvedContents.array ?? [contents]
        var combined = Data()
        for value in streams {
            combined.append(try decodedStream(value)); combined.append(10)
            guard combined.count <= 16 * 1_024 * 1_024 else { throw PDFEditorError.sourceStructureUnsupported }
        }
        return combined
    }

    func decodedStream(_ value: PDFValue) throws -> Data {
        guard case .stream(let dictionary, let bytes) = try resolved(value) else { throw PDFEditorError.invalidDocument }
        guard let filter = dictionary["Filter"] else { return bytes }
        let resolvedFilter = try resolved(filter)
        let filters = resolvedFilter.array ?? [resolvedFilter]
        guard filters.count == 1, filters[0].name == "FlateDecode" || filters[0].name == "Fl" else { throw PDFEditorError.sourceStructureUnsupported }
        if let parameters = dictionary["DecodeParms"] {
            let value = try resolved(parameters)
            switch value {
            case .null: break
            case .array(let values): guard values.count == 1, case .null = values[0] else { throw PDFEditorError.sourceStructureUnsupported }
            case .dictionary(let values): guard (values["Predictor"]?.number ?? 1) == 1 else { throw PDFEditorError.sourceStructureUnsupported }
            default: throw PDFEditorError.sourceStructureUnsupported
            }
        }
        var output = Data(count: 16 * 1_024 * 1_024)
        var written = 0
        let status = output.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in
                pe_inflate(source.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                           destination.bindMemory(to: UInt8.self).baseAddress, destination.count, &written)
            }
        }
        guard status == 0 else { throw PDFEditorError.sourceStructureUnsupported }
        output.count = written
        return output
    }

    @discardableResult func add(_ value: PDFValue) throws -> PDFReference {
        guard nextObject < 200_000 else { throw PDFEditorError.sourceStructureUnsupported }
        let ref = PDFReference(object: nextObject, generation: 0)
        nextObject += 1; objects[ref] = value
        return ref
    }

    /// Rewrite only reachable objects: retired text streams and earlier revisions are not appended to the output.
    func writtenData() throws -> Data {
        var reachable = Set<PDFReference>()
        func visit(_ value: PDFValue, depth: Int) throws {
            guard depth < 150 else { throw PDFEditorError.sourceStructureUnsupported }
            switch value {
            case .reference(let ref):
                if reachable.insert(ref).inserted { try visit(object(ref), depth: depth + 1) }
            case .array(let values): for value in values { try visit(value, depth: depth + 1) }
            case .dictionary(let dictionary), .stream(let dictionary, _):
                guard dictionary["ByteRange"] == nil, dictionary["Type"]?.name != "Sig", dictionary["FT"]?.name != "Sig",
                      dictionary["XFA"] == nil else { throw PDFEditorError.sourceStructureUnsupported }
                for value in dictionary.values { try visit(value, depth: depth + 1) }
            default: break
            }
        }
        guard let root = trailer["Root"] else { throw PDFEditorError.invalidDocument }
        try visit(root, depth: 0)
        if let info = trailer["Info"] { try visit(info, depth: 0) }
        var output = Data("%PDF-1.7\n%".utf8); output.append(contentsOf: [226, 227, 207, 211, 10])
        var positions: [Int: (Int, Int)] = [:]
        for ref in reachable.sorted(by: { $0.object < $1.object }) {
            guard positions[ref.object] == nil else { throw PDFEditorError.invalidDocument }
            positions[ref.object] = (output.count, ref.generation)
            output.append(Data("\(ref.object) \(ref.generation) obj\n".utf8))
            output.append(try pdfEncoded(object(ref))); output.append(Data("\nendobj\n".utf8))
            guard output.count <= 96 * 1_024 * 1_024 else { throw PDFEditorError.sourceStructureUnsupported }
        }
        let xref = output.count; let size = (positions.keys.max() ?? 0) + 1
        output.append(Data("xref\n0 \(size)\n0000000000 65535 f \n".utf8))
        for index in 1..<size {
            if let (offset, generation) = positions[index] { output.append(Data(String(format: "%010d %05d n \n", offset, generation).utf8)) }
            else { output.append(Data("0000000000 00000 f \n".utf8)) }
        }
        var dictionary: [String: PDFValue] = ["Size": .number(Double(size)), "Root": root]
        if let info = trailer["Info"] { dictionary["Info"] = info }
        if let id = trailer["ID"] { dictionary["ID"] = id }
        output.append(Data("trailer\n".utf8)); output.append(try pdfEncoded(.dictionary(dictionary)))
        output.append(Data("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return output
    }
}
