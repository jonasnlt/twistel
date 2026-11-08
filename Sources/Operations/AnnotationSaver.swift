import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// How the place of a mark on a page as it is seen (origin top left) lies in the page's own coordinates, which do not change when a page is turned or cropped.
struct PDFPageSpace: Sendable {
    let size: CGSize
    let transform: CGAffineTransform

    init(_ page: PDFPage) {
        let crop = page.bounds(for: .cropBox), rotation = ((page.rotation % 360) + 360) % 360
        switch rotation {
        case 90:
            size = CGSize(width: crop.height, height: crop.width)
            transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: crop.minX, ty: crop.minY)
        case 180:
            size = crop.size
            transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: crop.maxX, ty: crop.minY)
        case 270:
            size = CGSize(width: crop.height, height: crop.width)
            transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: crop.maxX, ty: crop.maxY)
        default:
            size = crop.size
            transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: crop.minX, ty: crop.maxY)
        }
    }
}

/// A number or a magnifier as a comment: PDF has no such kind of its own, so it is a stamp with its picture. It can be moved, resized and deleted like any comment.
private final class MarkStamp: PDFAnnotation {
    var mark: Mark?
    var space: PDFPageSpace?
    var source: MarkPainter.Source?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let mark, let space else { return }
        context.saveGState()
        context.concatenate(space.transform)
        MarkPainter.draw(mark, in: context, source: source)
        context.restoreGState()
    }
}

enum AnnotationSaver {
    enum PDFMode: String, CaseIterable, Identifiable, Sendable {
        /// Real comments: they can still be changed in Preview.
        case comments
        /// Part of the page: nobody can change or remove them.
        case burned

        var id: String { rawValue }
        var title: String { self == .comments ? tr("Editable comments", "Bearbeitbare Kommentare") : tr("Burned in", "Fest eingebrannt") }
    }

    // MARK: Pictures

    /// The picture with the marks, in its own size.
    static func render(_ original: CGImage, marks: [Mark]) -> CGImage? {
        let space = original.colorSpace.flatMap { $0.supportsOutput && $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: original.width, height: original.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: original.width, height: original.height)
        context.interpolationQuality = .none
        context.draw(original, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let source = MarkPainter.Source(picture: original, size: size)
        for mark in marks { MarkPainter.draw(mark, in: context, source: source) }
        return context.makeImage()
    }

    /// Whether something in it really is see-through: a photo loaded from HEIC also comes with a channel for it, fully opaque. Looked at in a small copy: quick, and a see-through place still shows.
    static func hasTransparency(_ image: CGImage) -> Bool {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) else { return false }
        let side = 256
        var bytes = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return bytes.contains { $0 < 255 }
    }

    /// The same kind of file, unless the picture is see-through and that kind cannot hold it.
    static func outputFormat(for source: URL, image: CGImage) -> FileFormat {
        let format = ImageToolSupport.outputFormat(for: source)
        guard hasTransparency(image), ![.png, .tiff, .webp, .avif].contains(format) else { return format }
        return .png
    }

