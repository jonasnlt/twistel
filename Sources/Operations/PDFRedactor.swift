import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Blacks out parts of a PDF so that they are gone from the file. A page with something to black out is drawn into a picture, the places are filled black in its pixels,
/// and the picture becomes the new page; with text recognition over it, without the places, so that the page stays searchable. What was under them cannot survive that,
/// however it was stored: text, hidden text, pictures, shapes. Other pages stay as they are. The file is written anew, so metadata, comments, form fields, attachments,
/// scripts and older versions do not come along.
///
/// Apple's "Redact" annotation was tried first: on saving it really removes text and picture pixels and even cuts shapes, but it is not documented, turned a curve
/// into a line through the page, and nobody promises it stays that way after the next macOS. Taking the page apart oneself would mean understanding every way a PDF can hold
/// content. A picture can be checked completely.
enum PDFRedactor {
    /// A place drawn by hand: page and fractions of it, origin top left.
    struct Area: Equatable, Sendable {
        var page: Int
        var box: CGRect
    }

    /// Enough for small print and a scan's detail. The new pages are pictures.
    static let dpi: CGFloat = 300

    /// The PDF to work on, in memory: without comments and links (they do not come along), only form fields stay, because what they show belongs to the page. The visible part is
    /// the whole page, so that all places are counted the same way.
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        guard !document.isLocked else { throw AppError.invalidInput(tr("\(url.lastPathComponent) is protected by a password. Remove it first with PDF password.", "\(url.lastPathComponent) ist mit einem Passwort geschützt. Entferne es zuerst mit \u{201E}PDF-Passwort\u{201C}.")) }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.setBounds(page.bounds(for: .cropBox), for: .mediaBox)
            for annotation in page.annotations where annotation.type != "Widget" { page.removeAnnotation(annotation) }
        }
        return document
    }

    /// A find's boxes as they are blacked out. Boxes around text are tight, and a descender peeking out could give a word away, so they get a margin. A face's box has one already.
    static func cover(of find: RedactionFinder.Find) -> [CGRect] {
        guard find.kind != .face else { return find.boxes }
        return find.boxes.map { box in
            box.insetBy(dx: -box.height * 0.15, dy: -box.height * 0.2).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// `left`: what was found and left unticked. It may stay readable, and only it: anything else from the search that can still be read stops the saving.
    static func redact(_ url: URL, finds: [RedactionFinder.Find], left: [RedactionFinder.Find] = [], areas: [Area], to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let document = try open(url)
        var covers: [Int: [CGRect]] = [:]
        for find in finds { covers[find.page, default: []] += cover(of: find) }
        for area in areas { covers[area.page, default: []].append(area.box) }
        guard !covers.isEmpty else { throw AppError.invalidInput(tr("Nothing is ticked to be blacked out.", "Zum Schwärzen ist nichts angehakt.")) }
        try await RecognitionCheck.shared.ensureWorking()

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-redact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let output = work.appendingPathComponent("redacted.pdf")

        let gone = RedactionFinder.gone(ticked: finds, left: left)
        var underHand: [String] = []
        var kept = ""
        var rebuilt: Set<Int> = []
        var unread: [Int] = []
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            progress(Double(index) / Double(document.pageCount) * 0.8)
            let size = PDFToWord.pageSize(page)
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            let places = covers[index] ?? []
            // A filled-in form's values are part of what the page shows, but cannot stay as form fields.
            guard !places.isEmpty || !page.annotations.isEmpty else {
                context.beginPDFPage(info)
                page.draw(with: .mediaBox, to: context)
                context.endPDFPage()
                kept += " " + (page.string ?? "")
                continue
            }
            rebuilt.insert(index)
            guard let picture = PDFRenderer.render(page: page, dpi: dpi) else { throw AppError.encodeFailed(tr("page \(index + 1)", "Seite \(index + 1)")) }
            // What was under a place drawn by hand is gone too, and must be checked like the rest.
            let areasHere = areas.filter { $0.page == index }.map(\.box)
            if !areasHere.isEmpty {
                let read = (try? await TextRecognizer.recognize(picture, choosingWords: false)).map(RedactionFinder.words(of:)) ?? []
                let written = PDFToWord.textAtoms(page).map { RedactionFinder.Word(text: $0.text, box: $0.box) }
                underHand += (read + written).filter { word in areasHere.contains { $0.contains(CGPoint(x: word.box.midX, y: word.box.midY)) } }.map(\.text)
            }
            let black = try blackened(picture, places: places)
            var lines: [TextRecognizer.Line] = []
            do {
                lines = keeping(try await TextRecognizer.recognize(black), outside: places)
            } catch is VisionLimit.NoAnswer {
                unread.append(index + 1)
            }
            kept += " " + lines.map(\.text).joined(separator: " ")
            guard let data = SocialMedia.jpeg(black, quality: 0.92), let provider = CGDataProvider(data: data as CFData),
                  let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw AppError.encodeFailed(tr("page \(index + 1)", "Seite \(index + 1)")) }
            context.beginPDFPage(info)
            context.draw(jpeg, in: box)
            TextRecognizer.drawInvisible(lines, in: box, into: context)
            context.endPDFPage()
        }
        // A word left unticked in one place stays readable there: that was the choice. A word under a place drawn by hand may be an everyday word that also stands elsewhere.
        let keptLetters = RedactionCheck.letters(kept)
        let checkedHand = underHand.filter { !keptLetters.contains(RedactionCheck.letters($0)) }
        let leftWords = left.filter { $0.kind != .face }.map(\.text)
        if leftWords.contains(where: { keptLetters.contains(RedactionCheck.letters($0)) }) || checkedHand.count < underHand.count { JobNotes.add(tr("Some blacked-out words still appear in other places that were not ticked.", "Einige geschwärzte Wörter stehen noch an anderen Stellen, die nicht angehakt waren.")) }
        if let outline = cleanOutline(of: document, without: gone.terms + underHand, parts: gone.parts) { CGPDFContextSetOutline(context, outline as CFDictionary) }
        context.closePDF()
        if !unread.isEmpty { JobNotes.add(VisionLimit.skippedPages(unread) + tr(" They are not searchable.", unread.count == 1 ? " Sie ist nicht durchsuchbar." : " Sie sind nicht durchsuchbar.")) }
        if hadMore(url) { JobNotes.add(tr("Comments, links, attachments or form fields were in this PDF. They are not in the copy.", "In diesem PDF waren Kommentare, Links, Anhänge oder Formularfelder. Sie sind nicht in der Kopie.")) }

        progress(0.85)
        let found = await RedactionCheck.problems(in: output, terms: gone.terms + checkedHand, parts: gone.parts, covers: covers, rebuilt: rebuilt, pageCount: document.pageCount)
        try Task.checkCancellation()
        guard found.isEmpty else {
            // Only what kind of problem: no words from the document in the log.
            DiagnosticLog.log("redaction check failed: \(found)")
            throw AppError.invalidInput(tr("The check found that something could still be read, so nothing was saved: \(found.joined(separator: "; ")).", "Die Prüfung hat gefunden, dass noch etwas lesbar ist, deshalb wurde nichts gesichert: \(found.joined(separator: "; "))."))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: output, to: destination)
        progress(1)
    }

    /// Whether the PDF has more than its pages that does not come along: worth saying, because it may be missed.
    private static func hadMore(_ url: URL) -> Bool {
        guard let file = CGPDFDocument(url as CFURL), let catalog = file.catalog else { return false }
        var object: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(catalog, "AcroForm", &object) || CGPDFDictionaryGetObject(catalog, "Names", &object) { return true }
        return (0..<file.numberOfPages).contains { number in
            var annotations: CGPDFArrayRef?
            guard let page = file.page(at: number + 1)?.dictionary else { return false }
            return CGPDFDictionaryGetArray(page, "Annots", &annotations)
        }
    }

    /// Real black in the pixels: no transparency, no pale edge.
    static func blackened(_ picture: CGImage, places: [CGRect]) throws -> CGImage {
        let width = picture.width, height = picture.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AppError.encodeFailed(tr("page", "Seite")) }
        context.setShouldAntialias(false)
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for place in places {
            context.fill(CGRect(x: place.minX * CGFloat(width), y: (1 - place.maxY) * CGFloat(height), width: place.width * CGFloat(width), height: place.height * CGFloat(height)).integral)
        }
        guard let image = context.makeImage() else { throw AppError.encodeFailed(tr("page", "Seite")) }
        return image
    }

    /// Words recognized in the blackened picture, without any that lie on a black place: nothing should be read there, and if something is, it does not go into the file.
    /// Vision's boxes are generous: its word next to a place often reaches into it, and is still a word that can be seen.
    static func keeping(_ lines: [TextRecognizer.Line], outside places: [CGRect]) -> [TextRecognizer.Line] {
        func clear(_ box: CGRect) -> Bool {
            let word = PDFToWord.topLeft(box)
            return !places.contains { $0.contains(CGPoint(x: word.midX, y: word.midY)) || TextRecognizer.overlap($0, word) > 0.5 }
        }
        return lines.compactMap { line in
            guard !line.words.isEmpty else { return clear(line.box) ? line : nil }
            let words = line.words.filter { clear($0.box) }
            guard !words.isEmpty else { return nil }
            return TextRecognizer.Line(text: words.map(\.text).joined(separator: " "), box: line.box, words: words, confidence: line.confidence)
        }
    }

    /// The bookmarks without those that name anything blacked out; their targets stay on the same pages.
    private static func cleanOutline(of document: PDFDocument, without gone: [String], parts: [String]) -> [String: Any]? {
        let words = gone.map(RedactionCheck.letters).filter { $0.count >= 3 }
        func entries(of item: PDFOutline) -> [[String: Any]] {
            (0..<item.numberOfChildren).compactMap { index -> [String: Any]? in
                guard let child = item.child(at: index), let label = child.label else { return nil }
                let letters = RedactionCheck.letters(label)
                guard !words.contains(where: { letters.contains($0) }), RedactionCheck.stillReadable(terms: [], parts: parts, in: label) == nil else { return nil }
                var entry: [String: Any] = [kCGPDFOutlineTitle as String: label]
                if let page = (child.destination ?? (child.action as? PDFActionGoTo)?.destination)?.page {
                    let target = document.index(for: page)
                    if target >= 0 { entry[kCGPDFOutlineDestination as String] = target + 1 }
                }
                let below = entries(of: child)
                if !below.isEmpty { entry[kCGPDFOutlineChildren as String] = below }
                return entry
            }
        }
        guard let root = document.outlineRoot else { return nil }
        let top = entries(of: root)
        return top.isEmpty ? nil : [kCGPDFOutlineChildren as String: top]
    }
}
