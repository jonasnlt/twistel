import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Finds what should be blacked out: words, patterns such as e-mail addresses, and faces. Only suggestions: the person ticks what goes.
enum RedactionFinder {
    enum Pattern: String, CaseIterable, Identifiable, Sendable {
        case email, phone, iban, date

        var id: String { rawValue }
        var title: String {
            switch self {
            case .email: return tr("E-mail addresses", "E-Mail-Adressen")
            case .phone: return tr("Phone numbers", "Telefonnummern")
            case .iban: return tr("IBANs", "IBANs")
            case .date: return tr("Dates (birth dates)", "Datumsangaben (Geburtstage)")
            }
        }
        var shortTitle: String {
            switch self {
            case .email: return tr("E-mail", "E-Mail")
            case .phone: return tr("Phone", "Telefon")
            case .iban: return "IBAN"
            case .date: return tr("Date", "Datum")
            }
        }
    }

    struct Request: Equatable, Sendable {
        var terms: [String] = []
        var patterns: Set<Pattern> = []
        var faces = false
        var isEmpty: Bool { terms.isEmpty && patterns.isEmpty && !faces }
    }

    struct Find: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case term
            /// One word of a term of several words, standing alone: "Frau Mustermann", "Mustermann, Erika".
            case part
            case pattern(Pattern)
            case face
        }

        let id = UUID()
        var page: Int
        var kind: Kind
        /// What it says; empty for a face.
        var text: String
        /// As fractions of the page or picture, origin top left.
        var boxes: [CGRect]
        /// The search term it came from, as typed; empty for patterns and faces.
        var term = ""

        static func == (a: Find, b: Find) -> Bool { a.page == b.page && a.kind == b.kind && a.text == b.text && a.boxes == b.boxes }

        var title: String {
            switch kind {
            case .term, .part: return text
            case .pattern: return text
            case .face: return tr("Face", "Gesicht")
            }
        }
        var kindTitle: String {
            switch kind {
            case .term: return tr("Word", "Wort")
            case .part: return tr("Part of \(term)", "Teil von \(term)")
            case .pattern(let pattern): return pattern.shortTitle
            case .face: return tr("Face", "Gesicht")
            }
        }
    }

    struct Word: Equatable, Sendable {
        var text: String
        var box: CGRect
    }

    struct Result: Sendable {
        var finds: [Find] = []
        /// Pages Vision did not answer for (1-based): their pictures were not looked at.
        var unreadPages: [Int] = []
    }

    // MARK: Whole files

    /// All pages: the text in the PDF and what the page shows as a picture. Also on pages with text: a screenshot in a report, letters drawn as shapes or a filled-in form
    /// are not in its text. That costs about a second per page.
    static func find(inPDF url: URL, request: Request, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Result {
        let document = try PDFRedactor.open(url)
        try await RecognitionCheck.shared.ensureWorking()
        var result = Result()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            progress(index + 1, document.pageCount)
            guard let page = document.page(at: index) else { continue }
            let textWords = PDFToWord.textAtoms(page).map { Word(text: $0.text, box: $0.box) }
            var finds = matches(in: textWords, request: request, page: index)
            if let picture = PDFRenderer.render(page: page, dpi: TextRecognizer.pageDPI) {
                do {
                    finds = merged(finds, with: try await find(in: picture, request: request, page: index))
                } catch is VisionLimit.NoAnswer {
                    result.unreadPages.append(index + 1)
                }
            }
            result.finds += finds
        }
        return result
    }

    /// One picture: text recognition and faces.
    static func find(in picture: CGImage, request: Request, page: Int = 0) async throws -> [Find] {
        var finds: [Find] = []
        if !request.terms.isEmpty || !request.patterns.isEmpty {
            finds = matches(in: words(of: try await TextRecognizer.recognize(picture, choosingWords: false)), request: request, page: page)
        }
        if request.faces {
            finds += try await faces(in: picture).map { Find(page: page, kind: .face, text: "", boxes: [$0]) }
        }
        return finds
    }

    /// Recognized words in fractions with the origin at the top left.
    static func words(of lines: [TextRecognizer.Line]) -> [Word] {
        TextRecognizer.rows(lines).joined().flatMap { line -> [Word] in
            line.words.isEmpty ? [Word(text: line.text, box: PDFToWord.topLeft(line.box))] : line.words.map { Word(text: $0.text, box: PDFToWord.topLeft($0.box)) }
        }
    }

    /// Faces with all the hair and chin (Vision's box ends at the forehead), as fractions with the origin at the top left. Looked for in the whole picture and in overlapping parts of it: on a page with a photo Vision
    /// found a face only in some parts, and each look takes only a few milliseconds.
    static func faces(in picture: CGImage) async throws -> [CGRect] {
        var found: [CGRect] = []
        for grid in 1...4 {
            let share = grid == 1 ? 1 : 2 / CGFloat(grid + 1)
            for column in 0..<grid {
                for row in 0..<grid {
                    try Task.checkCancellation()
                    let step = grid == 1 ? 0 : (1 - share) / CGFloat(grid - 1)
                    let part = CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: share, height: share)
                    let pixels = CGRect(x: part.minX * CGFloat(picture.width), y: part.minY * CGFloat(picture.height), width: part.width * CGFloat(picture.width), height: part.height * CGFloat(picture.height)).integral
                    guard let tile = grid == 1 ? picture : picture.cropping(to: pixels) else { continue }
                    let faces = try await VisionLimit.call(on: grid == 1 ? picture : nil) { try await DetectFaceRectanglesRequest().perform(on: tile) }
                    for observation in faces {
                        let face = PDFToWord.topLeft(observation.boundingBox.cgRect)
                        let inPicture = CGRect(x: part.minX + face.minX * part.width, y: part.minY + face.minY * part.height, width: face.width * part.width, height: face.height * part.height)
                        if let same = found.firstIndex(where: { TextRecognizer.overlap($0, inPicture) > 0.5 }) {
                            found[same] = found[same].union(inPicture)
                        } else {
                            found.append(inPicture)
                        }
                    }
                }
            }
        }
        return found.map { face in
            CGRect(x: face.minX - face.width * 0.35, y: face.minY - face.height * 0.8, width: face.width * 1.7, height: face.height * 2.1)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    /// Text and picture often show the same thing: one find for it.
    private static func merged(_ finds: [Find], with others: [Find]) -> [Find] {
        var result = finds
        for other in others where !result.contains(where: { $0.kind == other.kind && overlaps($0.boxes, other.boxes) }) { result.append(other) }
        return result.sorted { ($0.boxes.first?.minY ?? 0) < ($1.boxes.first?.minY ?? 0) }
    }

    private static func overlaps(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        a.contains { one in b.contains { one.intersects($0) } }
    }

    // MARK: Finding in words

    /// The words of a page or picture read as one text, with a place for each.
    static func matches(in words: [Word], request: Request, page: Int) -> [Find] {
        guard !words.isEmpty else { return [] }
        var text = ""
        var starts: [Int] = []
        for word in words {
            if !text.isEmpty { text += " " }
            starts.append((text as NSString).length)
            text += word.text
        }
        let nsText = text as NSString
        func find(_ range: NSRange, _ kind: Find.Kind, term: String = "") -> Find {
            let covered = words.indices.filter { index in
                let start = starts[index], end = start + (words[index].text as NSString).length
                return start < range.location + range.length && range.location < end
            }
            return Find(page: page, kind: kind, text: nsText.substring(with: range), boxes: lineBoxes(covered.map { words[$0].box }), term: term)
        }
        var finds: [Find] = []
        for term in request.terms {
            guard let regex = termExpression(term) else { continue }
            var taken = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map(\.range)
            finds += taken.map { find($0, .term, term: term) }
            for word in parts(of: term) {
                guard let regex = wordExpression(word) else { continue }
                for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) where !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    taken.append(match.range)
                    finds.append(find(match.range, .part, term: term))
                }
            }
        }
        var ibans: [NSRange] = []
        if request.patterns.contains(.iban) {
            ibans = ibanRanges(in: nsText)
            finds += ibans.map { find($0, .pattern(.iban)) }
        }
        if request.patterns.contains(.email) {
            finds += Self.email.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { find($0.range, .pattern(.email)) }
        }
        var dates: [NSRange] = []
        if request.patterns.contains(.date) || request.patterns.contains(.phone) {
            dates = Self.dates.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map(\.range)
        }
        if request.patterns.contains(.date) { finds += dates.map { find($0, .pattern(.date)) } }
        if request.patterns.contains(.phone) {
            let taken = ibans + dates
            for match in Self.phone.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                let digits = nsText.substring(with: match.range).filter(\.isNumber).count
                guard (7...15).contains(digits), !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                finds.append(find(match.range, .pattern(.phone)))
            }
        }
        return finds.sorted { ($0.boxes.first?.minY ?? 0) < ($1.boxes.first?.minY ?? 0) }
    }

    /// Boxes next to each other on one line become one.
    private static func lineBoxes(_ boxes: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for box in boxes {
            if let last = result.last, TextRecognizer.sharedHeight(last, box) > 0.5, box.minX >= last.minX, box.minX - last.maxX < box.height * 2 {
                result[result.count - 1] = last.union(box)
            } else {
                result.append(box)
            }
        }
        return result
    }

    /// A term as written, but also with big or small letters, with or without umlauts, and with spaces or a line-end hyphen between its letters: "Meyer" also finds "Mey-" "er".
    /// Between its words anything that is not a letter: text recognition reads "Erika, Mustermann", "Erika • Mustermann", "Erika_Mustermann".
    static func termExpression(_ term: String) -> NSRegularExpression? {
        let words = term.split(whereSeparator: \.isWhitespace).map(lettersPattern)
        guard !words.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: words.joined(separator: "[\\s\\p{P}\\p{S}]*"), options: [.caseInsensitive])
    }

    /// One word on its own: "Erika" does not find "Amerika", but "Mustermann" finds "Mustermanns".
    static func wordExpression(_ word: String) -> NSRegularExpression? {
        guard word.contains(where: { !$0.isWhitespace }) else { return nil }
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(lettersPattern(word))(?:['’]?s)?(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    private static func lettersPattern<Text: StringProtocol>(_ text: Text) -> String {
        let classes: [Character: String] = ["a": "[aäàáâ]", "ä": "(?:ä|ae|a)", "e": "[eèéê]", "i": "[iìíî]", "o": "[oöòóô]", "ö": "(?:ö|oe|o)", "u": "[uüùúû]", "ü": "(?:ü|ue|u)", "ß": "(?:ß|ss)", "c": "[cç]", "n": "[nñ]"]
        return text.filter { !$0.isWhitespace }.map { character -> String in
            classes[Character(character.lowercased())] ?? NSRegularExpression.escapedPattern(for: String(character))
        }.joined(separator: "[\\s\\-\\u00AD]*")
    }

    /// The words of a term of several words that say something on their own: not "von" or "Dr".
    static func parts(of term: String) -> [String] {
        let words = term.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
        guard words.count > 1 else { return [] }
        let small: Set<String> = ["von", "van", "vom", "zum", "zur", "der", "den", "dem", "des", "die", "das", "und", "the", "and", "for", "gmbh", "herr", "frau"]
        return words.filter { $0.count >= 3 && !small.contains($0.lowercased()) }
    }

    /// What must no longer be readable after blacking out what is ticked: the ticked terms and each of their words. What was left unticked was the person's choice and stays.
    static func gone(ticked: [Find], left: [Find]) -> (terms: [String], parts: [String]) {
        var chosen: Set<String> = []
        for find in left where find.kind != .face {
            chosen.insert(RedactionCheck.letters(find.text))
            guard find.kind == .term else { continue }
            chosen.insert(RedactionCheck.letters(find.term))
            chosen.formUnion(parts(of: find.term).map(RedactionCheck.letters))
        }
        let terms = ticked.filter { $0.kind != .face && $0.kind != .part }.map { $0.kind == .term ? $0.term : $0.text }
        // A word on its own counts as a word: "Erika" must not be found in "Amerika".
        let words = ticked.filter { $0.kind == .part }.map(\.text) + ticked.filter { $0.kind == .term }.flatMap { parts(of: $0.term) }
        var seen = chosen
        return (terms.filter { seen.insert(RedactionCheck.letters($0)).inserted }, words.filter { seen.insert(RedactionCheck.letters($0)).inserted })
    }

    private static let email = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+\\-äöüÄÖÜß]+@[A-Za-z0-9\\-äöü]+(?:\\.[A-Za-z0-9\\-äöü]+)*\\.[A-Za-z]{2,}")

    /// Starts like a phone number (+49, 0049, 0123, (0123)): an invoice number or a row of years does not.
    private static let phone = try! NSRegularExpression(pattern: "(?<![\\p{L}\\d.,/])(?:\\+\\s?\\d{1,3}|00\\s?\\d{1,3}|\\(?0\\d{1,5}\\)?)(?:[\\s/\\-–.]?\\(?\\d\\)?){4,14}(?!\\d)")

    private static let months = "Januar|Jänner|Februar|März|Maerz|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember|January|February|March|May|June|July|October|December|Jan\\.?|Feb\\.?|Mär\\.?|Mar\\.?|Apr\\.?|Jun\\.?|Jul\\.?|Aug\\.?|Sep\\.?|Sept\\.?|Okt\\.?|Oct\\.?|Nov\\.?|Dez\\.?|Dec\\.?"
    private static let dates = try! NSRegularExpression(pattern: "(?<![\\d.])\\d{1,2}\\.\\s?\\d{1,2}\\.\\s?(?:\\d{4}|\\d{2})(?!\\d)|(?<!\\d)\\d{4}-\\d{2}-\\d{2}(?!\\d)|(?<![\\d/])\\d{1,2}/\\d{1,2}/\\d{2,4}(?!\\d)|(?<!\\d)\\d{1,2}\\.?\\s(?:\(months))\\s\\d{4}(?!\\d)|\\b(?:\(months))\\s\\d{1,2},?\\s\\d{4}(?!\\d)", options: [.caseInsensitive])

    private static let ibanStart = try! NSRegularExpression(pattern: "\\b[A-Z]{2}\\d{2}(?:\\s?[A-Z0-9]){11,30}")
    private static let ibanLengths = ["DE": 22, "AT": 20, "CH": 21, "NL": 18, "FR": 27, "IT": 27, "ES": 24, "GB": 22, "BE": 16, "LU": 20, "PL": 28, "DK": 18, "SE": 24, "NO": 15, "FI": 18, "IE": 22, "PT": 25]

    /// The pattern also takes in what follows ("… 00 BIC COBADEFF"): the end comes from the check digits, otherwise from the country's length.
    /// A misread IBAN fails the check digits and is still found: better one find too many.
    private static func ibanRanges(in text: NSString) -> [NSRange] {
        ibanStart.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { match in
            let found = text.substring(with: match.range)
            var compact = "", ends: [Int] = []
            for (offset, unit) in found.utf16.enumerated() {
                guard let scalar = Unicode.Scalar(unit), !CharacterSet.whitespaces.contains(scalar) else { continue }
                compact.unicodeScalars.append(scalar)
                ends.append(offset + 1)
            }
            let country = String(compact.prefix(2))
            let valid = stride(from: compact.count, through: 15, by: -1).first { isValidIBAN(String(compact.prefix($0))) }
            let count = min(compact.count, valid ?? ibanLengths[country] ?? 22)
            return NSRange(location: match.range.location, length: ends[count - 1])
        }
    }

    static func isValidIBAN(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }.uppercased()
        guard compact.count >= 15, compact.count <= 34 else { return false }
        var remainder = 0
        for character in compact.dropFirst(4) + compact.prefix(4) {
            guard let value = character.isNumber ? character.wholeNumberValue : character.asciiValue.map({ Int($0) - 55 }), value >= 0 else { return false }
            remainder = value > 9 ? (remainder * 100 + value) % 97 : (remainder * 10 + value) % 97
        }
        return remainder == 1
    }
}
