import CoreText
import Foundation
import PDFKit
import Vision

/// Text recognition (OCR) with Apple Vision, on this Mac, German and English. Images become .txt files; scanned PDFs
/// become searchable PDFs (the page as it was, with invisible text on top) and/or .txt files.
enum TextRecognizer {
    static let languages = ["de-DE", "en-US"]
    /// Off: Vision's language correction "corrects" names and technical terms into plausible wrong words ("qpdf" became
    /// "apdf"), which nobody notices. Measured against hand-written target texts it was no better overall.
    static let usesLanguageCorrection = false
    /// Pages are read at this resolution; enough for small print, quick enough for long scans.
    static let pageDPI: CGFloat = 300
    /// A page with at least this many characters of real text is taken as it is and not recognized again.
    static let existingTextThreshold = 20

    enum PDFOutput: String, CaseIterable, Identifiable {
        case searchablePDF
        case text
        case both

        static let standard = PDFOutput.searchablePDF
        var id: String { rawValue }
        var title: String {
            switch self {
            case .searchablePDF: return tr("Searchable PDF", "Durchsuchbares PDF")
            case .text: return tr("Text file", "Textdatei")
            case .both: return tr("Both", "Beides")
            }
        }
    }

    /// One recognized line: its text, its box and the box of each word in the image, as fractions with the origin at
    /// the bottom left. `words` is empty when Vision gave no word boxes.
    struct Line: Equatable {
        struct Word: Equatable {
            let text: String
            let box: CGRect
            /// The highlighter colour on the word in the picture (`Highlighter.marked`).
            var highlight: Highlighter.Color?
        }

        let text: String
        let box: CGRect
        var words: [Word] = []
        /// How sure Vision is, from 0 to 1. It gave 1 for good lines and 0.3 or 0.5 for misread ones.
        var confidence: Float = 1
    }

    /// Lines Vision is less sure of are read once more on their own (`rereadingUnsure`).
    static let rereadBelow: Float = 0.75

    /// What the recognition is doing right now, for the progress card.
    struct Status: Equatable {
        let fraction: Double
        let step: String
    }

    /// The lines of one picture. Read with Apple's newer Vision interface: the older one (VNRecognizeTextRequest) drops
    /// some lines without a word, with the same model and the same settings. Where Vision's text finder sees text but no
    /// line was recognized, that spot is read once more on its own, so short lines like "PDF“." are not lost either.
    /// Highlighter colour is taken out first (`Highlighter`), and lines Vision is unsure of are read again on their own.
    /// Words the dictionary does not know are compared with other readings of their line (`choosingKnownWords`).
    static func recognize(_ image: CGImage, choosingWords: Bool = true) async throws -> [Line] {
        do {
            return try await recognizeLines(image, choosingWords: choosingWords)
        } catch where Task.isCancelled {
            // Vision answers Cancel with its own error; the progress card should say "Cancelled", not "failed".
            throw CancellationError()
        }
    }

    private static func recognizeLines(_ original: CGImage, choosingWords: Bool) async throws -> [Line] {
        let image = Highlighter.cleaned(original) ?? original
        // The first reading is what counts; without an answer the page cannot be read. All the others improve on it.
        var lines = try await rereadingUnsure(try await read(image), in: image, read: read)
        let regions = try await VisionLimit.optional {
            try await VisionLimit.call(on: image) { try await DetectTextRectanglesRequest().perform(on: image).map(\.boundingBox.cgRect) }
        } ?? []
        for spot in regions {
            guard !isRead(spot, in: lines) else { continue }
            try Task.checkCancellation()
            if let found = try await VisionLimit.optional({ try await read(part: spot, of: image, with: read) }) { lines = adding(found, to: lines) }
        }
        lines = adding(try await readingLeftOutEnds(of: lines, regions: regions, in: image), to: lines)
        lines = joiningPieces(lines, imageSize: CGSize(width: image.width, height: image.height))
        if choosingWords { lines = try await choosingKnownWords(lines, in: image) }
        return Highlighter.marked(lines, in: original)
    }

