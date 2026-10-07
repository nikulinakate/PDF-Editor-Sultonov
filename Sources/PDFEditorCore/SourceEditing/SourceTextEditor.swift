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
    public let id: UUID
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
    private var combined: [UUID: SourceTextBlock] = [:]

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
        let media = try document.inherited("MediaBox", page: page).map { try document.resolved($0).array?.compactMap(\.number) } ?? nil
        guard let media, media.count == 4 else { throw PDFEditorError.invalidDocument }
        var pathRectangle: (Double, Double, Double, Double)?
        var pathSegments = 0
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
            case "re":
                if numbers.count == 4, pathSegments == 0, abs(state.matrix.b) < 0.001, abs(state.matrix.c) < 0.001 {
                    let x1 = state.matrix.a * numbers[0] + state.matrix.x, y1 = state.matrix.d * numbers[1] + state.matrix.y
                    let x2 = x1 + state.matrix.a * numbers[2], y2 = y1 + state.matrix.d * numbers[3]
                    pathRectangle = (min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2))
                } else { pathRectangle = nil }
                pathSegments += 1
            case "m", "l", "c", "v", "y", "h": pathSegments += 1; pathRectangle = nil
            case "W", "W*":
                if let rect = pathRectangle, pathSegments == 1,
                   rect.0 <= media[0] + 0.01, rect.1 <= media[1] + 0.01,
                   rect.2 >= media[2] - 0.01, rect.3 >= media[3] - 0.01 {} // Quartz's ordinary page clip.
                else { state.clipped = true }
            case "n", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*": pathSegments = 0; pathRectangle = nil
            case "gs":
                guard let name = values.first?.name, let states = resources["ExtGState"],
                      let entry = try document.dictionary(states)[name] else { throw PDFEditorError.invalidDocument }
                if try document.dictionary(entry)["Font"] != nil { state.clipped = true }
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
                if rendering >= 4 { state.clipped = true }
                let effective = state.matrix.concatenating(textMatrix)
                guard rendering == 0, abs(spacing*effective.a) <= 0.01, abs(wordSpacing*effective.a) <= 0.01, horizontal == 100, abs(rise*effective.a) <= 0.01,
                      abs(effective.b) < 0.001, abs(effective.c) < 0.001, effective.a > 0,
                      abs(effective.d-effective.a) < 0.001, size > 0, let fontValue = fonts[font],
                      let decoder = try? PDFFontDecoder(document: document, value: fontValue) else {
                    supported = false; operands.removeAll(); continue
                }
                if let first = anchor {
                    if abs(first.y-effective.y) > 0.01 || blockFont.split(separator: "+").last != decoder.name.split(separator: "+").last || abs(blockSize-size*effective.a) > 0.01 { supported = false }
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
                    blocks.append(SourceTextBlock(id: UUID(), pageIndex: index, text: text, fontName: blockFont,
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

    /// Join adjacent objects only after the caller verifies they cover one displayed line.
    public func combining(_ members: [SourceTextBlock], text: String) throws -> SourceTextBlock {
        guard !consumed, let first = members.min(by: { $0.baselineX < $1.baselineX }),
              let last = members.max(by: { $0.insertionOffset < $1.insertionOffset }),
              Set(members.map(\.id)).count == members.count else { throw PDFEditorError.staleSourceSelection }
        for member in members {
            guard member.snapshot == snapshot, member.pageIndex == first.pageIndex,
                  inspected[first.pageIndex]?.contains(where: { $0.id == member.id && $0.operands == member.operands }) == true else {
                throw PDFEditorError.staleSourceSelection
            }
        }
        let block = SourceTextBlock(id: UUID(), pageIndex: first.pageIndex, text: text, fontName: first.fontName,
            fontSize: first.fontSize, baselineX: first.baselineX, baselineY: first.baselineY, snapshot: snapshot,
            operands: members.flatMap(\.operands).sorted(by: { $0.lowerBound < $1.lowerBound }),
            insertionOffset: last.insertionOffset, transform: last.transform)
        combined[block.id] = block
        return block
    }

    /// Donor text is generated by CoreText with its font/Unicode resources. It becomes ordinary page content.
    public func replacing(_ block: SourceTextBlock, withTextPDF donorData: Data, donorBaselineX: Double = 0, donorBaselineY: Double = 0) throws -> Data {
        guard !consumed, block.snapshot == snapshot, let selected = combined[block.id] ?? inspected[block.pageIndex]?.first(where: { $0.id == block.id }),
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
                guard rename[name] == nil else { throw PDFEditorError.sourceStructureUnsupported }
                var suffix = rename.count
                var newName = "PE\(document.nextObject)_\(suffix)"
                while target[newName] != nil { suffix += 1; newName = "PE\(document.nextObject)_\(suffix)" }
                rename[name] = newName; target[newName] = try copy(value)
            }
            resources[category] = .dictionary(target)
        }
        let donorMedia = try donor.inherited("MediaBox", page: donorPage).map { try donor.resolved($0).array?.compactMap(\.number) } ?? nil
        guard let donorMedia, donorMedia.count == 4 else { throw PDFEditorError.invalidDocument }
        let donorContent = try donor.pageContent(donorPage)
        var donorLexer = PDFLexer(donorContent), edits: [(Range<Int>, Data)] = []
        var donorOperands: [(PDFValue, Range<Int>)] = [], pageClip: Range<Int>?, clipConfirmed = false
        while true {
            donorLexer.skip(); if donorLexer.position == donorLexer.bytes.count { break }
            let start = donorLexer.position, value = try donorLexer.value()
            if let name = value.name, let replacement = rename[name] { edits.append((start..<donorLexer.position, try pdfEncoded(.name(replacement)))) }
            if case .keyword(let command) = value {
                let numbers = donorOperands.compactMap { $0.0.number }
                if command == "re", numbers.count == 4,
                   abs(numbers[0]-donorMedia[0]) < 0.01, abs(numbers[1]-donorMedia[1]) < 0.01,
                   abs(numbers[2]-(donorMedia[2]-donorMedia[0])) < 0.01,
                   abs(numbers[3]-(donorMedia[3]-donorMedia[1])) < 0.01, let first = donorOperands.first {
                    pageClip = first.1.lowerBound..<donorLexer.position; clipConfirmed = false
                } else if (command == "W" || command == "W*"), pageClip != nil { clipConfirmed = true }
                else if command == "n", let clip = pageClip, clipConfirmed {
                    // The donor page clip would crop descenders after placement on another page.
                    edits.append((clip.lowerBound..<donorLexer.position, Data())); pageClip = nil; clipConfirmed = false
                } else { pageClip = nil; clipConfirmed = false }
                donorOperands.removeAll()
            } else { donorOperands.append((value, start..<donorLexer.position)) }
            guard donorOperands.count < 10_000 else { throw PDFEditorError.sourceStructureUnsupported }
        }
        var inserted = donorContent
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { inserted.replaceSubrange(range, with: replacement) }
        var content = try document.pageContent(page)
        // Restore a page-space CTM around the donor, then restore the surrounding graphics state.
        let injection = Data(("\nq\n" + (try block.transform.inverse()).command + "1 0 0 1 \(pdfNumber(block.baselineX-donorBaselineX)) \(pdfNumber(block.baselineY-donorBaselineY)) cm\n").utf8) + inserted + Data("\nQ\n".utf8)
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
