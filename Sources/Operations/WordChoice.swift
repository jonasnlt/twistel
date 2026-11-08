import AppKit
import Vision

/// The system's dictionary, German and English. Lookups are locked (the recognition runs in the background) and kept.
enum Spelling {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Bool] = [:]

    /// A word with hyphens is known when each of its parts is.
    static func isKnown(_ word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let answer = known[word] { return answer }
        let checker = NSSpellChecker.shared
        let answer = word.split(separator: "-").allSatisfy { part in
            ["de", "en"].contains { language in
                checker.checkSpelling(of: String(part), startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
        }
        known[word] = answer
        return answer
    }
}

/// Without language correction Vision misreads single letters ("Sustems", "requlation") and, with one candidate per line,
/// offers nothing else. With correction it gives ten, but also "corrects" names, and its answer sometimes never comes (about
/// once in a hundred lines, the task waits for ever; measured). So a word the dictionary does not know is compared with
/// other readings of its line, all without correction: the line on its own at three sizes. The first reading at the same
/// place that the dictionary knows replaces it, else the spelling most readings agree on (`majority`), otherwise the word stays
/// as it was read. Measured against hand-written target texts (characters wrong): a photographed page 6 → 5, the same as a
/// PDF at 250 dpi 6 → 4, at 300 dpi 14 → 8, at 366 dpi 15 → 12, at 400 dpi 4 → 2, at 500 dpi 8 → 3, other photo 19 → 18, screenshot
/// 26 → 25; every change right, no name changed.
extension TextRecognizer {
    /// Another reading of a word, with its box in the whole picture.
    struct Alternative: Equatable {
        let text: String
        let box: CGRect
        /// Which of the readings it comes from: one reading has one vote.
        var reading = 0
    }

    static func choosingKnownWords(_ lines: [Line], in image: CGImage, known: (String) -> Bool = Spelling.isKnown) async throws -> [Line] {
        var result: [Line] = []
        var previous: String?
        for line in rows(lines).joined() {
            var chosen = line
            if !doubtfulWords(line, previous: previous, known: known).isEmpty {
                try Task.checkCancellation()
                if let found = try await VisionLimit.optional({ try await alternatives(to: line, in: image) }) {
                    chosen = choosing(line, previous: previous, from: found, known: known)
                }
            }
            result.append(chosen)
            previous = line.text
        }
        return result
    }

    /// The word split from the punctuation around it.
    private static func core(of word: String) -> (lead: String, core: String, trail: String) {
        let characters = Array(word)
        var start = 0, end = characters.count
        while start < end, !characters[start].isLetter { start += 1 }
        while end > start, !characters[end - 1].isLetter { end -= 1 }
        return (String(characters[..<start]), String(characters[start..<end]), String(characters[end...]))
    }

    /// The places of the words to look at. Left alone: short words, anything with digits, words with two capitals (names
    /// and abbreviations like "KORVALIX", "PDF", "McName"), and the two parts of a word broken at the line's end ("Ergeb-",
    /// "ples"): the dictionary knows neither, and "ples" would become "pies" (measured).
    private static func doubtfulWords(_ line: Line, previous: String?, known: (String) -> Bool) -> [Int] {
        line.words.indices.filter { index in
            let word = line.words[index].text, core = core(of: word).core
            guard core.count >= 4, !word.contains(where: \.isNumber), core.filter(\.isUppercase).count < 2 else { return false }
            if index == line.words.count - 1, word.hasSuffix("-") { return false }
            if index == 0, previous?.hasSuffix("-") == true, core.first?.isLowercase == true { return false }
            return !known(core)
        }
    }

    /// `line` with its unknown words replaced: by an alternative at the same place with the same number of letters, at most two
    /// letters different, that the dictionary knows or most readings agree on. A lost or added letter usually means another
    /// word; only big and small letters different is no change (a name read in small letters stays as it was).
    static func choosing(_ line: Line, previous: String?, from alternatives: [Alternative], known: (String) -> Bool) -> Line {
        var words = line.words
        for index in doubtfulWords(line, previous: previous, known: known) {
            let word = words[index], read = core(of: word.text)
            let same = alternatives.filter { horizontalShare($0.box, word.box) > 0.6 && sharedHeight($0.box, word.box) > 0.4 }
            let similar = same.filter { other in
                let letters = core(of: other.text).core
                return letters.count == read.core.count && (1...2).contains(lettersApart(letters, read.core))
            }
            guard let pick = similar.map({ core(of: $0.text).core }).first(where: known) ?? majority(of: same, against: read.core, among: similar) else { continue }
            words[index] = Line.Word(text: read.lead + pick + read.trail, box: word.box, highlight: word.highlight)
        }
        guard words != line.words else { return line }
        return Line(text: words.map(\.text).joined(separator: " "), box: line.box, words: words, confidence: line.confidence)
    }

    /// The spelling most readings agree on. The dictionary does not know many right words ("Validierung", "qpdf"), so at least
    /// two readings must have it, and more than have the word as first read (which counts once more for that first reading).
    /// A name read the same way most of the time stays.
    private static func majority(of readings: [Alternative], against first: String, among similar: [Alternative]) -> String? {
        func votes(_ letters: String) -> Int { Set(readings.filter { core(of: $0.text).core == letters }.map(\.reading)).count }
        guard let pick = Set(similar.map { core(of: $0.text).core }).max(by: { (votes($0), $0) < (votes($1), $1) }), votes(pick) >= 2, votes(pick) > votes(first) + 1 else { return nil }
        return pick
    }

    /// In how many places two words of the same length differ, big and small letters alike.
    private static func lettersApart(_ a: String, _ b: String) -> Int {
        zip(a.lowercased(), b.lowercased()).filter { $0 != $1 }.count
    }

    /// The line on its own at full, 3/4 and half size.
    private static func alternatives(to line: Line, in image: CGImage) async throws -> [Alternative] {
        let size = CGSize(width: image.width, height: image.height)
        let margin = line.box.height * size.height
        // Pixels count from the top, Vision's boxes from the bottom.
        let pixels = CGRect(x: line.box.minX * size.width, y: (1 - line.box.maxY) * size.height, width: line.box.width * size.width, height: line.box.height * size.height)
            .insetBy(dx: -margin, dy: -margin * 0.6).intersection(CGRect(origin: .zero, size: size)).integral
        guard !pixels.isEmpty, let part = image.cropping(to: pixels) else { return [] }
        func inPage(_ box: CGRect) -> CGRect { TextRecognizer.boxInPage(box, part: pixels, of: size) }
        var found: [Alternative] = []
        for (reading, scale) in [CGFloat(1), 0.75, 0.5].enumerated() {
            guard let picture = scaled(part, by: scale) else { continue }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
            request.usesLanguageCorrection = false
            let recognition = request
            for observation in try await VisionLimit.call(on: picture, { try await recognition.perform(on: picture) }) {
                guard let candidate = observation.topCandidates(1).first else { continue }
                found += candidate.string.split(separator: " ").compactMap { token in
                    candidate.boundingBox(for: token.startIndex..<token.endIndex).map { Alternative(text: String(token), box: inPage($0.boundingBox.cgRect), reading: reading) }
                }
            }
        }
        return found
    }

    private static func scaled(_ image: CGImage, by scale: CGFloat) -> CGImage? {
        guard scale != 1 else { return image }
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
