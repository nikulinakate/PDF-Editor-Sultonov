import Foundation

struct PDFMatrix {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, x = 0.0, y = 0.0
    func concatenating(_ t: PDFMatrix) -> PDFMatrix {
        PDFMatrix(a: a*t.a+c*t.b, b: b*t.a+d*t.b, c: a*t.c+c*t.d, d: b*t.c+d*t.d,
                  x: a*t.x+c*t.y+x, y: b*t.x+d*t.y+y)
    }
    func inverse() throws -> PDFMatrix {
        let det = a*d-b*c
        guard abs(det) > 0.000001 else { throw PDFEditorError.sourceTextUnsupported }
        return PDFMatrix(a: d/det, b: -b/det, c: -c/det, d: a/det,
                         x: (c*y-d*x)/det, y: (b*x-a*y)/det)
    }
    var command: String { [a,b,c,d,x,y].map(pdfNumber).joined(separator: " ") + " cm\n" }
}

public struct SourceTextBlock: Identifiable {
    public let id: Int
    public let pageIndex: Int
    public let text: String
    public let fontName: String
    public let fontSize: Double
    public let baselineX: Double
    public let baselineY: Double
    let snapshot: UUID
    let operands: [Range<Int>]
    let insertionOffset: Int
    let transform: PDFMatrix
}

/// A snapshot owns its selection offsets. Never apply a block to a different snapshot.
public final class NativeContentEditor {
    public let capabilities = ContentCapabilities()
    private let snapshot = UUID()
    private var consumed = false
    private let document: PDFObjectDocument
    private let pages: [PDFReference]
    private var inspected: [Int: [SourceTextBlock]] = [:]

    public init(data: Data) throws {
        document = try PDFObjectDocument(data: data)
        pages = try document.pages()
        // Check all reachable objects before offering edits, including signatures and XFA.
        _ = try document.writtenData()
    }