    /// `metadata`: as read from the original. The picture was loaded upright, so a stored turn would turn it a second time.
    static func save(_ image: CGImage, metadata: [CFString: Any], to destination: URL, format: FileFormat, quality: Double) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-annotate-\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: work) }
        if ImageIOBridge.canEncodeNatively(format) {
            var keep: [CFString: Any] = [:]
            if let exif = metadata[kCGImagePropertyExifDictionary] { keep[kCGImagePropertyExifDictionary] = exif }
            if var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = nil
                keep[kCGImagePropertyTIFFDictionary] = tiff
            }
            if let place = metadata[kCGImagePropertyGPSDictionary] { keep[kCGImagePropertyGPSDictionary] = place }
            keep[kCGImagePropertyOrientation] = 1
            try ImageIOBridge.write(image, to: work, format: format, quality: quality, metadata: keep)
        } else {
            try await ImageIOBridge.writeAnyFormat(image, to: work, format: format, quality: quality)
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: work, to: destination)
    }

    /// For pasting elsewhere, as PNG and TIFF: some apps take only the one or the other.
    static func copy(_ image: CGImage, to pasteboard: NSPasteboard = .general) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]), let tiff = bitmap.tiffRepresentation else { throw AppError.encodeFailed(tr("clipboard", "Zwischenablage")) }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setData(tiff, forType: .tiff)
    }

    // MARK: PDFs

    /// Enough for the small part a magnifier enlarges.
    private static let magnifierDPI: CGFloat = 400

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        guard !document.isLocked else { throw AppError.invalidInput(tr("\(url.lastPathComponent) is protected by a password. Remove it first with PDF password.", "\(url.lastPathComponent) ist mit einem Passwort geschützt. Entferne es zuerst mit \u{201E}PDF-Passwort\u{201C}.")) }
        return document
    }

    /// The page as it is seen, with comments already on it.
    static func picture(ofPage index: Int, in url: URL, dpi: CGFloat) throws -> (image: CGImage, size: CGSize) {
        let document = try open(url)
        guard let page = document.page(at: index) else { throw AppError.unreadable(url) }
        page.setBounds(page.bounds(for: .cropBox), for: .mediaBox)
        // A page is drawn only as long as its document lives.
        return try withExtendedLifetime(document) {
            guard let image = PDFRenderer.render(page: page, dpi: dpi) else { throw AppError.unreadable(url) }
            return (image, PDFToWord.pageSize(page))
        }
    }

    private static func source(page index: Int, of url: URL, marks: [Mark]) throws -> MarkPainter.Source? {
        guard marks.contains(where: { $0.kind == .magnifier }) else { return nil }
        let (image, size) = try picture(ofPage: index, in: url, dpi: magnifierDPI)
        return MarkPainter.Source(picture: image, size: size)
    }

    static func save(_ url: URL, marks: [Mark], mode: PDFMode, to destination: URL, progress: @escaping (Double) -> Void) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-annotate-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: work) }
        switch mode {
        case .comments: try writeComments(url, marks: marks, to: work, progress: progress)
        case .burned: try burn(url, marks: marks, to: work, progress: progress)
        }
        try Task.checkCancellation()
        try check(work, against: url, marks: marks, mode: mode)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: work, to: destination)
        progress(1)
    }

    private static func writeComments(_ url: URL, marks: [Mark], to file: URL, progress: (Double) -> Void) throws {
        let document = try open(url)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let here = marks.filter { $0.page == index }
            guard !here.isEmpty else { continue }
            let source = try source(page: index, of: url, marks: here)
            let space = PDFPageSpace(page)
            for mark in here { page.addAnnotation(annotation(for: mark, space: space, source: source)) }
            progress(Double(index + 1) / Double(document.pageCount) * 0.7)
        }
        guard document.write(to: file), let written = try? Data(contentsOf: file) else { throw AppError.encodeFailed(file.lastPathComponent) }
        try repairedStreams(written).write(to: file)
        // PDFKit wants comments let go on the main thread (it says so in the log otherwise).
        DispatchQueue.main.async { withExtendedLifetime(document) {} }
    }

    private static let textInset: CGFloat = 2

    static func annotation(for mark: Mark, space: PDFPageSpace, source: MarkPainter.Source?) -> PDFAnnotation {
        let box = mark.bounds.applying(space.transform).standardized
        let border = PDFBorder()
        border.lineWidth = mark.lineWidth
        let annotation: PDFAnnotation
        switch mark.kind {
        case .arrow:
            let room = mark.lineWidth + mark.arrowHead
            annotation = PDFAnnotation(bounds: box.insetBy(dx: -room, dy: -room), forType: .line, withProperties: nil)
            let origin = annotation.bounds.origin
            func local(_ point: CGPoint) -> CGPoint {
                let onPage = point.applying(space.transform)
                return CGPoint(x: onPage.x - origin.x, y: onPage.y - origin.y)
            }
            annotation.startPoint = local(mark.points[0])
            annotation.endPoint = local(mark.points[1])
            annotation.endLineStyle = .closedArrow
            annotation.color = mark.color.nsColor()
            annotation.interiorColor = mark.color.nsColor()
        case .text:
            // A text comment keeps 2 points of air around its text and sets its first line a little higher (measured).
            let placed = mark.frame.offsetBy(dx: 0, dy: mark.fontSize * 0.065).applying(space.transform).standardized
            annotation = PDFAnnotation(bounds: placed.insetBy(dx: -textInset, dy: -textInset), forType: .freeText, withProperties: nil)
            annotation.contents = mark.text
            annotation.font = NSFont(name: "Helvetica", size: mark.fontSize)
            annotation.fontColor = mark.color.nsColor()
            annotation.color = .clear
            border.lineWidth = 0
        case .rectangle:
            annotation = PDFAnnotation(bounds: box, forType: .square, withProperties: nil)
            annotation.color = mark.color.nsColor()
        case .ellipse:
            annotation = PDFAnnotation(bounds: box, forType: .circle, withProperties: nil)
            annotation.color = mark.color.nsColor()
        case .pen, .highlighter:
            annotation = PDFAnnotation(bounds: box.insetBy(dx: -mark.lineWidth, dy: -mark.lineWidth), forType: .ink, withProperties: nil)
            let origin = annotation.bounds.origin
            let path = NSBezierPath()
            path.lineWidth = mark.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            for (index, point) in mark.points.enumerated() {
                let onPage = point.applying(space.transform)
                let local = CGPoint(x: onPage.x - origin.x, y: onPage.y - origin.y)
                if index == 0 { path.move(to: local) } else { path.line(to: local) }
            }
            if mark.points.count == 1 { path.line(to: path.currentPoint) }
            annotation.add(path)
            annotation.color = mark.color.nsColor(alpha: mark.kind == .highlighter ? Mark.highlighterAlpha : 1)
        case .number, .magnifier, .picture:
            let stamp = MarkStamp(bounds: box, forType: .stamp, withProperties: nil)
            stamp.mark = mark
            stamp.space = space
            stamp.source = source
            if mark.kind == .number { stamp.contents = "\(mark.number)" }
            annotation = stamp
        }
        annotation.border = border
        // Otherwise the name of the person logged in to the Mac is written into every comment.
        annotation.userName = ""
        return annotation
    }

    private static func burn(_ url: URL, marks: [Mark], to file: URL, progress: @escaping (Double) -> Void) throws {
        _ = try open(url)
        var sources: [Int: MarkPainter.Source] = [:]
        for page in Set(marks.map(\.page)) { sources[page] = try source(page: page, of: url, marks: marks.filter { $0.page == page }) }
        try PDFStamp.stamp(url, to: file, progress: { progress($0 * 0.9) }) { context, box, index, _ in
            let here = marks.filter { $0.page == index }
            guard !here.isEmpty else { return }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.maxY)
            context.scaleBy(x: 1, y: -1)
            for mark in here { MarkPainter.draw(mark, in: context, source: sources[index]) }
            context.restoreGState()
        }
    }

    /// Three faults of PDFKit's writer (also in comments that only hold text): fonts inside comments come without the stream length a PDF must give, and a text comment's
    /// font and size are written as a name with a broken spelling instead of a string, so that its size reads back as 12. Readers guess the one, and the other shows when a comment is edited.
    /// And Apple's own note in each comment (for Preview) has the scale of its model as 0: Preview then picks a scale of its own when a text is edited, and the writing shrinks
    /// (14 points became 6.7, scale 0.48). With 1, the size shown, the size in the comment and the size when editing are the same.
    /// Corrects all three and moves the table of places in the file along. A file with another layout stays as it is.
    static func repairedStreams(_ data: Data) -> Data {
        // Latin-1 keeps one character per byte, so that places in the text are places in the file.
        guard let text = String(data: data, encoding: .isoLatin1),
              let lengths = try? NSRegularExpression(pattern: "<<\\s*/Length1\\s+(\\d+)\\s*>>\\s*stream\\r?\\n"),
              let fonts = try? NSRegularExpression(pattern: "/DA /([^\\s/<>\\[\\]()]+#2320Tf[^\\s/<>\\[\\]()]*)"),
              let notes = try? NSRegularExpression(pattern: "/AAPL:AKAnnotationObject \\(([A-Za-z0-9+/=]+)\\)") else { return data }
        let whole = text as NSString
        let everything = NSRange(location: 0, length: whole.length)
        var edits: [(place: Int, removed: Int, bytes: Data)] = []
        for match in lengths.matches(in: text, range: everything) {
            let close = whole.range(of: ">>", options: [], range: match.range)
            if close.location != NSNotFound { edits.append((close.location, 0, Data("/Length \(whole.substring(with: match.range(at: 1))) ".utf8))) }
        }
        for match in fonts.matches(in: text, range: everything) {
            let spelled = whole.substring(with: match.range(at: 1)).replacingOccurrences(of: "#2320", with: " ")
            edits.append((match.range.location, match.range.length, Data("/DA (/\(spelled))".utf8)))
        }
        for match in notes.matches(in: text, range: everything) {
            let range = match.range(at: 1)
            if let scaled = scaledNote(whole.substring(with: range)) { edits.append((range.location, range.length, Data(scaled.utf8))) }
        }
        edits.sort { $0.place < $1.place }
        let tablePlace = whole.range(of: "\nxref", options: .backwards)
        guard !edits.isEmpty, tablePlace.location != NSNotFound else { return data }
        let tail = whole.substring(from: tablePlace.location + 1)
        // One plain table only, as PDFKit writes it.
        let pieces = tail.components(separatedBy: "trailer")
        guard pieces.count == 2, !pieces[1].contains("/Prev"), let start = pieces[1].range(of: "startxref"), let end = pieces[1].range(of: "%%EOF") else { return data }
        // How far each place moves: the sum of what the edits before it add, found by halving (edits are sorted by place).
        var shifts = [0]
        for edit in edits { shifts.append(shifts[shifts.count - 1] + edit.bytes.count - edit.removed) }
        func moved(_ offset: Int) -> Int {
            var low = 0, high = edits.count
            while low < high {
                let middle = (low + high) / 2
                if edits[middle].place <= offset { low = middle + 1 } else { high = middle }
            }
            return offset + shifts[low]
        }

        var result = Data()
        var place = 0
        for edit in edits where edit.place <= tablePlace.location {
            result.append(data[place..<edit.place])
            result.append(edit.bytes)
            place = edit.place + edit.removed
        }
        result.append(data[place...tablePlace.location])
        let table = result.count
        var lines: [String] = []
        for line in pieces[0].components(separatedBy: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 3, fields[2] == "n", fields[0].count == 10, let offset = Int(fields[0]) {
                lines.append(String(format: "%010d %@ n ", moved(offset), String(fields[1])))
            } else {
                lines.append(line)
            }
        }
        result.append(Data(lines.joined(separator: "\n").utf8))
        result.append(Data(("trailer" + pieces[1][..<start.upperBound] + "\n\(table)\n" + pieces[1][end.lowerBound...]).utf8))
        return result
    }

    /// Apple's note (a keyed archive, base64), with every model scale of 0 set to 1; nil when there is nothing to change.
    static func scaledNote(_ base64: String) -> String? {
        guard let raw = Data(base64Encoded: base64),
              let note = try? PropertyListSerialization.propertyList(from: raw, options: .mutableContainersAndLeaves, format: nil) as? NSMutableDictionary,
              let objects = note["$objects"] as? NSMutableArray else { return nil }
        var changed = false
        for case let object as NSMutableDictionary in objects {
            if let scale = object["originalModelBaseScaleFactor"] as? NSNumber, scale.doubleValue == 0 {
                object["originalModelBaseScaleFactor"] = 1.0
                changed = true
            }
        }
        guard changed, let written = try? PropertyListSerialization.data(fromPropertyList: note, format: .binary, options: 0) else { return nil }
        return written.base64EncodedString()
    }

    /// The first word of `before` that is not in `after`, in the order of the page; a burned-in text may stand between.
    /// Only words with a letter or digit count: rewriting a page can lose the text behind a lone sign from a font Ghostscript made
    /// (the "€" of a table in a PDF/A file, measured; it stays visible). That is no reason to refuse the whole file.
    /// The page's text is turned into one string once and searched character for character (both in the same Unicode form): searching
    /// a Swift string converted it anew for every word, which made a page with many words take seconds.
    static func lostWord(before: String, after: String) -> String? {
        let words = RedactionCheck.letters(after).precomposedStringWithCanonicalMapping as NSString
        let length = words.length
        var place = 0
        var elsewhere = Set<String>()
        for word in before.split(whereSeparator: \.isWhitespace).map({ RedactionCheck.letters(String($0)).precomposedStringWithCanonicalMapping })
            where word.contains(where: { $0.isLetter || $0.isNumber }) {
            var found = words.range(of: word, options: .literal, range: NSRange(location: place, length: length - place))
            if found.location == NSNotFound {
                // Not further on: anywhere before (text can stand in another order), searched backwards from here, so the nearest is found
                // first. A word found so once needs no second search.
                if elsewhere.contains(word) { continue }
                let reach = min(length, place + (word as NSString).length)
                found = words.range(of: word, options: [.literal, .backwards], range: NSRange(location: 0, length: reach))
                guard found.location != NSNotFound else { return word }
                elsewhere.insert(word)
            }
            place = found.location + found.length
        }
        return nil
    }

    /// Before anything is saved: as many pages, all of the text still there, and the marks in the file.
    private static func check(_ file: URL, against url: URL, marks: [Mark], mode: PDFMode) throws {
        guard let result = PDFDocument(url: file), let original = PDFDocument(url: url) else { throw AppError.encodeFailed(file.lastPathComponent) }
        guard result.pageCount == original.pageCount else { throw AppError.invalidInput(tr("The result has another number of pages, so nothing was saved.", "Das Ergebnis hat eine andere Seitenzahl, deshalb wurde nichts gesichert.")) }
        for index in 0..<original.pageCount {
            guard let before = original.page(at: index), let after = result.page(at: index) else { continue }
            guard lostWord(before: before.string ?? "", after: after.string ?? "") == nil else {
                throw AppError.invalidInput(tr("Text of page \(index + 1) would not be searchable any more, so nothing was saved.", "Der Text von Seite \(index + 1) wäre nicht mehr durchsuchbar, deshalb wurde nichts gesichert."))
            }
            if mode == .comments {
                let wanted = before.annotations.count + marks.filter { $0.page == index }.count
                guard after.annotations.count == wanted else { throw AppError.invalidInput(tr("Not all comments of page \(index + 1) were written, so nothing was saved.", "Nicht alle Kommentare von Seite \(index + 1) wurden geschrieben, deshalb wurde nichts gesichert.")) }
            }
        }
    }
}
