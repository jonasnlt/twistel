import CoreGraphics
import Foundation
import PDFKit

/// Checks a blacked-out file before it is saved. Anything found means nothing is saved. Says what kind of problem it is, never the words themselves: messages reach the log.
enum RedactionCheck {
    /// Compared without spaces and big or small letters, the way readers put text together in different ways.
    static func letters(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "-" && $0 != "\u{00AD}" }.lowercased()
    }

    #if DEBUG
    /// Tests and the test access: the check finds this as well, to see that nothing is saved then.
    nonisolated(unsafe) static var simulatedProblem: String?
    #endif

    /// What a reader's text still gives away of these: a problem to name, or nil.
    /// `parts`: the single words of terms of several words. Text recognition may read "Erika, Mustermann" or cut a term in two, and then the term as a whole is not there any more, but its words are.
    static func stillReadable(terms: [String], parts: [String], in text: String) -> String? {
        let inText = letters(text)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        if terms.contains(where: { term in
            inText.contains(letters(term)) || RedactionFinder.termExpression(term)?.firstMatch(in: text, range: whole) != nil
        }) { return tr("a blacked-out word", "ein geschwärztes Wort") }
        if parts.contains(where: { RedactionFinder.wordExpression($0)?.firstMatch(in: text, range: whole) != nil }) { return tr("a part of a blacked-out term", "ein Teil eines geschwärzten Begriffs") }
        return nil
    }

    static func problems(in url: URL, terms: [String], parts: [String] = [], covers: [Int: [CGRect]], rebuilt: Set<Int>, pageCount: Int) async -> [String] {
        var problems: [String] = []
        #if DEBUG
        if let simulatedProblem { problems.append(simulatedProblem) }
        #endif
        guard let document = PDFDocument(url: url), let file = CGPDFDocument(url as CFURL), let data = try? Data(contentsOf: url) else { return [tr("the result cannot be read", "das Ergebnis lässt sich nicht lesen")] }
        if document.pageCount != pageCount { problems.append(tr("the number of pages changed", "die Seitenzahl hat sich geändert")) }
        problems += structureProblems(file)
        let raw = RawPDF(data)
        problems += raw.versionProblems()
        let terms = terms.filter { !letters($0).isEmpty }
        if !terms.isEmpty || !parts.isEmpty {
            func look(_ reader: String, _ text: String) {
                if let what = stillReadable(terms: terms, parts: parts, in: text) { problems.append(tr("\(what) can still be read with \(reader)", "\(what) ist mit \(reader) noch lesbar")) }
            }
            look("PDFKit", document.string ?? "")
            for (name, text) in await otherReaders(url) { look(name, text) }
            if raw.contains(any: terms) { problems.append(tr("a blacked-out word is still in the file itself", "ein geschwärztes Wort steht noch in der Datei selbst")) }
            if raw.contains(words: parts) { problems.append(tr("a part of a blacked-out term is still in the file itself", "ein Teil eines geschwärzten Begriffs steht noch in der Datei selbst")) }
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let places = covers[index] ?? []
            if !places.isEmpty {
                let centres = PDFToWord.textAtoms(page).map { CGPoint(x: $0.box.midX, y: $0.box.midY) }
                if centres.contains(where: { centre in places.contains { $0.contains(centre) } }) { problems.append(tr("page \(index + 1) has text under a black place", "Seite \(index + 1) hat Text unter einer schwarzen Stelle")) }
                if !isBlack(page, places: places) { problems.append(tr("page \(index + 1) is not black everywhere it should be", "Seite \(index + 1) ist nicht überall schwarz, wo sie es sein sollte")) }
            }
            if rebuilt.contains(index), let reference = file.page(at: index + 1), !isOnlyAPicture(reference) { problems.append(tr("page \(index + 1) holds more than its picture", "Seite \(index + 1) enthält mehr als ihr Bild")) }
        }
        return problems
    }

    /// Whatever else can read text here: pdftotext where it is installed, and Ghostscript. Each reads a PDF its own way.
    private static func otherReaders(_ url: URL) async -> [(String, String)] {
        var texts: [(String, String)] = []
        if let tool = Shell.which("pdftotext"), let result = try? await Shell.run(tool, [url.path, "-"]), result.succeeded { texts.append(("pdftotext", result.stdout)) }
        if let tool = PDFCompression.ghostscriptPath {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-check-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            if let result = try? await Shell.run(tool, ["-dSAFER", "-q", "-dBATCH", "-dNOPAUSE", "-sDEVICE=txtwrite", "-sOutputFile=-", PDFCompression.plainNamed(url, in: work).path], environment: ["TMPDIR": work.path + "/"]), result.succeeded {
                texts.append(("Ghostscript", result.stdout))
            }
        }
        return texts
    }

    /// Nothing that holds content besides the pages.
    private static func structureProblems(_ file: CGPDFDocument) -> [String] {
        var problems: [String] = []
        if let catalog = file.catalog {
            for (key, name) in [("AcroForm", tr("form fields", "Formularfelder")), ("Names", tr("attachments or scripts", "Anhänge oder Skripte")), ("OpenAction", tr("an opening action", "eine Aktion beim Öffnen")), ("AA", tr("automatic actions", "automatische Aktionen")), ("Metadata", tr("metadata", "Metadaten")), ("JavaScript", tr("scripts", "Skripte"))] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(catalog, key, &object) { problems.append(tr("the file still has \(name)", "die Datei enthält noch \(name)")) }
            }
        }
        if let info = file.info {
            for key in ["Title", "Author", "Subject", "Keywords"] {
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(info, key, &object) { problems.append(tr("the file still has metadata", "die Datei enthält noch Metadaten")) }
            }
        }
        for number in 0..<file.numberOfPages {
            guard let dictionary = file.page(at: number + 1)?.dictionary else { continue }
            var annotations: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Annots", &annotations) { problems.append(tr("page \(number + 1) still has comments or fields", "Seite \(number + 1) enthält noch Kommentare oder Felder")) }
        }
        return problems
    }

    /// In the page as drawn: nothing brighter than the little that saving as JPEG leaves. The edge is left out for the blurring of the drawing itself.
    private static func isBlack(_ page: PDFPage, places: [CGRect]) -> Bool {
        guard let picture = PDFRenderer.render(page: page, dpi: 150) else { return false }
        let width = picture.width, height = picture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        for place in places {
            let area = CGRect(x: place.minX * CGFloat(width), y: place.minY * CGFloat(height), width: place.width * CGFloat(width), height: place.height * CGFloat(height)).insetBy(dx: 2, dy: 2)
            guard area.width > 0, area.height > 0 else { continue }
            for y in max(0, Int(area.minY))..<min(height, Int(area.maxY)) {
                for x in max(0, Int(area.minX))..<min(width, Int(area.maxX)) {
                    let at = (y * width + x) * 4
                    if pixels[at] > 40 || pixels[at + 1] > 40 || pixels[at + 2] > 40 { return false }
                }
            }
        }
        return true
    }

    /// A rebuilt page has one picture and a font for its invisible text.
    private static func isOnlyAPicture(_ page: CGPDFPage) -> Bool {
        var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
        guard let dictionary = page.dictionary, CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        final class Count { var images = 0; var others = 0 }
        let count = Count()
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?, subtype: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream, let inner = CGPDFStreamGetDictionary(stream), CGPDFDictionaryGetName(inner, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                count.images += 1
            } else {
                count.others += 1
            }
            return true
        }, nil)
        return count.images == 1 && count.others == 0
    }
}