    /// Text at the end of a line that Vision's text finder sees but the reading left out: the "4." before a heading comes
    /// and goes between readings (same picture). The end is read on its own with a piece of the line, and
    /// the words beside the line are kept.
    private static func readingLeftOutEnds(of lines: [Line], regions: [CGRect], in image: CGImage) async throws -> [Line] {
        let size = CGSize(width: image.width, height: image.height)
        var found: [Line] = []
        for region in regions {
            let row = lines.filter { sharedHeight($0.box, region) > 0.5 && horizontalShare($0.box, region) > 0.5 }
            guard let first = row.map(\.box.minX).min(), let last = row.map(\.box.maxX).max() else { continue }
            // In fractions of the picture's width: half a letter height is too little to be a word.
            let height = region.height * size.height / size.width
            for (from, to, outside) in [(region.minX, first + height * 4, region.minX < first - height * 0.5), (last - height * 4, region.maxX, region.maxX > last + height * 0.5)] where outside {
                try Task.checkCancellation()
                let part = CGRect(x: from, y: region.minY, width: to - from, height: region.height)
                let reading = try await VisionLimit.optional { try await read(part: part, of: image, with: read) } ?? []
                for line in reading where sharedHeight(line.box, region) > 0.5 {
                    let words = line.words.filter { $0.box.midX < first || $0.box.midX > last }
                    guard !words.isEmpty, words.contains(where: { $0.text.contains { $0.isLetter || $0.isNumber } }) else { continue }
                    found.append(Line(text: words.map(\.text).joined(separator: " "), box: words.reduce(CGRect.null) { $0.union($1.box) },
                                      words: words, confidence: line.confidence))
                }
            }
        }
        return found
    }

    /// The place `spot` (Vision's fractions, origin bottom left) read on its own, with a margin so the letters are whole;
    /// the lines found in it with their boxes in the whole picture.
    /// A box found in a cut-out part (`pixels`, counted from the top left), as a share of the whole page.
    static func boxInPage(_ box: CGRect, part pixels: CGRect, of size: CGSize) -> CGRect {
        CGRect(x: (pixels.minX + box.minX * pixels.width) / size.width, y: 1 - (pixels.maxY - box.minY * pixels.height) / size.height,
               width: box.width * pixels.width / size.width, height: box.height * pixels.height / size.height)
    }

    static func read(part spot: CGRect, of image: CGImage, with read: (CGImage) async throws -> [Line]) async throws -> [Line] {
        let size = CGSize(width: image.width, height: image.height)
        // Pixels count from the top, Vision's boxes from the bottom.
        let margin = spot.height * size.height
        let pixels = CGRect(x: spot.minX * size.width, y: (1 - spot.maxY) * size.height, width: spot.width * size.width, height: spot.height * size.height)
            .insetBy(dx: -margin, dy: -margin * 0.6).intersection(CGRect(origin: .zero, size: size)).integral
        guard !pixels.isEmpty, let part = image.cropping(to: pixels) else { return [] }
        func inPage(_ box: CGRect) -> CGRect { boxInPage(box, part: pixels, of: size) }
        return try await read(part).map { found in
            Line(text: found.text, box: inPage(found.box), words: found.words.map { Line.Word(text: $0.text, box: inPage($0.box)) }, confidence: found.confidence)
        }
    }

    /// Lines Vision is unsure of, read once more on their own. On a curved photographed line it gave nonsense such as
    /// letter salad with Cyrillic letters (confidence 0.3) for the whole page, the same line on its own was read right (1.0,
    /// measured on photographed pages). The new reading counts only if it is the line at the same place (the margin
    /// also catches its neighbours) and Vision is surer of it.
    static func rereadingUnsure(_ lines: [Line], in image: CGImage, read: (CGImage) async throws -> [Line]) async throws -> [Line] {
        var result = lines
        for (index, line) in lines.enumerated() where line.confidence < rereadBelow {
            try Task.checkCancellation()
            guard let found = try await VisionLimit.optional({ try await self.read(part: line.box, of: image, with: read) }) else { continue }
            let same = found.filter { sharedHeight($0.box, line.box) > 0.5 && horizontalShare($0.box, line.box) > 0.5 }
            guard let best = same.max(by: { overlap($0.box, line.box) < overlap($1.box, line.box) }), best.confidence > line.confidence else { continue }
            result[index] = best
        }
        return result
    }

