import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// PDF → Word as editable flowing text: headings, paragraphs, lists, tables and pictures in reading order.
///
/// The structure of each page comes from Apple's document recognition (`RecognizeDocumentsRequest`, macOS 26): it
/// finds paragraphs in reading order (also across two columns), tables with their cells, and lists. Its gaps are filled
/// here: heading levels (from the font size), pictures (it finds none), headers and footers, and the place of tables.
/// The words come from the PDF itself on pages with real text, and from the app's text recognition on scanned pages
/// (without language correction, after its self-check).
enum PDFToWord {
    /// Resolution of the page picture Apple's document recognition reads.
    static let structureDPI: CGFloat = 200
    /// Pictures are cut out of the page at this resolution.
    static let pictureDPI: CGFloat = 300

    /// A word with its place on the page, as fractions of the page with the origin at the top left (y grows downwards).
    /// `size` is the font size in points (real text) or the height of the recognized line in points (scans).
    struct Atom: Equatable {
        var text: String
        var box: CGRect
        var size: CGFloat
        var bold = false
        var italic = false
        /// The highlighter colour on the word (scans).
        var highlight: Highlighter.Color?
        /// The recognized line the word belongs to (scans): its words stay together and in order, even on a slanted or
        /// curved photo where the heights of neighbouring lines overlap.
        var line: Int?
    }

    enum Source: Equatable {
        case text, recognized
    }

    /// One piece of a page, before the decisions that need the whole document (heading levels, lists, page furniture).
    struct Element {
        enum Kind {
            case text
            case table(rows: Int, columns: Int, cells: [WordDocument.Cell])
            case picture(WordDocument.Picture)
        }

        var kind: Kind
        var text = ""
        var box: CGRect
        var page: Int
        var source: Source = .text
        var size: CGFloat = 0
        var bold = false
        var lines = 1
        /// The box of the last line, to see whether the text runs on in the next element.
        var lastLine: CGRect = .null
        var alignment: WordDocument.Alignment = .left
        /// Apple's recognition saw this paragraph as part of a list (it sometimes misses the bullet itself).
        var listHint: Bool?
        /// The words of `text` in order, with bold and italic (real text only), for `emphasis(of:words:)`.
        var words: [Atom] = []

        var isText: Bool { if case .text = kind { return true } else { return false } }
    }

    // MARK: Whole document

    static func convert(_ source: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let document = try await analyze(source, progress: { progress($0 * 0.95) })
        try await document.write(to: destination)
        progress(1)
    }