/// The bytes of a PDF: what stands between its streams, and its streams unpacked.
struct RawPDF {
    let data: Data
    /// The bytes outside streams.
    private(set) var outside = Data()
    private(set) var textStreams: [Data] = []
    /// Pictures and fonts: a short word occurs in them by chance.
    private(set) var binaryStreams: [Data] = []

    init(_ data: Data) {
        self.data = data
        let start = Data("stream".utf8), end = Data("endstream".utf8)
        var place = data.startIndex
        while let found = data.range(of: start, in: place..<data.endIndex) {
            // "endstream" also contains the word.
            if found.lowerBound >= data.startIndex + 3, data[(found.lowerBound - 3)..<found.lowerBound] == Data("end".utf8) {
                outside.append(data[place..<found.upperBound])
                place = found.upperBound
                continue
            }
            outside.append(data[place..<found.upperBound])
            var body = found.upperBound
            if body < data.endIndex, data[body] == 13 { body += 1 }
            if body < data.endIndex, data[body] == 10 { body += 1 }
            guard let close = data.range(of: end, in: body..<data.endIndex) else {
                place = found.upperBound
                break
            }
            let head = String(decoding: data[max(data.startIndex, found.lowerBound - 600)..<found.lowerBound], as: UTF8.self)
            let dictionary = head.components(separatedBy: " obj").last ?? head
            let stream = data[body..<close.lowerBound]
            let unpacked = dictionary.contains("FlateDecode") ? RawPDF.inflate(Data(stream)) ?? Data(stream) : Data(stream)
            let binary = ["/Image", "DCTDecode", "/Length1", "/FontFile", "Type1C", "CIDFontType0C", "OpenType", "ICCBased", "/N 3", "/N 1"].contains { dictionary.contains($0) }
            if binary { binaryStreams.append(unpacked) } else { textStreams.append(unpacked) }
            outside.append(end)
            place = close.upperBound
        }
        outside.append(data[place..<data.endIndex])
    }