    public func textBlocks(onPage index: Int) throws -> [SourceTextBlock] {
        guard !consumed else { throw PDFEditorError.staleSourceSelection }
        guard pages.indices.contains(index) else { throw PDFEditorError.invalidPage }
        if let blocks = inspected[index] { return blocks }
        let page = pages[index]
        let resources = try document.inherited("Resources", page: page).map { try document.dictionary($0) } ?? [:]
        let fonts = try resources["Font"].map { try document.dictionary($0) } ?? [:]
        let content = try document.pageContent(page)
        var lexer = PDFLexer(content)
        var operands: [(PDFValue, Range<Int>)] = []
        struct State { var matrix = PDFMatrix(); var clipped = false }
        var state = State(), stack: [State] = []
        var textMatrix = PDFMatrix(), font = "", size = 0.0, rendering = 0.0
        var spacing = 0.0, wordSpacing = 0.0, horizontal = 100.0, rise = 0.0
        var textStates: [(String, Double, Double, Double, Double, Double, Double)] = []
        var active = false, supported = true, marked = 0
        var text = "", ranges: [Range<Int>] = [], anchor: PDFMatrix?, blockFont = "", blockSize = 0.0
        var blocks: [SourceTextBlock] = []
        while true {
            lexer.skip(); if lexer.position == lexer.bytes.count { break }
            let start = lexer.position; let value = try lexer.value()
            guard case .keyword(let command) = value else {
                operands.append((value, start..<lexer.position))
                guard operands.count <= 10_000 else { throw PDFEditorError.sourceStructureUnsupported }
                continue
            }
            let values = operands.map(\.0), numbers = values.compactMap(\.number)
            func matrix() -> PDFMatrix? {
                guard numbers.count == 6 else { return nil }
                return PDFMatrix(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], x: numbers[4], y: numbers[5])
            }
            switch command {
            case "BI": throw PDFEditorError.sourceStructureUnsupported // Inline image bytes are not PDF tokens.
            case "q":
                stack.append(state); textStates.append((font, size, rendering, spacing, wordSpacing, horizontal, rise))
            case "Q":
                guard let saved = stack.popLast(), let savedText = textStates.popLast() else { throw PDFEditorError.invalidDocument }
                state = saved
                (font, size, rendering, spacing, wordSpacing, horizontal, rise) = savedText
            case "cm": if let m = matrix() { state.matrix = state.matrix.concatenating(m) } else { throw PDFEditorError.invalidDocument }
            case "W", "W*": state.clipped = true
            case "BDC", "BMC": marked += 1
            case "EMC": marked = max(0, marked - 1)
            case "BT":
                guard !active else { throw PDFEditorError.invalidDocument }
                active = true; supported = !state.clipped && marked == 0
                text = ""; ranges = []; anchor = nil; textMatrix = PDFMatrix()
            case "Tf":
                guard values.count == 2, let name = values[0].name, let number = values[1].number else { throw PDFEditorError.invalidDocument }
                font = name; size = number
            case "Tm": if let m = matrix() { textMatrix = m } else { throw PDFEditorError.invalidDocument }
            case "Td", "TD":
                if numbers.count == 2 { textMatrix = textMatrix.concatenating(PDFMatrix(x: numbers[0], y: numbers[1])) }
                else { supported = false }
            case "T*", "'", "\"": supported = false
            case "Tr": rendering = numbers.first ?? -1
            case "Tc": spacing = numbers.first ?? -1
            case "Tw": wordSpacing = numbers.first ?? -1
            case "Tz": horizontal = numbers.first ?? -1
            case "Ts": rise = numbers.first ?? -1
            case "Tj", "TJ":
                guard active, operands.count == 1 else { throw PDFEditorError.invalidDocument }
                let effective = state.matrix.concatenating(textMatrix)
                guard rendering == 0, spacing == 0, wordSpacing == 0, horizontal == 100, rise == 0,
                      abs(effective.b) < 0.001, abs(effective.c) < 0.001, effective.a > 0,
                      abs(effective.d-effective.a) < 0.001, size > 0, let fontValue = fonts[font],
                      let decoder = try? PDFFontDecoder(document: document, value: fontValue) else {
                    supported = false; operands.removeAll(); continue
                }
                if let first = anchor {
                    if abs(first.y-effective.y) > 0.01 || blockFont != decoder.name || abs(blockSize-size*effective.a) > 0.01 { supported = false }
                } else { anchor = effective; blockFont = decoder.name; blockSize = size*effective.a }
                let strings: [Data]
                if let string = values[0].string { strings = [string] }
                else if let array = values[0].array, array.allSatisfy({ $0.string != nil || $0.number != nil }) { strings = array.compactMap(\.string) }
                else { supported = false; operands.removeAll(); continue }
                do { for string in strings { text += try decoder.decode(string) }; ranges.append(operands[0].1) }
                catch { supported = false }
            case "ET":
                guard active else { throw PDFEditorError.invalidDocument }; active = false
                if supported, let anchor, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   text.count <= 2_000, (3...200).contains(blockSize) {
                    blocks.append(SourceTextBlock(id: lexer.position, pageIndex: index, text: text, fontName: blockFont,
                                                  fontSize: blockSize, baselineX: anchor.x, baselineY: anchor.y,
                                                  snapshot: snapshot, operands: ranges, insertionOffset: lexer.position, transform: state.matrix))
                }
            default:
                if active && !["TL", "rg", "g", "k", "RG", "G", "K"].contains(command) { supported = false }
            }
            operands.removeAll()
        }
        guard !active, stack.isEmpty else { throw PDFEditorError.invalidDocument }
        inspected[index] = blocks
        return blocks
    }

    /// Donor text is generated by CoreText with its font/Unicode resources. It becomes ordinary page content.
    public func replacing(_ block: SourceTextBlock, withTextPDF donorData: Data) throws -> Data {
        guard !consumed, block.snapshot == snapshot, let selected = inspected[block.pageIndex]?.first(where: { $0.id == block.id }),
              selected.text == block.text, selected.operands == block.operands else { throw PDFEditorError.staleSourceSelection }
        let page = pages[block.pageIndex], donor = try PDFObjectDocument(data: donorData)
        guard let donorPage = try donor.pages().first else { throw PDFEditorError.invalidDocument }
        var imported: [PDFReference: PDFReference] = [:]
        func copy(_ value: PDFValue, depth: Int = 0) throws -> PDFValue {
            guard depth < 80 else { throw PDFEditorError.sourceStructureUnsupported }
            switch value {
            case .reference(let ref):
                if let existing = imported[ref] { return .reference(existing) }
                let new = try document.add(.null); imported[ref] = new
                document.objects[new] = try copy(donor.object(ref), depth: depth + 1)
                return .reference(new)
            case .array(let array): return .array(try array.map { try copy($0, depth: depth + 1) })
            case .dictionary(let dictionary): return .dictionary(try dictionary.mapValues { try copy($0, depth: depth + 1) })
            case .stream(let dictionary, let data): return .stream(try dictionary.mapValues { try copy($0, depth: depth + 1) }, data)
            default: return value
            }
        }
        var resources = try document.inherited("Resources", page: page).map { try document.dictionary($0) } ?? [:]
        let donorResources = try donor.inherited("Resources", page: donorPage).map { try donor.dictionary($0) } ?? [:]
        var rename: [String: String] = [:]
        for (category, values) in donorResources {
            if category == "ProcSet" { continue }
            let entries = try donor.dictionary(values)
            var target = try resources[category].map { try document.dictionary($0) } ?? [:]
            for (name, value) in entries {
                let newName = "PE\(document.nextObject)_\(rename.count)"
                rename[name] = newName; target[newName] = try copy(value)
            }
            resources[category] = .dictionary(target)
        }
        let donorContent = try donor.pageContent(donorPage)
        var donorLexer = PDFLexer(donorContent), edits: [(Range<Int>, Data)] = []
        while true {
            donorLexer.skip(); if donorLexer.position == donorLexer.bytes.count { break }
            let start = donorLexer.position, value = try donorLexer.value()
            if let name = value.name, let replacement = rename[name] { edits.append((start..<donorLexer.position, try pdfEncoded(.name(replacement)))) }
        }
        var inserted = donorContent
        for (range, replacement) in edits.reversed() { inserted.replaceSubrange(range, with: replacement) }
        var content = try document.pageContent(page)
        // Restore a page-space CTM around the donor, then restore the surrounding graphics state.
        let injection = Data(("\nq\n" + (try block.transform.inverse()).command + "1 0 0 1 \(pdfNumber(block.baselineX)) \(pdfNumber(block.baselineY)) cm\n").utf8) + inserted + Data("\nQ\n".utf8)
        content.insert(contentsOf: injection, at: block.insertionOffset)
        for range in block.operands.reversed() { content.replaceSubrange(range, with: Data((content[range.lowerBound] == 91 ? "[]" : "()").utf8)) }
        var pageDictionary = try document.dictionary(.reference(page))
        pageDictionary["Resources"] = .dictionary(resources)
        pageDictionary["Contents"] = .reference(try document.add(.stream([:], content)))
        document.objects[page] = .dictionary(pageDictionary)
        consumed = true
        return try document.writtenData()
    }
}