    static func analyze(_ url: URL, progress: @escaping (Double) -> Void = { _ in }) async throws -> WordDocument {
        guard let pdf = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        guard !pdf.isLocked else { throw AppError.invalidInput(tr("\(url.lastPathComponent) is protected by a password. Remove it first with PDF password.", "\(url.lastPathComponent) ist mit einem Passwort geschützt. Entferne es zuerst mit \u{201E}PDF-Passwort\u{201C}.")) }
        var pages: [[Element]] = []
        var skipped: [Int] = []
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            do {
                pages.append(try await analyze(page: page, index: index))
            } catch is VisionLimit.NoAnswer {
                skipped.append(index + 1)
            }
            progress(Double(index + 1) / Double(max(1, pdf.pageCount)))
        }
        var document = WordDocument(blocks: blocks(from: pages))
        if !skipped.isEmpty {
            guard !pages.allSatisfy(\.isEmpty) else { throw VisionLimit.NoAnswer() }
            // At the very top of the result too: a progress card is soon gone, and a page must not go missing unnoticed.
            let note = VisionLimit.skippedPages(skipped)
            JobNotes.add(note)
            document.blocks.insert(.paragraph(text: "[\(note)]", alignment: .left), at: 0)
        }
        if let first = pdf.page(at: 0) {
            let size = pageSize(first)
            if size.width > 100, size.height > 100 { document.pageSize = size }
        }
        return document
    }

    /// The page as it is shown (turned pages turned).
    static func pageSize(_ page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    // MARK: One page

    static func analyze(page: PDFPage, index: Int) async throws -> [Element] {
        guard let image = PDFRenderer.render(page: page, dpi: structureDPI) else { return [] }
        let size = pageSize(page)
        let hasText = (page.string?.filter { !$0.isWhitespace }.count ?? 0) >= TextRecognizer.existingTextThreshold
        // On scans the structure is read without highlighter colour too, like the words (`TextRecognizer`).
        let structure = try await recognizeStructure(hasText ? image : Highlighter.cleaned(image) ?? image)
        let source: Source = hasText ? .text : .recognized
        var atoms: [Atom]
        if hasText {
            atoms = textAtoms(page)
        } else {
            try await RecognitionCheck.shared.ensureWorking()
            try Task.checkCancellation()
            let scan = PDFRenderer.render(page: page, dpi: TextRecognizer.pageDPI) ?? image
            atoms = recognizedAtoms(try await TextRecognizer.recognize(scan), in: scan, pageHeight: size.height)
        }
        return elements(structure: structure, atoms: atoms, source: source, page: index, pageSize: size, figures: { exclusions in
            let found = figureRects(in: image, pageSize: size, excluding: exclusions, scanned: !hasText)
            guard !found.isEmpty, let sharp = PDFRenderer.render(page: page, dpi: pictureDPI) else { return [] }
            return found.compactMap { rect in picture(from: sharp, rect: rect, pageSize: size).map { (rect, $0) } }
        })
    }

    /// What Apple's document recognition found on a page, in the app's coordinates (origin top left).
    struct Structure {
        struct Paragraph {
            var box: CGRect
            var transcript: String
            var lineBoxes: [CGRect]
            var alignment: WordDocument.Alignment?
        }

        struct Table {
            struct Cell {
                var box: CGRect
                var row: Int, column: Int, rowSpan: Int, columnSpan: Int
                var transcript: String
            }

            var box: CGRect
            var cells: [Cell]
        }

        var paragraphs: [Paragraph] = []
        var tables: [Table] = []
        var lists: [CGRect] = []
    }

    static func recognizeStructure(_ image: CGImage) async throws -> Structure {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = TextRecognizer.usesLanguageCorrection
        request.textRecognitionOptions.recognitionLanguages = TextRecognizer.languages.map { Locale.Language(identifier: $0) }
        request.barcodeDetectionOptions.enabled = false
        let observations: [DocumentObservation]
        let recognition = request
        do {
            observations = try await VisionLimit.call(on: image) { try await recognition.perform(on: image) }
        } catch where Task.isCancelled {
            throw CancellationError()
        }
        var structure = Structure()
        for observation in observations {
            let document = observation.document
            for paragraph in document.paragraphs {
                let alignment: WordDocument.Alignment? = switch paragraph.textAlignment {
                case .center: .center
                case .trailing: .right
                case .leading: .left
                default: nil
                }
                structure.paragraphs.append(.init(box: topLeft(paragraph.boundingRegion.boundingBox.cgRect), transcript: paragraph.transcript,
                                                  lineBoxes: paragraph.lines.map { topLeft($0.boundingBox.cgRect) }, alignment: alignment))
            }
            for table in document.tables {
                let cells = table.rows.flatMap { $0 }.map { cell in
                    Structure.Table.Cell(box: topLeft(cell.content.boundingRegion.boundingBox.cgRect), row: cell.rowRange.lowerBound,
                                         column: cell.columnRange.lowerBound, rowSpan: cell.rowRange.count, columnSpan: cell.columnRange.count,
                                         transcript: cell.content.text.transcript)
                }
                structure.tables.append(.init(box: topLeft(table.boundingRegion.boundingBox.cgRect), cells: cells))
            }
            structure.lists += document.lists.map { topLeft($0.boundingRegion.boundingBox.cgRect) }
        }
        return structure
    }

    /// Vision's boxes have the origin at the bottom left.
    static func topLeft(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The words of a page with real text, with font size and weight. The place of each word comes from a selection of
    /// it: `characterBounds(at:)` gives the box of the character before after every line break.
    static func textAtoms(_ page: PDFPage) -> [Atom] {
        guard let string = page.string as NSString?, string.length > 0 else { return [] }
        let attributed = page.attributedString
        let transform = page.transform(for: .mediaBox)
        let shown = pageSize(page)
        guard shown.width > 0, shown.height > 0 else { return [] }
        var atoms: [Atom] = []
        let whitespace = CharacterSet.whitespacesAndNewlines
        var index = 0
        while index < string.length {
            let rest = NSRange(location: index, length: string.length - index)
            let start = string.rangeOfCharacter(from: whitespace.inverted, options: [], range: rest)
            guard start.location != NSNotFound else { break }
            let after = NSRange(location: start.location, length: string.length - start.location)
            let end = string.rangeOfCharacter(from: whitespace, options: [], range: after)
            let wordRange = NSRange(location: start.location, length: (end.location == NSNotFound ? string.length : end.location) - start.location)
            index = wordRange.location + wordRange.length
            guard let selection = page.selection(for: wordRange) else { continue }
            // Into the page as shown: the box's origin at 0, a turned page turned.
            let rect = selection.bounds(for: page).applying(transform).standardized
            guard !rect.isEmpty, rect.width.isFinite else { continue }
            var sizes: [CGFloat] = [], bold = 0, italic = 0
            if let attributed, wordRange.location + wordRange.length <= attributed.length {
                for i in wordRange.location..<(wordRange.location + wordRange.length) {
                    guard let font = attributed.attribute(.font, at: i, effectiveRange: nil) as? NSFont else { continue }
                    sizes.append(font.pointSize)
                    let name = font.fontName.lowercased()
                    let traits = font.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) || ["bold", "black", "heavy", "semibold"].contains(where: { name.contains($0) }) { bold += 1 }
                    if traits.contains(.italic) || ["italic", "oblique"].contains(where: { name.contains($0) }) { italic += 1 }
                }
            }
            let normalized = CGRect(x: rect.minX / shown.width, y: 1 - rect.maxY / shown.height, width: rect.width / shown.width, height: rect.height / shown.height)
            atoms.append(Atom(text: string.substring(with: wordRange), box: normalized, size: sizes.isEmpty ? rect.height * 0.8 : median(sizes),
                              bold: bold * 2 > sizes.count && !sizes.isEmpty, italic: italic * 2 > sizes.count && !sizes.isEmpty))
        }
        return atoms
    }

    /// The recognized words of a scanned page. Their size is measured in the picture: from the baseline to the top of
    /// the capitals and tall letters, as a font size. The height of Vision's line boxes was far too uneven for that
    /// (body text 10.5 to 17.5 pt in one letter), the height of the lower-case letters too.
    static func recognizedAtoms(_ lines: [TextRecognizer.Line], in image: CGImage, pageHeight: CGFloat) -> [Atom] {
        lines.enumerated().flatMap { number, line -> [Atom] in
            let words = line.words.isEmpty ? [TextRecognizer.Line.Word(text: line.text, box: line.box)] : line.words
            // A word without capitals or tall letters ("zum") measures too small: the line takes its upper quarter.
            let heights = words.compactMap { ascent(of: $0.box, in: image) }.sorted()
            let size = heights.isEmpty ? line.box.height * pageHeight * 0.7
                : heights[min(heights.count - 1, heights.count * 3 / 4)] / CGFloat(image.height) * pageHeight / 0.72
            return words.map { Atom(text: $0.text, box: topLeft($0.box), size: size, highlight: $0.highlight, line: number) }
        }
    }

    /// Pixels from the baseline (the lowest row with much ink) up to the top of the letters, from a row profile of the box.
    static func ascent(of box: CGRect, in image: CGImage) -> CGFloat? {
        let pixels = CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                            width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
            .insetBy(dx: 0, dy: -box.height * CGFloat(image.height) * 0.1).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 4, pixels.height >= 6, let part = image.cropping(to: pixels) else { return nil }
        let width = part.width, height = part.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        let gray = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height), count: width * height)
        let background = Int(gray.max() ?? 255)
        // Rows from the top: the bitmap's first row is the picture's top row.
        var rows = [Int](repeating: 0, count: height)
        for y in 0..<height { for x in 0..<width where Int(gray[y * width + x]) < background - 90 { rows[y] += 1 } }
        guard let peak = rows.max(), peak >= 2, let baseline = rows.lastIndex(where: { $0 * 100 >= peak * 35 }) else { return nil }
        // Up from the baseline while there is ink: dots above a capital ("Ö") are apart from the letter and do not count.
        var top = baseline
        while top > 0, rows[top - 1] > 1 { top -= 1 }
        return baseline > top ? CGFloat(baseline - top + 1) : nil
    }

    // MARK: Putting a page together

    static func elements(structure: Structure, atoms: [Atom], source: Source, page: Int, pageSize: CGSize,
                         figures: ([CGRect]) -> [(CGRect, WordDocument.Picture)] = { _ in [] }) -> [Element] {
        // Table cells also come as paragraphs, and in the wrong place: the table takes them.
        let paragraphs = structure.paragraphs.filter { paragraph in
            !structure.tables.contains { $0.box.insetBy(dx: -0.005, dy: -0.005).contains(CGPoint(x: paragraph.box.midX, y: paragraph.box.midY)) }
        }
        // Each word goes to the table cell or paragraph it sits in; the rest is placed below.
        var cellAtoms = structure.tables.map { $0.cells.map { _ in [Atom]() } }
        var paragraphAtoms = paragraphs.map { _ in [Atom]() }
        var rest: [Atom] = []
        var outsideTables: [Atom] = []
        atomLoop: for atom in atoms {
            let center = CGPoint(x: atom.box.midX, y: atom.box.midY)
            for (t, table) in structure.tables.enumerated() where table.box.insetBy(dx: -0.005, dy: -0.005).contains(center) {
                if let c = table.cells.indices.min(by: { distance(center, table.cells[$0].box) < distance(center, table.cells[$1].box) }) {
                    cellAtoms[t][c].append(atom)
                    continue atomLoop
                }
            }
            outsideTables.append(atom)
        }
        // A recognized line goes to the paragraph it overlaps most, as a whole; a word of real text to the one it sits in.
        for group in groupedByLine(outsideTables) {
            let box = group.reduce(CGRect.null) { $0.union($1.box) }
            if group.first?.line != nil {
                let best = paragraphs.indices.max { inside(box, paragraphs[$0].box) < inside(box, paragraphs[$1].box) }
                if let best, inside(box, paragraphs[best].box.insetBy(dx: -box.height * 0.3, dy: -box.height * 0.3)) >= 0.3 {
                    paragraphAtoms[best] += group
                } else {
                    rest += group
                }
                continue
            }
            for atom in group {
                let center = CGPoint(x: atom.box.midX, y: atom.box.midY)
                let tolerance = atom.box.height * 0.4
                let containing = paragraphs.indices.filter { paragraphs[$0].box.insetBy(dx: -tolerance, dy: -tolerance).contains(center) }
                if let p = containing.min(by: { paragraphs[$0].box.width * paragraphs[$0].box.height < paragraphs[$1].box.width * paragraphs[$1].box.height }) {
                    paragraphAtoms[p].append(atom)
                } else {
                    rest.append(atom)
                }
            }
        }
        // A word beside a paragraph on the same line (a bullet left of its text) belongs to it.
        var loose: [Atom] = []
        for atom in rest {
            let near = paragraphs.indices.first { p in
                paragraphs[p].lineBoxes.contains { line in
                    verticalOverlap(line, atom.box) > 0.5 && (line.minX - atom.box.maxX < atom.box.height * 4 && atom.box.minX - line.maxX < atom.box.height * 4)
                }
            }
            if let near { paragraphAtoms[near].append(atom) } else { loose.append(atom) }
        }

        let looseLines = groupLines(loose)
        var ordered: [Element] = []
        for (p, paragraph) in paragraphs.enumerated() {
            // A paragraph none of whose words arrived here, whose text is a loose line nearby: the line is placed below,
            // the paragraph would repeat it.
            if paragraphAtoms[p].isEmpty, source == .recognized, looseLines.contains(where: { line in
                let box = line.reduce(CGRect.null) { $0.union($1.box) }
                return box.intersects(paragraph.box.insetBy(dx: -0.02, dy: -0.02)) && RecognitionCheck.similarity(join([line]), paragraph.transcript) >= 0.6
            }) { continue }
            var element = textElement(atoms: paragraphAtoms[p], fallback: paragraph, source: source, page: page, pageHeight: pageSize.height)
            element.listHint = structure.lists.contains { $0.insetBy(dx: -0.01, dy: -0.005).contains(CGPoint(x: paragraph.box.midX, y: paragraph.box.midY)) }
            if !element.text.isEmpty { ordered.append(element) }
        }
        var extras: [Element] = []
        for line in looseLines {
            let text = join([line])
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            let box = line.reduce(CGRect.null) { $0.union($1.box) }
            extras.append(Element(kind: .text, text: text, box: box, page: page, source: source, size: median(line.map(\.size)),
                                  bold: line.filter(\.bold).count * 2 > line.count, lastLine: box, words: line))
        }
        for (t, table) in structure.tables.enumerated() {
            guard let element = tableElement(table, atoms: cellAtoms[t], page: page, source: source) else { continue }
            extras.append(element)
        }
        let exclusions = atoms.map(\.box) + structure.paragraphs.map(\.box) + structure.tables.map(\.box)
        for (rect, picture) in figures(exclusions) {
            // Running text is never part of a picture: then it is a photographed page with uneven light, not a picture.
            guard !ordered.contains(where: { inside($0.box, rect) > 0.8 && ($0.lines >= 2 || $0.text.count >= 60) }) else { continue }
            // Labels inside a picture stay in the picture.
            ordered.removeAll { inside($0.box, rect) > 0.8 }
            extras.append(Element(kind: .picture(picture), box: rect, page: page))
        }
        for extra in extras.sorted(by: { $0.box.minY < $1.box.minY }) { insert(extra, into: &ordered) }
        alignShortLines(&ordered)
        return joiningWrappedLines(joiningStackedLines(swappingReversedNeighbours(ordered)))
    }

    /// Two paragraphs right below each other in the wrong order (it happens with Apple's recognition) are swapped.
    static func swappingReversedNeighbours(_ elements: [Element]) -> [Element] {
        var result = elements
        for index in result.indices.dropLast() {
            let a = result[index], b = result[index + 1]
            if a.isText, b.isText, horizontalOverlap(a.box, b.box) > min(a.box.width, b.box.width) * 0.5, b.box.maxY <= a.box.minY + 0.002 {
                result.swapAt(index, index + 1)
            }
        }
        return result
    }

    /// A paragraph Apple's recognition cut in two: the first part's last line runs to the right edge of the text without
    /// ending a sentence, and the next line follows at the normal line distance with the same left edge.
    static func joiningWrappedLines(_ elements: [Element]) -> [Element] {
        let text = elements.filter { $0.isText && $0.lines >= 2 }
        let pitch = median(text.map { $0.box.height / CGFloat($0.lines) })
        guard pitch > 0, let left = elements.filter(\.isText).map(\.box.minX).min(), let right = text.map(\.box.maxX).max() else { return elements }
        var result: [Element] = []
        for element in elements {
            if let last = result.last, last.isText, element.isText, !last.lastLine.isNull, !last.text.contains("\n"), !element.text.contains("\n"),
               last.lastLine.maxX >= right - (right - left) * 0.12, abs(last.box.minX - element.box.minX) < 0.012,
               abs(element.size - last.size) <= max(last.size, 0.0001) * 0.1, element.box.minY - last.lastLine.minY < pitch * 1.3,
               element.box.minY > last.lastLine.minY, listMarker(element.text) == nil,
               !(last.text.last.map { ".!?:".contains($0) } ?? false) || element.text.first?.isLowercase == true {
                result[result.count - 1].text = join([[Atom(text: last.text, box: .zero, size: 0)], [Atom(text: element.text, box: .zero, size: 0)]])
                result[result.count - 1].lines += element.lines
                result[result.count - 1].box = last.box.union(element.box)
                result[result.count - 1].lastLine = element.lastLine
                result[result.count - 1].words += element.words
            } else {
                result.append(element)
            }
        }
        return result
    }

    /// Single lines stacked at the page's normal line distance, with the same left edge and size (an address block),
    /// are one paragraph with line breaks; Apple's recognition makes each line a paragraph of its own. The line distance
    /// is that inside the page's paragraphs of several lines; a gap between paragraphs is larger.
    static func joiningStackedLines(_ elements: [Element]) -> [Element] {
        let pitch = median(elements.filter { $0.isText && $0.lines >= 2 }.map { $0.box.height / CGFloat($0.lines) })
        guard pitch > 0 else { return elements }
        var result: [Element] = []
        var lastLineTop: CGFloat = 0
        for element in elements {
            if let last = result.last, last.isText, element.isText, element.lines == 1, last.alignment == element.alignment,
               abs(last.box.minX - element.box.minX) < 0.012, last.size > 0, abs(element.size - last.size) <= last.size * 0.1,
               listMarker(last.text) == nil, listMarker(element.text) == nil, last.listHint != true, element.listHint != true,
               last.text.split(separator: "\n").count == last.lines, element.box.minY - lastLineTop < pitch * 1.2,
               last.text.split(separator: "\n").allSatisfy({ $0.count <= 60 }), element.text.count <= 60 {
                result[result.count - 1].text += "\n" + element.text
                result[result.count - 1].lines += 1
                result[result.count - 1].box = last.box.union(element.box)
                result[result.count - 1].lastLine = element.lastLine
                result[result.count - 1].words += element.words
            } else {
                result.append(element)
            }
            lastLineTop = element.box.minY
        }
        return result
    }

    private static func textElement(atoms: [Atom], fallback: Structure.Paragraph, source: Source, page: Int, pageHeight: CGFloat) -> Element {
        var element = Element(kind: .text, box: fallback.box, page: page, source: source)
        element.alignment = fallback.alignment ?? .left
        if atoms.isEmpty {
            // Text Apple's recognition read that is not in the PDF's text (e.g. a picture of text on a page with real text).
            element.text = fallback.transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            element.source = .recognized
            element.size = median(fallback.lineBoxes.map { $0.height * pageHeight }) * 0.7
            element.lines = max(1, fallback.lineBoxes.count)
            element.lastLine = fallback.lineBoxes.last ?? fallback.box
        } else {
            let lines = groupLines(atoms)
            element.text = join(lines)
            element.words = lines.flatMap { $0 }
            element.size = median(atoms.map(\.size))
            element.bold = atoms.filter(\.bold).count * 2 > atoms.count
            element.lines = lines.count
            element.box = atoms.reduce(fallback.box) { $0.union($1.box) }
            element.lastLine = lines.last.map { $0.reduce(CGRect.null) { $0.union($1.box) } } ?? element.box
        }
        return element
    }

    private static func tableElement(_ table: Structure.Table, atoms: [[Atom]], page: Int, source: Source) -> Element? {
        guard !table.cells.isEmpty else { return nil }
        let cells = table.cells.enumerated().map { index, cell in
            let cellAtoms = atoms[index]
            let text = cellAtoms.isEmpty ? cell.transcript.split(whereSeparator: \.isWhitespace).joined(separator: " ") : join(groupLines(cellAtoms))
            return WordDocument.Cell(text: text, row: cell.row, column: cell.column, rowSpan: max(1, cell.rowSpan), columnSpan: max(1, cell.columnSpan),
                                     bold: !cellAtoms.isEmpty && cellAtoms.filter(\.bold).count * 2 > cellAtoms.count)
        }
        let rows = cells.map { $0.row + $0.rowSpan }.max() ?? 1, columns = cells.map { $0.column + $0.columnSpan }.max() ?? 1
        return Element(kind: .table(rows: rows, columns: columns, cells: cells), box: table.box, page: page, source: source)
    }

    /// Puts a table, picture or loose line in reading order: before the first element below it in the same column,
    /// otherwise after the last element above it in that column (the end of a column), otherwise at the end.
    static func insert(_ extra: Element, into ordered: inout [Element]) {
        let column = ordered.indices.filter { horizontalOverlap(ordered[$0].box, extra.box) > 0 }
        if let below = column.first(where: { ordered[$0].box.minY >= extra.box.minY - 0.002 }) {
            ordered.insert(extra, at: below)
        } else if let above = column.last {
            ordered.insert(extra, at: above + 1)
        } else {
            ordered.append(extra)
        }
    }

    /// Single lines Apple gives no alignment: right-aligned (a date in a letter) or centered, judged against the page's text.
    private static func alignShortLines(_ elements: inout [Element]) {
        let text = elements.filter { $0.isText && $0.lines > 1 }
        guard let left = text.map(\.box.minX).min(), let right = text.map(\.box.maxX).max(), right - left > 0.3 else { return }
        let middle = (left + right) / 2
        for index in elements.indices where elements[index].isText && elements[index].lines == 1 && elements[index].alignment == .left {
            let box = elements[index].box
            // Short: a full line in the right one of two columns also ends at the right edge, but is not right-aligned.
            if box.maxX > right - 0.02, box.minX > middle, box.width < (right - left) * 0.4 {
                elements[index].alignment = .right
            } else if abs(box.midX - middle) < 0.015, box.minX > left + 0.08 {
                elements[index].alignment = .center
            }
        }
    }

    /// Words by recognized line (in their order), each word of real text on its own.
    static func groupedByLine(_ atoms: [Atom]) -> [[Atom]] {
        var groups: [[Atom]] = []
        var index: [Int: Int] = [:]
        for atom in atoms {
            if let line = atom.line, let at = index[line] {
                groups[at].append(atom)
            } else {
                if let line = atom.line { index[line] = groups.count }
                groups.append([atom])
            }
        }
        return groups
    }

    /// Words in lines, top to bottom, each line left to right. Recognized lines stay as they were read.
    static func groupLines(_ atoms: [Atom]) -> [[Atom]] {
        guard !atoms.isEmpty else { return [] }
        if atoms.allSatisfy({ $0.line != nil }) {
            return groupedByLine(atoms).sorted { ($0.map(\.box.minY).min() ?? 0) < ($1.map(\.box.minY).min() ?? 0) }
        }
        let height = median(atoms.map(\.box.height))
        var lines: [[Atom]] = []
        for atom in atoms.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = lines.last, let lastMid = last.map(\.box.midY).max(), abs(atom.box.midY - lastMid) <= height * 0.5 {
                lines[lines.count - 1].append(atom)
            } else {
                lines.append([atom])
            }
        }
        return lines.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    /// Lines joined into one paragraph; a word broken at the line end ("Rück-" "gabe") is put back together.
    static func join(_ lines: [[Atom]]) -> String {
        var text = ""
        for line in lines {
            let part = line.map(\.text).joined(separator: " ")
            if text.isEmpty {
                text = part
            } else if (text.hasSuffix("-") || text.hasSuffix("\u{00AD}")), let first = part.first, first.isLowercase,
                      let before = text.dropLast().last, before.isLetter {
                text = String(text.dropLast()) + part
            } else if text.hasSuffix("-") || text.hasSuffix("/") {
                text += part
            } else {
                text += " " + part
            }
        }
        return text
    }

    // MARK: Pictures

    /// Places on the page with dense non-text ink (photos, drawings, charts), as page fractions with the origin at the top
    /// left. Text, tables and thin lines are left out; anything touching the page edge (scanner shadows) too. On a scanned
    /// page the edge is that of the scan: a photo placed on a page with a white margin has its table edge or shadow there.
    static func figureRects(in image: CGImage, pageSize: CGSize, excluding: [CGRect], scanned: Bool = false) -> [CGRect] {
        let cell: CGFloat = 3
        let width = SafeNumber.int(pageSize.width / cell, in: 8...4_000), height = SafeNumber.int(pageSize.height / cell, in: 8...4_000)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        // Rows from the top: the bitmap's first row is the picture's top row.
        func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        var white = [Bool](repeating: false, count: width * height)
        for y in 0..<height { for x in 0..<width { let c = color(x, y); white[y * width + x] = min(c.0, c.1, c.2) >= 254 } }
        let area = scanned ? photoFrame(white: white, width: width, height: height) : (minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)
        var counts: [Int: Int] = [:]
        for y in area.minY...area.maxY {
            for x in area.minX...area.maxX {
                let c = color(x, y)
                counts[(c.0 >> 4) << 8 | (c.1 >> 4) << 4 | c.2 >> 4, default: 0] += 1
            }
        }
        guard let paper = counts.max(by: { $0.value < $1.value })?.key else { return [] }
        let background = ((paper >> 8 & 15) * 16 + 8, (paper >> 4 & 15) * 16 + 8, (paper & 15) * 16 + 8)
        var ink = [Bool](repeating: false, count: width * height)
        let blocked = excluding.map { CGRect(x: $0.minX * CGFloat(width) - 1, y: $0.minY * CGFloat(height) - 1,
                                             width: $0.width * CGFloat(width) + 2, height: $0.height * CGFloat(height) + 2) }
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                guard max(abs(c.0 - background.0), abs(c.1 - background.1), abs(c.2 - background.2)) > 18 else { continue }
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if !blocked.contains(where: { $0.contains(point) }) { ink[y * width + x] = true }
            }
        }
        // Neighbours up to two cells apart belong together, so a picture with light areas stays one picture.
        var seen = [Bool](repeating: false, count: width * height)
        var found: [CGRect] = []
        for start in ink.indices where ink[start] && !seen[start] {
            var stack = [start], minX = width, maxX = 0, minY = height, maxY = 0, count = 0
            seen[start] = true
            while let current = stack.popLast() {
                let x = current % width, y = current / width
                count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let next = ny * width + nx
                        if ink[next] && !seen[next] { seen[next] = true; stack.append(next) }
                    }
                }
            }
            let w = maxX - minX + 1, h = maxY - minY + 1
            guard CGFloat(w) * cell >= 36, CGFloat(h) * cell >= 30, Double(count) / Double(w * h) >= 0.25,
                  minX > area.minX + 1, minY > area.minY + 1, maxX < area.maxX - 1, maxY < area.maxY - 1 else { continue }
            found.append(CGRect(x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
                                width: CGFloat(w) / CGFloat(width), height: CGFloat(h) / CGFloat(height)))
        }
        return mergingTouching(found, gap: 10 / pageSize.height)
    }

    /// Where a photo placed on a page with a white margin begins and ends (in cells), or the whole page. A side counts
    /// only at a sharp edge: white margin, then at least 15 pt of rows (columns) that are nearly all filled. Paper
    /// scanned as pure white has no such edge, text lines have white gaps between them.
    static func photoFrame(white: [Bool], width: Int, height: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let run = 5
        func filled(row y: Int) -> Bool { (0..<width).filter { !white[y * width + $0] }.count * 100 >= width * 85 }
        func filled(column x: Int) -> Bool { (0..<height).filter { !white[$0 * width + x] }.count * 100 >= height * 85 }
        func edge(_ indices: [Int], filled: (Int) -> Bool) -> Int {
            guard let first = indices.firstIndex(where: filled), first > 0, first + run <= indices.count,
                  indices[first..<(first + run)].allSatisfy(filled) else { return indices[0] }
            return indices[first]
        }
        let rows = Array(0..<height), columns = Array(0..<width)
        let frame = (minX: edge(columns, filled: { filled(column: $0) }), minY: edge(rows, filled: { filled(row: $0) }),
                     maxX: edge(columns.reversed(), filled: { filled(column: $0) }), maxY: edge(rows.reversed(), filled: { filled(row: $0) }))
        return frame.minX < frame.maxX && frame.minY < frame.maxY ? frame : (minX: 0, minY: 0, maxX: width - 1, maxY: height - 1)
    }

    /// Parts of one picture that came apart at a light stretch (a pale sky) are put back together.
    static func mergingTouching(_ rects: [CGRect], gap: CGFloat) -> [CGRect] {
        var result = rects
        var merged = true
        while merged {
            merged = false
            outer: for i in result.indices {
                for j in result.indices where j > i {
                    let a = result[i], b = result[j]
                    let shareColumns = horizontalOverlap(a, b) > min(a.width, b.width) * 0.5
                    let close = max(a.minY, b.minY) - min(a.maxY, b.maxY) <= gap
                    if (shareColumns && close) || a.intersects(b) {
                        result[i] = a.union(b)
                        result.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return result
    }

    /// The part of the page as a JPEG, with its size on the page in points.
    static func picture(from page: CGImage, rect: CGRect, pageSize: CGSize) -> WordDocument.Picture? {
        let pixels = CGRect(x: rect.minX * CGFloat(page.width), y: rect.minY * CGFloat(page.height),
                            width: rect.width * CGFloat(page.width), height: rect.height * CGFloat(page.height)).integral
        guard let part = page.cropping(to: pixels) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, part, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return WordDocument.Picture(data: data as Data, isJPEG: true, size: CGSize(width: rect.width * pageSize.width, height: rect.height * pageSize.height))
    }

    // MARK: Whole document: headings, lists, headers and footers

    static func blocks(from pages: [[Element]]) -> [WordDocument.Block] {
        var pages = removingPageFurniture(pages)
        mergeAcrossPages(&pages)
        let placements = pages.flatMap(columnLayout)
        let elements = pages.flatMap { $0 }
        var bodySize: [Source: CGFloat] = [:]
        for source in [Source.text, .recognized] {
            let sizes = elements.filter { $0.isText && $0.source == source }.flatMap { element in
                [CGFloat](repeating: element.size, count: max(1, element.text.count / 10))
            }
            bodySize[source] = sizes.isEmpty ? 0 : median(sizes)
        }

        let levels = headingLevels(elements, bodySize: bodySize)
        var textRight: [Int: CGFloat] = [:]
        for element in elements where element.isText && element.lines >= 2 { textRight[element.page] = max(textRight[element.page] ?? 0, element.box.maxX) }
        var blocks: [WordDocument.Block] = []
        var list: (ordered: Bool, items: [(text: String, words: [Atom])])?
        func closeList() {
            if let current = list {
                blocks.append(.list(ordered: current.ordered, items: current.items.map(\.text),
                                    emphasis: current.items.map { emphasis(of: $0.text, words: $0.words) }))
            }
            list = nil
        }
        var columns = 1
        for (index, element) in elements.enumerated() {
            if placements[index].columns != columns {
                closeList()
                columns = placements[index].columns
                blocks.append(.columns(columns))
            } else if columns > 1, placements[index].startsColumn || elements[index - 1].page != element.page {
                // The right column, or the next page's left column: Word would otherwise fill each column to the bottom.
                closeList()
                blocks.append(.columnBreak)
            }
            switch element.kind {
            case .table(let rows, let columns, let cells):
                closeList()
                blocks.append(.table(rows: rows, columns: columns, cells: cells))
            case .picture(let picture):
                closeList()
                blocks.append(.picture(picture))
            case .text:
                if let level = levels[index] {
                    closeList()
                    // Headings have their weight from the style; only the highlighter is added.
                    let marks = emphasis(of: element.text, words: element.words).filter { $0.highlight != nil }.map {
                        WordDocument.Emphasis(range: $0.range, highlight: $0.highlight)
                    }
                    blocks.append(.heading(level: level, text: element.text, emphasis: marks))
                    continue
                }
                // A line of a list item that Apple's recognition split off: no marker, and the line before it runs to the
                // right edge of the text (a short line before it means a new item whose marker got lost).
                if list != nil, element.listHint == true, listMarker(element.text) == nil, index > 0, elements[index - 1].isText,
                   let right = textRight[element.page], let left = elements.filter({ $0.page == element.page && $0.isText }).map(\.box.minX).min(),
                   elements[index - 1].box.maxX >= right - (right - left) * 0.12 {
                    let count = list!.items.count, item = list!.items[count - 1]
                    list!.items[count - 1] = (join([[Atom(text: item.text, box: .zero, size: 0)], [Atom(text: element.text, box: .zero, size: 0)]]),
                                              item.words + element.words)
                    continue
                }
                if let item = listItem(element, previous: index > 0 ? elements[index - 1] : nil, next: index + 1 < elements.count ? elements[index + 1] : nil,
                                       continuing: list?.ordered) {
                    if let current = list, current.ordered == item.ordered {
                        list?.items.append((item.text, element.words))
                    } else {
                        closeList()
                        list = (item.ordered, [(item.text, element.words)])
                    }
                    continue
                }
                closeList()
                blocks.append(.paragraph(text: element.text, alignment: element.alignment, emphasis: emphasis(of: element.text, words: element.words)))
            }
        }
        closeList()
        return blocks
    }

    /// Which elements of a page run in two columns (2) and which across the page (1). Two only when the page is set in two
    /// columns throughout, below at most a title across the whole width: every element after the title lies in one half,
    /// the left column is read before the right one, and both hold running text. Otherwise the whole page is one column.
    static func columnLayout(_ page: [Element]) -> [(columns: Int, startsColumn: Bool)] {
        let single = [(columns: Int, startsColumn: Bool)](repeating: (1, false), count: page.count)
        let text = page.filter(\.isText)
        guard let left = text.map(\.box.minX).min(), let right = text.map(\.box.maxX).max(), right - left > 0.3 else { return single }
        let middle = (left + right) / 2
        enum Side { case left, right, across }
        let sides = page.map { element -> Side in
            element.box.maxX <= middle + 0.005 ? .left : (element.box.minX >= middle - 0.005 ? .right : .across)
        }
        guard let start = sides.firstIndex(where: { $0 != .across }), sides[start] == .left else { return single }
        let body = sides[start...]
        guard !body.contains(.across), let firstRight = body.firstIndex(of: .right), !body[firstRight...].contains(.left) else { return single }
        func characters(_ side: Side) -> Int { zip(page, sides).filter { $0.1 == side && $0.0.isText }.map { $0.0.text.count }.reduce(0, +) }
        let all = text.map(\.text.count).reduce(0, +)
        guard characters(.left) >= 150, characters(.right) >= 150, (characters(.left) + characters(.right)) * 10 >= all * 6 else { return single }
        return page.indices.map { ($0 < start ? 1 : 2, $0 == firstRight) }
    }

    /// How much larger than the body text an element is, if it looks like a heading: short, not a sentence, and larger
    /// (or bold on a page with real text). Measured against the body text of the same kind (font size for real text,
    /// baseline-to-top height for scans).
    static func headingRatio(_ element: Element, body: CGFloat) -> CGFloat? {
        let text = element.text
        guard element.isText, body > 0, element.lines <= 3, text.count <= 150, text.contains(where: \.isLetter), !text.hasSuffix(",") else { return nil }
        let ratio = element.size / body
        // "Allgemeiner Teil:" is a heading; a line ending like a sentence is not.
        let endsLikeSentence = text.last.map { ".!?;,".contains($0) } ?? false
        if ratio >= 1.2 { return ratio }
        guard element.lines == 1, !endsLikeSentence, listMarker(text)?.ordered != false else { return nil }
        // "2. Kapitel und ..." in a larger font is a numbered heading, at body size a list item.
        if ratio >= 1.1 { return ratio }
        if element.bold, ratio >= 0.95, element.source == .text, text.split(separator: " ").count <= 12, listMarker(text) == nil { return ratio }
        return nil
    }

    /// Heading levels by size groups: the largest headings of the document are level 1, the next size level 2, all
    /// smaller ones level 3. Sizes less than 20 % apart are one group (scans measure a heading a little differently
    /// each time, measured 1.32 to 1.68 times the body text for one size).
    static func headingLevels(_ elements: [Element], bodySize: [Source: CGFloat]) -> [Int?] {
        let ratios = elements.map { headingRatio($0, body: bodySize[$0.source] ?? 0) }
        var groups: [CGFloat] = []
        for ratio in ratios.compactMap({ $0 }).sorted(by: >) {
            if let smallest = groups.last, ratio * 1.2 > smallest { groups[groups.count - 1] = ratio } else { groups.append(ratio) }
        }
        return ratios.map { ratio in
            guard let ratio else { return nil }
            return min(3, (groups.firstIndex { ratio >= $0 } ?? groups.count - 1) + 1)
        }
    }

    /// Bold, italic and highlighted stretches of `text`, from the words it was made of (they carry the PDF's font and the
    /// highlighter colour). The words are matched to the text word by word; joined parts of a broken word ("Rück-" "gabe")
    /// match "Rückgabe", a list marker the text lost is skipped. Where they stop matching, the rest stays plain: no emphasis
    /// is better than a wrong one. A broken word with one part highlighted is highlighted as a whole.
    static func emphasis(of text: String, words: [Atom]) -> [WordDocument.Emphasis] {
        guard words.contains(where: { $0.bold || $0.italic || $0.highlight != nil }) else { return [] }
        func key(_ part: String) -> String { part.filter { $0 != "-" && $0 != "\u{00AD}" } }
        let characters = Array(text)
        var result: [WordDocument.Emphasis] = []
        var next = 0, index = 0
        while index < characters.count {
            guard !characters[index].isWhitespace else { index += 1; continue }
            var end = index
            while end < characters.count, !characters[end].isWhitespace { end += 1 }
            let token = key(String(characters[index..<end]))
            if result.isEmpty, index == characters.indices.first(where: { !characters[$0].isWhitespace }), next == 0, words.count > 1,
               !token.hasPrefix(key(words[0].text)), listMarker(words[0].text + " x") != nil {
                next = 1
            }
            var built = "", used: [Atom] = []
            while next < words.count, built.count < token.count {
                built += key(words[next].text)
                used.append(words[next])
                next += 1
            }
            guard built == token, !used.isEmpty else { break }
            let bold = used.allSatisfy(\.bold), italic = used.allSatisfy(\.italic), highlight = used.compactMap(\.highlight).first
            if bold || italic || highlight != nil {
                // Next to the stretch before it with the same look, only spaces between: one stretch.
                if let last = result.last, last.bold == bold, last.italic == italic, last.highlight == highlight,
                   characters[last.range.upperBound..<index].allSatisfy(\.isWhitespace) {
                    result[result.count - 1].range = last.range.lowerBound..<end
                } else {
                    result.append(WordDocument.Emphasis(range: index..<end, bold: bold, italic: italic, highlight: highlight))
                }
            }
            index = end
        }
        return result
    }

    /// The marker at the start of a list item and whether the list is numbered.
    static func listMarker(_ text: String) -> (ordered: Bool, length: Int)? {
        let bullets: Set<Character> = ["•", "·", "▪", "◦", "‣", "●", "○", "■", "□", "-", "–", "—", "*", "\u{F0B7}", "➢", "✓"]
        if let first = text.first, bullets.contains(first) {
            let spaces = text.dropFirst().prefix(while: { $0 == " " || $0 == "\t" }).count
            // "•Text" without a space is still an item; "-Text" or "*Text" are not.
            guard spaces > 0 || first == "•" || first == "●" else { return nil }
            return (false, 1 + spaces)
        }
        let scalars = Array(text)
        var digits = 0
        while digits < scalars.count, digits < 3, scalars[digits].isNumber { digits += 1 }
        var markerEnd = digits
        if digits == 0, scalars.count > 2, scalars[0].isLetter, scalars[0].isLowercase { markerEnd = 1 }
        guard markerEnd > 0, markerEnd + 1 < scalars.count, scalars[markerEnd] == "." || scalars[markerEnd] == ")",
              scalars[markerEnd + 1] == " " else { return nil }
        let spaces = scalars[(markerEnd + 1)...].prefix(while: { $0 == " " || $0 == "\t" }).count
        return (true, markerEnd + 1 + spaces)
    }

    /// A list item: it starts with a marker, or Apple's recognition saw a list here and the marker got lost. A numbered
    /// item needs a numbered neighbour ("2024. war ..." alone is no list).
    private static func listItem(_ element: Element, previous: Element?, next: Element?, continuing: Bool?) -> (ordered: Bool, text: String)? {
        if let marker = listMarker(element.text) {
            let text = String(element.text.dropFirst(marker.length)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if marker.ordered, continuing != true, element.listHint != true,
               ![previous, next].contains(where: { $0.map { $0.isText && listMarker($0.text)?.ordered == true } ?? false }) {
                return nil
            }
            return (marker.ordered, text)
        }
        if element.listHint == true, let continuing { return (continuing, element.text) }
        return nil
    }

    /// Page numbers and running headers or footers: short lines above (below) all running text of a page, in its top
    /// (bottom) 15 %, that are a page number or come back on another page. Recognized text may differ a little from page
    /// to page ("Kapitelthema" / "Kapitelthena"), so "comes back" means at least 75 % alike, numbers ignored. A running header
    /// can also be the title of the text: directly above the same words on its page it goes and the title stays ("Zur
    /// Autorin" twice on a photographed book page). With real text, clearly larger than its other appearances it is a title too and stays;
    /// on scans sizes say too little for that (the same header measured 10.3 and 2.7 on photographed pages).
    static func removingPageFurniture(_ pages: [[Element]]) -> [[Element]] {
        enum Edge { case top, bottom }
        func edge(_ element: Element, on page: [Element]) -> Edge? {
            guard element.isText, element.lines <= 2, element.text.count <= 90 else { return nil }
            let body = page.filter { $0.isText && $0.lines >= 2 }
            if element.box.maxY < 0.15, !body.contains(where: { $0.box.maxY <= element.box.minY }) { return .top }
            if element.box.minY > 0.85, !body.contains(where: { $0.box.minY >= element.box.maxY }) { return .bottom }
            return nil
        }
        func key(_ text: String) -> String { text.lowercased().filter { !$0.isNumber && !$0.isWhitespace } }
        let edges = pages.enumerated().flatMap { number, page in
            page.compactMap { element in edge(element, on: page).map { (page: number, edge: $0, key: key(element.text), size: element.size) } }
        }
        return pages.enumerated().map { number, page in
            // The header above its own title on this page; the title then is no furniture, whatever else comes back.
            var headers = Set<Int>(), titles = Set<Int>()
            for index in page.indices.dropLast() where page[index + 1].isText && edge(page[index], on: page) == .top {
                let own = key(page[index].text), next = key(page[index + 1].text)
                guard own.count >= 3, RecognitionCheck.similarity(own, next) >= 0.85 else { continue }
                headers.insert(index)
                titles.insert(index + 1)
            }
            return page.indices.filter { index in
                let element = page[index]
                if headers.contains(index) { return false }
                if titles.contains(index) { return true }
                guard let side = edge(element, on: page) else { return true }
                if isPageNumber(element.text) { return false }
                let own = key(element.text)
                guard own.count >= 3 else { return true }
                return !edges.contains { other in
                    guard other.page != number, other.edge == side, RecognitionCheck.similarity(other.key, own) >= 0.75 else { return false }
                    return element.source == .recognized || element.size < other.size * 1.25
                }
            }.map { page[$0] }
        }
    }

    static func isPageNumber(_ text: String) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: "–", with: " ").replacingOccurrences(of: "-", with: " ").split(separator: " ")
        guard words.contains(where: { $0.allSatisfy(\.isNumber) }) else { return false }
        return words.allSatisfy { word in word.allSatisfy(\.isNumber) || ["seite", "page", "von", "of", "s.", "p.", "/"].contains(String(word)) }
            || text.range(of: #"^\s*\d+\s*/\s*\d+\s*$"#, options: .regularExpression) != nil
    }

    /// A paragraph that runs on to the next page (no sentence end, next page starts in lower case) becomes one paragraph.
    private static func mergeAcrossPages(_ pages: inout [[Element]]) {
        guard pages.count > 1 else { return }
        for index in 1..<pages.count {
            guard let last = pages[index - 1].last, last.isText, let first = pages[index].first, first.isText,
                  let end = last.text.last, !".!?:;\"“”)".contains(end), first.text.first?.isLowercase == true,
                  listMarker(last.text) == nil else { continue }
            pages[index - 1][pages[index - 1].count - 1].text = join([[Atom(text: last.text, box: .zero, size: 0)], [Atom(text: first.text, box: .zero, size: 0)]])
            pages[index - 1][pages[index - 1].count - 1].lines += first.lines
            pages[index - 1][pages[index - 1].count - 1].words += first.words
            pages[index].removeFirst()
        }
    }

    // MARK: Geometry

    static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat { max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) }

    /// How much of the smaller height the two boxes share, from 0 to 1.
    static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        return shared / max(min(a.height, b.height), 0.0001)
    }

    /// How much of `a` lies inside `b`, from 0 to 1.
    static func inside(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull, a.width > 0, a.height > 0 else { return 0 }
        return shared.width * shared.height / (a.width * a.height)
    }
}