    /// A zlib stream without its two bytes at the start.
    static func inflate(_ stream: Data) -> Data? {
        guard stream.count > 2 else { return nil }
        return try? (stream.dropFirst(2) as NSData).decompressed(using: .zlib) as Data
    }

    /// One version only: added versions at the end would keep older content.
    func versionProblems() -> [String] {
        func count(_ word: String) -> Int {
            let needle = Data(word.utf8)
            var total = 0, place = outside.startIndex
            while let found = outside.range(of: needle, in: place..<outside.endIndex) {
                total += 1
                place = found.upperBound
            }
            return total
        }
        var problems: [String] = []
        if count("%%EOF") != 1 || count("startxref") != 1 { problems.append(tr("the file has older versions in it", "die Datei enthält noch ältere Fassungen")) }
        for (word, name) in [("/EmbeddedFile", tr("attachments", "Anhänge")), ("/JavaScript", tr("scripts", "Skripte")), ("/JS", tr("scripts", "Skripte")), ("/XFA", tr("form fields", "Formularfelder")), ("/Annot", tr("comments or fields", "Kommentare oder Felder"))] where count(word) > 0 {
            problems.append(tr("the file still has \(name)", "die Datei enthält noch \(name)"))
        }
        return problems
    }

    /// As text, in the ways a PDF writes it: plain, as UTF-16, or as hexadecimal digits of these.
    private static func forms(of term: String) -> [Data] {
        var bytes = [Data(term.utf8)]
        if let latin = term.data(using: .isoLatin1) { bytes.append(latin) }
        if let wide = term.data(using: .utf16BigEndian) {
            bytes.append(wide)
            bytes.append(Data(wide.map { String(format: "%02x", $0) }.joined().utf8))
        }
        return bytes
    }

    private static func lowered(_ bytes: Data) -> Data { Data(bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }) }

    func contains(any terms: [String]) -> Bool {
        var needles: [Data] = [], longNeedles: [Data] = []
        for term in terms {
            for form in Set([term.lowercased(), term.filter { !$0.isWhitespace }.lowercased()]) where form.utf8.count >= 3 {
                let bytes = RawPDF.forms(of: form)
                needles += bytes
                longNeedles += bytes.filter { $0.count >= 8 }
            }
        }
        for part in [outside] + textStreams {
            let text = RawPDF.lowered(part)
            if needles.contains(where: { text.range(of: $0) != nil }) { return true }
        }
        for part in binaryStreams {
            let text = RawPDF.lowered(part)
            if longNeedles.contains(where: { text.range(of: $0) != nil }) { return true }
        }
        return false
    }

    /// Single words, as words only: "max" is also in "/MaxWidth", and a PDF's own names begin with a slash.
    func contains(words: [String]) -> Bool {
        let needles = words.flatMap { RawPDF.forms(of: $0.lowercased()) }.filter { !$0.isEmpty }
        func isLetter(_ byte: UInt8) -> Bool { (97...122).contains(byte) || byte >= 0x80 }
        for part in [outside] + textStreams {
            let text = RawPDF.lowered(part)
            for needle in needles {
                var place = text.startIndex
                while let found = text.range(of: needle, in: place..<text.endIndex) {
                    let before = found.lowerBound > text.startIndex ? text[found.lowerBound - 1] : 0
                    let after = found.upperBound < text.endIndex ? text[found.upperBound] : 0
                    if !isLetter(before), before != UInt8(ascii: "/"), !isLetter(after) { return true }
                    place = found.upperBound
                }
            }
        }
        return false
    }
}