    /// How much of the lower of the two boxes' heights they share, from 0 to 1.
    static func sharedHeight(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY)) / max(min(a.height, b.height), 0.000_001)
    }

    /// How much of the narrower of the two boxes' widths they share, from 0 to 1.
    static func horizontalShare(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) / max(min(a.width, b.width), 0.000_001)
    }

    /// Whether the words of `lines` cover the place `spot`. On a slanted photo the box of a neighbouring line covers much
    /// of a line that was never read, and its words lie in the spot's tall box too (at 366 dpi a whole line was lost
    /// that way), so only words count that, with the page's slant, are at the height of the spot's middle.
    private static func isRead(_ spot: CGRect, in lines: [Line]) -> Bool {
        let slope = pageSlope(lines)
        var covered: CGFloat = 0
        for line in lines {
            for box in line.words.isEmpty ? [line.box] : line.words.map(\.box) {
                let height: CGFloat = box.midY + slope * (spot.midX - box.midX)
                guard abs(height - spot.midY) <= box.height * 0.45 else { continue }
                covered += max(0, min(box.maxX, spot.maxX) - max(box.minX, spot.minX))
            }
        }
        return covered >= spot.width * 0.5
    }

    /// Lines read a second time are added only where no line was recognized yet: the margin around a spot often catches
    /// pieces of lines that are already there (e.g. "1. Zie" next to a numbered list).
    static func adding(_ found: [Line], to lines: [Line]) -> [Line] {
        var result = lines
        func boxes(_ line: Line) -> [CGRect] { line.words.isEmpty ? [line.box] : line.words.map(\.box) }
        for line in found where !boxes(line).contains(where: { box in result.flatMap(boxes).contains { overlap($0, box) > 0.3 } }) {
            result.append(line)
        }
        return result
    }

    /// The first reading of a picture, before spots without a line are read again.
    static func read(_ image: CGImage) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        request.usesLanguageCorrection = usesLanguageCorrection
        let reading = request
        return try await VisionLimit.call(on: image) { try await reading.perform(on: image) }.compactMap { observation in
            observation.topCandidates(1).first.map {
                Line(text: $0.string, box: observation.boundingBox.cgRect, words: words(of: $0), confidence: $0.confidence)
            }
        }
    }

    /// Each word with its own box, so the invisible text can sit exactly on the word in the picture; all or nothing.
    private static func words(of candidate: RecognizedText) -> [Line.Word] {
        var words: [Line.Word] = []
        for token in candidate.string.split(separator: " ") {
            guard let box = candidate.boundingBox(for: token.startIndex..<token.endIndex)?.boundingBox.cgRect else { return [] }
            words.append(Line.Word(text: String(token), box: box))
        }
        return words
    }

    /// How much of the smaller box lies inside the other one, from 0 to 1.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let common = a.intersection(b)
        let smaller = min(a.width * a.height, b.width * b.height)
        return common.isNull || smaller <= 0 ? 0 : common.width * common.height / smaller
    }

    /// Lines in reading order (top to bottom, then left to right), joined into plain text.
    static func plainText(_ lines: [Line]) -> String {
        rows(lines).joined().map(\.text).joined(separator: "\n")
    }

    /// The lines by rows, top to bottom, each row left to right. On a slanted photo the box of a line is much taller than
    /// its letters, and the boxes of neighbouring lines overlap by more than half (a line and
    /// the line below it), so the rows come from the height of the words, with the page's slant taken out.
    static func rows(_ lines: [Line]) -> [[Line]] {
        func center(_ line: Line) -> CGPoint {
            guard let first = line.words.first?.box, let last = line.words.last?.box else { return CGPoint(x: line.box.midX, y: line.box.midY) }
            return CGPoint(x: (first.midX + last.midX) / 2, y: (first.midY + last.midY) / 2)
        }
        func height(_ line: Line) -> CGFloat { line.words.isEmpty ? line.box.height : middle(line.words.map(\.box.height)) }
        let slope = pageSlope(lines)
        func level(_ line: Line) -> CGFloat { center(line).y - slope * (center(line).x - 0.5) }
        var rows: [(level: CGFloat, height: CGFloat, lines: [Line])] = []
        for line in lines.sorted(by: { level($0) > level($1) }) {
            if let row = rows.last, row.level - level(line) <= min(row.height, height(line)) / 2 {
                rows[rows.count - 1].lines.append(line)
            } else {
                rows.append((level(line), height(line), [line]))
            }
        }
        return rows.map { $0.lines.sorted { $0.box.minX < $1.box.minX } }
    }

    /// How much the lines of a page fall to the right, from the first and last word of each line.
    private static func pageSlope(_ lines: [Line]) -> CGFloat {
        middle(lines.compactMap { line -> CGFloat? in
            guard let first = line.words.first?.box, let last = line.words.last?.box, last.midX - first.midX > 0.1 else { return nil }
            return (last.midY - first.midY) / (last.midX - first.midX)
        })
    }

    private static func middle(_ values: [CGFloat]) -> CGFloat {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    /// Vision sometimes gives one line in pieces (the start of a line and its rest, or the "4." and the heading
    /// after it). Pieces next to each other at the same height, less than a letter height apart, become one line. Two
    /// columns or table cells are further apart.
    static func joiningPieces(_ lines: [Line], imageSize size: CGSize) -> [Line] {
        rows(lines).flatMap { row -> [Line] in
            var result: [Line] = []
            for line in row {
                guard let last = result.last else { result.append(line); continue }
                // The ends that meet, not the whole boxes: a slanted line's box says little about its height at one end.
                let end = last.words.last?.box ?? last.box, start = line.words.first?.box ?? line.box
                let letters = min(end.height, start.height) * size.height
                let gap = (start.minX - end.maxX) * size.width
                guard gap <= letters, gap >= -letters, abs(start.midY - end.midY) * size.height <= letters / 2 else { result.append(line); continue }
                result[result.count - 1] = Line(text: last.text + " " + line.text, box: last.box.union(line.box),
                                                words: last.words.isEmpty || line.words.isEmpty ? [] : last.words + line.words,
                                                confidence: min(last.confidence, line.confidence))
            }
            return result
        }
    }

    // MARK: Images

    static func text(ofImage url: URL, progress: @escaping (Status) -> Void = { _ in }) async throws -> String {
        let image = try ImageIOBridge.load(url)
        // Vision reports no progress within a picture; the card shows a moving bar until it is done.
        progress(Status(fraction: 0, step: tr("Recognizing text", "Text wird erkannt")))
        return plainText(try await recognize(image))
    }

    // MARK: PDFs

    /// Writes a searchable PDF and/or a text file for a scanned PDF. Pages that already contain text are copied as they are.
    /// A page with at least `enoughText` letters counts as having text. For a plain text file a page with a few words is fine as it is.
    static func process(pdf url: URL, searchablePDF: URL?, text: URL?, enoughText: Int = existingTextThreshold, progress: @escaping (Status) -> Void = { _ in }) async throws {
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        guard !document.isLocked else { throw AppError.invalidInput(tr("\(url.lastPathComponent) is password protected.", "\(url.lastPathComponent) ist mit einem Passwort geschützt.")) }
        var context: CGContext?
        if let searchablePDF {
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            context = CGContext(searchablePDF as CFURL, mediaBox: &box, nil)
            guard context != nil else { throw AppError.encodeFailed(searchablePDF.lastPathComponent) }
        }
        var pageTexts: [String] = []
        var recognizedSomething = false
        var skipped: [Int] = []
        let count = document.pageCount
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let step = tr("Page \(index + 1) of \(count)", "Seite \(index + 1) von \(count)")
            progress(Status(fraction: Double(index) / Double(count), step: step))
            let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var lines: [Line] = []
            if existing.count >= enoughText {
                pageTexts.append(existing)
            } else if let image = PDFRenderer.render(page: page, dpi: pageDPI) {
                do {
                    lines = try await recognize(image)
                    pageTexts.append(plainText(lines))
                    recognizedSomething = recognizedSomething || !lines.isEmpty
                } catch is VisionLimit.NoAnswer {
                    // The page stays as it is in the PDF, just without text to search; the text file says so at its place.
                    skipped.append(index + 1)
                    pageTexts.append("[\(VisionLimit.skippedPages([index + 1]))]")
                }
            }
            if let context { draw(page, invisibleLines: lines, into: context) }
            progress(Status(fraction: Double(index + 1) / Double(count), step: step))
        }
        context?.closePDF()
        if !skipped.isEmpty {
            guard skipped.count < count else {
                if let searchablePDF { try? FileManager.default.removeItem(at: searchablePDF) }
                throw VisionLimit.NoAnswer()
            }
            JobNotes.add(VisionLimit.skippedPages(skipped))
        }
        let allText = pageTexts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard recognizedSomething || !allText.isEmpty else {
            if let searchablePDF { try? FileManager.default.removeItem(at: searchablePDF) }
            throw AppError.invalidInput(tr("No text was found in \(url.lastPathComponent).", "In \(url.lastPathComponent) wurde kein Text gefunden."))
        }
        if let text { try allText.write(to: text, atomically: true, encoding: .utf8) }
    }

    /// The page as it was (vectors, images and all), with the recognized lines as invisible, selectable text on top.
    static func draw(_ page: PDFPage, invisibleLines lines: [Line], into context: CGContext) {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        var pageBox = CGRect(x: 0, y: 0, width: rotated ? bounds.height : bounds.width, height: rotated ? bounds.width : bounds.height)
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
        context.beginPDFPage(info)
        context.saveGState()
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        drawInvisible(lines, in: pageBox, into: context)
        context.endPDFPage()
    }

    /// The lines as invisible, selectable text over a page of this size.
    static func drawInvisible(_ lines: [Line], in pageBox: CGRect, into context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            func inPage(_ box: CGRect) -> CGRect {
                CGRect(x: box.minX * pageBox.width, y: box.minY * pageBox.height, width: box.width * pageBox.width, height: box.height * pageBox.height)
            }
            let lineRect = inPage(line.box)
            // Word by word where Vision gave word boxes; otherwise the whole line.
            let runs = line.words.isEmpty ? [(line.text, lineRect)] : line.words.map { ($0.text, inPage($0.box)) }
            for (text, rect) in runs where !text.isEmpty {
                // No horizontal stretching: PDFKit (and Preview) ignore it when they place search hits and selections, so a
                // stretched line was highlighted up to 17 letters beside the word. The font size makes the text as wide
                // as in the picture instead. Its height doesn't matter for searching.
                let size = lineRect.height * 0.8
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let natural = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), nil, nil, nil)
                guard natural > 0 else { continue }
                let fitted = CTFontCreateWithName("Helvetica" as CFString, max(1, size * rect.width / CGFloat(natural)), nil)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: rect.minX, y: lineRect.minY + lineRect.height * 0.2)
                // With a space after it, or copied text runs together ("beideWörter"); it does not change where the word sits.
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text + " ", attributes: [.font: fitted])), context)
            }
        }
        context.restoreGState()
    }

    // MARK: The tool's job

    /// `run` off the main thread. Cancelling the calling task (the Cancel button) also stops the page being recognized.
    static func runInBackground(_ url: URL, output: PDFOutput, in directory: URL, progress: @escaping @Sendable (Status) -> Void) async throws -> [URL] {
        let notes = JobNotes.current
        let task = Task.detached { try await JobNotes.$current.withValue(notes) { try await run(url, output: output, in: directory, progress: progress) } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Recognizes `url` and writes the results next to it (via the temporary folder); returns the files written.
    static func run(_ url: URL, output: PDFOutput, in directory: URL, progress: @escaping (Status) -> Void) async throws -> [URL] {
        progress(Status(fraction: 0, step: tr("Checking text recognition", "Texterkennung wird geprüft")))
        try await RecognitionCheck.shared.ensureWorking()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-ocr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        var staged: [(URL, URL)] = []
        if FileFormat.detect(url) == .pdf {
            let pdf = output == .text ? nil : work.appendingPathComponent("searchable.pdf")
            let text = output == .searchablePDF ? nil : work.appendingPathComponent("text.txt")
            try await process(pdf: url, searchablePDF: pdf, text: text, progress: progress)
            if let pdf { staged.append((pdf, ConversionMatrix.uniqueURL(directory: directory, baseName: base, suffix: tr("searchable", "durchsuchbar"), ext: "pdf"))) }
            if let text { staged.append((text, ConversionMatrix.uniqueURL(directory: directory, baseName: base, suffix: "", ext: "txt"))) }
        } else {
            let text = try await self.text(ofImage: url, progress: progress)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.invalidInput(tr("No text was found in \(url.lastPathComponent).", "In \(url.lastPathComponent) wurde kein Text gefunden."))
            }
            let file = work.appendingPathComponent("text.txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            staged.append((file, ConversionMatrix.uniqueURL(directory: directory, baseName: base, suffix: "", ext: "txt")))
            progress(Status(fraction: 1, step: tr("Recognizing text", "Text wird erkannt")))
        }
        try Task.checkCancellation()
        for (from, to) in staged { try FileManager.default.moveItem(at: from, to: to) }
        DiagnosticLog.log("text recognition: \(FileFormat.detect(url)?.rawValue ?? "?") input, \(staged.count) file(s) written")
        return staged.map(\.1)
    }
}
