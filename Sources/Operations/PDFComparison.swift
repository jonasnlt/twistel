import CoreGraphics
import CoreImage
import Foundation
import PDFKit
import Vision

/// Compares two PDFs: the text as one long text, so that a page break that moved is no change, and each page as a picture, for images, layout and scans.
struct PDFComparison: @unchecked Sendable {
    struct Place: Equatable, Sendable {
        var page: Int
        /// Fractions of the page, origin top left.
        var box: CGRect
    }

    /// One word, or two parts of a word broken at the end of a line.
    struct Token: Equatable, Sendable {
        var text: String
        var key: String
        var places: [Place]
    }

    struct Change: Equatable, Sendable {
        enum Kind: String, Sendable { case added, removed, changed }
        var kind: Kind
        var oldText: String
        var newText: String
        var oldPlaces: [Place]
        var newPlaces: [Place]
    }

    /// A page of the old file with the page of the new one that shows the same; nil where there is none.
    struct PagePair: Equatable, Sendable {
        var old: Int?
        var new: Int?
        /// Where the pictures differ, as fractions of the page, origin top left.
        var regions: [CGRect] = []
        /// Moves the new page's picture onto the old one's: only for scans, which never lie exactly the same.
        var alignment: CGAffineTransform?
        var isScan = false
    }

    var oldURL: URL
    var newURL: URL
    var oldPageCount = 0
    var newPageCount = 0
    var changes: [Change] = []
    var pairs: [PagePair] = []
    /// Pages read by text recognition: small differences in reading are not reported.
    var oldScanned: Set<Int> = []
    var newScanned: Set<Int> = []
    var unreadable: [String] = []

    func changes(on pair: PagePair) -> [Change] {
        changes.filter { change in
            (pair.old != nil && change.oldPlaces.first?.page == pair.old) || (change.oldPlaces.isEmpty && pair.new != nil && change.newPlaces.first?.page == pair.new)
        }
    }

    func hasDifferences(_ pair: PagePair) -> Bool {
        pair.old == nil || pair.new == nil || !pair.regions.isEmpty || !changes(on: pair).isEmpty
    }

    var removedPages: [Int] { pairs.filter { $0.new == nil }.compactMap(\.old) }
    var addedPages: [Int] { pairs.filter { $0.old == nil }.compactMap(\.new) }

    static let visualDPI: CGFloat = 110
    /// Pages per PDF that are compared: the page order works with a table of old × new pages (2,000 × 2,000 is 64 MB).
    static let largestPageCount = 2_000
    /// Words per PDF: beyond that a document is no longer compared word by word in reasonable time.
    static let largestWordCount = 1_500_000
    /// Longest pieces of text compared letter by letter (scans, reading errors); longer ones count as changed.
    static let longestSimilarText = 2_000
    /// Most removed × added words looked at one by one for reading errors.
    static let mostReadingErrorPairs = 250_000

    // MARK: Whole files

    static func compare(_ oldURL: URL, _ newURL: URL, progress: @escaping @Sendable (Double, String?) -> Void = { _, _ in }) async throws -> PDFComparison {
        var result = PDFComparison(oldURL: oldURL, newURL: newURL)
        try await RecognitionCheck.shared.ensureWorking()
        let old = try AnnotationSaver.open(oldURL), new = try AnnotationSaver.open(newURL)
        for (document, url) in [(old, oldURL), (new, newURL)] where document.pageCount > largestPageCount {
            throw AppError.invalidInput(tr("\(url.lastPathComponent) has \(document.pageCount) pages; PDFs of up to \(largestPageCount) pages can be compared.",
                                           "\(url.lastPathComponent) hat \(document.pageCount) Seiten; verglichen werden können PDFs mit bis zu \(largestPageCount) Seiten."))
        }
        result.oldPageCount = old.pageCount
        result.newPageCount = new.pageCount
        let total = Double(old.pageCount + new.pageCount) * 2
        var done = 0.0
        func tick(_ step: String) {
            done += 1
            progress(min(done / max(total, 1), 0.99), step)
        }
        let oldRead = try await read(old, name: tr("old", "alte"), result: &result.unreadable) { tick(tr("Reading old page \($0)", "Alte Seite \($0) wird gelesen")) }
        let newRead = try await read(new, name: tr("new", "neue"), result: &result.unreadable) { tick(tr("Reading new page \($0)", "Neue Seite \($0) wird gelesen")) }
        result.oldScanned = oldRead.scanned
        result.newScanned = newRead.scanned
        let anyScan = !oldRead.scanned.isEmpty || !newRead.scanned.isEmpty
        guard oldRead.tokens.count <= largestWordCount, newRead.tokens.count <= largestWordCount else {
            throw AppError.invalidInput(tr("These PDFs have too much text to be compared word by word (more than 1.5 million words).",
                                           "Diese PDFs haben zu viel Text, um sie Wort für Wort zu vergleichen (mehr als 1,5 Millionen Wörter)."))
        }
        try Task.checkCancellation()
        let matches = matchedTokens(oldRead.tokens, newRead.tokens)
        try Task.checkCancellation()
        result.changes = try groupedChanges(oldRead.tokens, newRead.tokens, matches: matches, tolerant: anyScan)
        let thumbsOld = try thumbnails(oldURL, count: old.pageCount), thumbsNew = try thumbnails(newURL, count: new.pageCount)
        let aligned = try alignPages(oldCount: old.pageCount, newCount: new.pageCount, oldTokens: oldRead.tokens, newTokens: newRead.tokens, matches: matches, oldThumbs: thumbsOld, newThumbs: thumbsNew)
        for var pair in aligned {
            try Task.checkCancellation()
            if let oldPage = pair.old, let newPage = pair.new {
                tick(tr("Comparing page \(oldPage + 1)", "Seite \(oldPage + 1) wird verglichen"))
                pair.isScan = oldRead.scanned.contains(oldPage) || newRead.scanned.contains(newPage)
                let a = try AnnotationSaver.picture(ofPage: oldPage, in: oldURL, dpi: visualDPI).image
                let b = try AnnotationSaver.picture(ofPage: newPage, in: newURL, dpi: visualDPI).image
                let sized = PixelPage(b, width: a.width, height: a.height)
                if pair.isScan { pair.alignment = try? alignment(of: b, onto: a) }
                let moved = pair.alignment.flatMap { warped(b, by: $0, width: a.width, height: a.height) } ?? sized
                pair.regions = regions(PixelPage(a, width: a.width, height: a.height), moved, tolerant: pair.isScan)
            }
            result.pairs.append(pair)
        }
        progress(1, nil)
        return result
    }

    private static func read(_ document: PDFDocument, name: String, result unreadable: inout [String], tick: (Int) -> Void) async throws -> (tokens: [Token], scanned: Set<Int>) {
        var words: [(text: String, place: Place)] = []
        var scanned: Set<Int> = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            tick(index + 1)
            guard let page = document.page(at: index) else { continue }
            page.setBounds(page.bounds(for: .cropBox), for: .mediaBox)
            let written = PDFToWord.textAtoms(page)
            if written.map(\.text.count).reduce(0, +) >= TextRecognizer.existingTextThreshold {
                words += written.map { ($0.text, Place(page: index, box: $0.box)) }
                continue
            }
            // No real text on it: what the page shows, by text recognition.
            scanned.insert(index)
            guard let picture = PDFRenderer.render(page: page, dpi: TextRecognizer.pageDPI) else { continue }
            do {
                let lines = try await TextRecognizer.recognize(picture)
                words += RedactionFinder.words(of: lines).map { ($0.text, Place(page: index, box: $0.box)) }
            } catch is VisionLimit.NoAnswer {
                unreadable.append(tr("\(name) page \(index + 1)", "\(name) Seite \(index + 1)"))
            }
        }
        return (tokens(from: words), scanned)
    }

    /// Words as they are compared. "Muster-" at the end of a line and "mann" on the next are one word: where a line ends changes when text moves.
    static func tokens(from words: [(text: String, place: Place)]) -> [Token] {
        var result: [Token] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.text.hasSuffix("-") || word.text.hasSuffix("\u{00AD}"), index + 1 < words.count, word.text.count > 1 {
                let next = words[index + 1]
                let nextLine = next.place.page != word.place.page || next.place.box.minY > word.place.box.midY
                if nextLine, next.text.first?.isLowercase == true {
                    let joined = String(word.text.dropLast()) + next.text
                    result.append(Token(text: joined, key: key(joined), places: [word.place, next.place]))
                    index += 2
                    continue
                }
            }
            result.append(Token(text: word.text, key: key(word.text), places: [word.place]))
            index += 1
        }
        return result
    }

    /// The same word however it is set: ligatures, kinds of quotation marks and dashes, an invisible hyphen.
    static func key(_ word: String) -> String {
        var text = word.precomposedStringWithCompatibilityMapping
        for (from, to) in [("\u{00AD}", ""), ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{201E}", "\""), ("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{2013}", "-"), ("\u{2014}", "-")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text
    }

    // MARK: Text

    /// Which tokens of the two texts are the same, in order.
    private static func matchedTokens(_ old: [Token], _ new: [Token]) -> [(old: Int, new: Int)] {
        var ids: [String: Int] = [:]
        func id(_ key: String) -> Int {
            if let known = ids[key] { return known }
            ids[key] = ids.count
            return ids.count - 1
        }
        return commonParts(old.map { id($0.key) }, new.map { id($0.key) })
    }

    /// The longest list of equal items in the same order (Myers' way, from his 1986 paper). If two texts are too different to be worth it, what lies between their equal start and end counts as all changed.
    static func commonParts(_ a: [Int], _ b: [Int], limit: Int = 5000) -> [(old: Int, new: Int)] {
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }
        var pairs = (0..<start).map { (old: $0, new: $0) }
        let n = endA - start, m = endB - start
        if n > 0, m > 0 {
            let most = min(n + m, limit)
            var v = [Int](repeating: 0, count: 2 * most + 3)
            let offset = most + 1
            var trace: [[Int]] = []
            var found: Int?
            search: for d in 0...most {
                // Only what this round can change: keeps the memory small.
                trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
                for k in stride(from: -d, through: d, by: 2) {
                    var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                    var y = x - k
                    while x < n, y < m, a[start + x] == b[start + y] {
                        x += 1
                        y += 1
                    }
                    v[offset + k] = x
                    if x >= n, y >= m {
                        found = d
                        break search
                    }
                }
            }
            if let found {
                var x = n, y = m
                var inner: [(old: Int, new: Int)] = []
                for d in stride(from: found, to: 0, by: -1) {
                    let before = trace[d]
                    func value(_ k: Int) -> Int { before[k + d + 1] }
                    let k = x - y
                    let previous = (k == -d || (k != d && value(k - 1) < value(k + 1))) ? k + 1 : k - 1
                    let px = value(previous), py = px - previous
                    while x > px, y > py {
                        x -= 1
                        y -= 1
                        inner.append((start + x, start + y))
                    }
                    x = px
                    y = py
                }
                while x > 0, y > 0 {
                    x -= 1
                    y -= 1
                    inner.append((start + x, start + y))
                }
                pairs += inner.reversed()
            }
        }
        pairs += (0..<(a.count - endA)).map { (old: endA + $0, new: endB + $0) }
        return pairs
    }

    /// What lies between the equal parts.
    private static func groupedChanges(_ old: [Token], _ new: [Token], matches: [(old: Int, new: Int)], tolerant: Bool) throws -> [Change] {
        var changes: [Change] = []
        var nextOld = 0, nextNew = 0
        func close(_ oldEnd: Int, _ newEnd: Int) {
            var removed = Array(old[nextOld..<oldEnd]), added = Array(new[nextNew..<newEnd])
            if tolerant { (removed, added) = withoutReadingErrors(removed, added) }
            guard !removed.isEmpty || !added.isEmpty else { return }
            // The same letters, only divided differently: not a change.
            if squeezed(removed.map(\.key).joined()) == squeezed(added.map(\.key).joined()) { return }
            if tolerant, !removed.isEmpty, !added.isEmpty, similar(squeezed(removed.map(\.key).joined()), squeezed(added.map(\.key).joined())) { return }
            let kind: Change.Kind = removed.isEmpty ? .added : added.isEmpty ? .removed : .changed
            changes.append(Change(kind: kind, oldText: removed.map(\.text).joined(separator: " "), newText: added.map(\.text).joined(separator: " "), oldPlaces: removed.flatMap(\.places), newPlaces: added.flatMap(\.places)))
        }
        for (index, match) in matches.enumerated() {
            if index % 1_000 == 0 { try Task.checkCancellation() }
            close(match.old, match.new)
            nextOld = match.old + 1
            nextNew = match.new + 1
        }
        close(old.count, new.count)
        return changes
    }

    private static func squeezed(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Text recognition misreads a letter here and there, big or small, a comma. On scans such a word is the same word.
    private static func withoutReadingErrors(_ removed: [Token], _ added: [Token]) -> ([Token], [Token]) {
        var old = removed, new = added
        guard old.count * new.count <= mostReadingErrorPairs else { return (old, new) }
        var i = 0
        while i < old.count, !Task.isCancelled {
            if let j = new.firstIndex(where: { similar(squeezed($0.key), squeezed(old[i].key)) }) {
                old.remove(at: i)
                new.remove(at: j)
            } else {
                i += 1
            }
        }
        return (old, new)
    }

    /// At most one letter in five different.
    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let longest = max(a.count, b.count)
        guard longest >= 4, longest <= longestSimilarText else { return false }
        return editDistance(Array(a), Array(b), limit: longest / 5) <= longest / 5
    }

    static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            var smallest = row[0]
            for (j, y) in b.enumerated() {
                let current = row[j + 1]
                row[j + 1] = x == y ? previous : min(previous, current, row[j]) + 1
                previous = current
                smallest = min(smallest, row[j + 1])
            }
            if smallest > limit { return limit + 1 }
        }
        return row[b.count]
    }

    // MARK: Pages

    private static func thumbnails(_ url: URL, count: Int) throws -> [[UInt8]] {
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        return try (0..<count).map { index in
            try Task.checkCancellation()
            guard let page = document.page(at: index), let picture = PDFRenderer.render(page: page, dpi: 18) else { return [] }
            return PixelPage(picture, width: 48, height: 64).gray
        }
    }

    /// Which page shows what: by the words they share, or by how alike they look if they have no words. Pages keep their order; a page without a partner is one that was added or removed.
    private static func alignPages(oldCount: Int, newCount: Int, oldTokens: [Token], newTokens: [Token], matches: [(old: Int, new: Int)], oldThumbs: [[UInt8]], newThumbs: [[UInt8]]) throws -> [PagePair] {
        guard oldCount > 0 || newCount > 0 else { return [] }
        var shared = [[Int]](repeating: [Int](repeating: 0, count: max(newCount, 1)), count: max(oldCount, 1))
        for match in matches {
            guard let a = oldTokens[match.old].places.first?.page, let b = newTokens[match.new].places.first?.page else { continue }
            shared[a][b] += 1
        }
        var wordsOld = [Int](repeating: 0, count: max(oldCount, 1)), wordsNew = [Int](repeating: 0, count: max(newCount, 1))
        for token in oldTokens { if let page = token.places.first?.page { wordsOld[page] += 1 } }
        for token in newTokens { if let page = token.places.first?.page { wordsNew[page] += 1 } }
        func score(_ i: Int, _ j: Int) -> Double {
            if wordsOld[i] >= 5 || wordsNew[j] >= 5 {
                return Double(shared[i][j]) / Double(max(wordsOld[i], wordsNew[j], 1))
            }
            let a = oldThumbs[i], b = newThumbs[j]
            guard a.count == b.count, !a.isEmpty else { return 0 }
            let difference = zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
            return max(0, 1 - difference / 25)
        }
        // Best order-keeping choice: a page is paired only if they really have something in common.
        let threshold = 0.2
        var best = [[Double]](repeating: [Double](repeating: 0, count: newCount + 1), count: oldCount + 1)
        for i in stride(from: oldCount - 1, through: 0, by: -1) {
            try Task.checkCancellation()
            for j in stride(from: newCount - 1, through: 0, by: -1) {
                let s = score(i, j)
                best[i][j] = max(best[i + 1][j], best[i][j + 1], s >= threshold ? s + best[i + 1][j + 1] : 0)
            }
        }
        var pairs: [PagePair] = []
        var i = 0, j = 0
        while i < oldCount || j < newCount {
            if i < oldCount, j < newCount {
                let s = score(i, j)
                if s >= threshold, abs(best[i][j] - (s + best[i + 1][j + 1])) < 1e-9 {
                    pairs.append(PagePair(old: i, new: j))
                    i += 1
                    j += 1
                } else if best[i + 1][j] >= best[i][j + 1] {
                    pairs.append(PagePair(old: i, new: nil))
                    i += 1
                } else {
                    pairs.append(PagePair(old: nil, new: j))
                    j += 1
                }
            } else if i < oldCount {
                pairs.append(PagePair(old: i, new: nil))
                i += 1
            } else {
                pairs.append(PagePair(old: nil, new: j))
                j += 1
            }
        }
        return pairs
    }

    // MARK: Pictures

    /// A page as brightness values.
    struct PixelPage {
        var width: Int
        var height: Int
        var gray: [UInt8]

        init(_ image: CGImage, width: Int, height: Int) {
            self.width = width
            self.height = height
            gray = [UInt8](repeating: 255, count: width * height)
            gray.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        /// The average of each point with its neighbours, for what a scan blurs anyway.
        func blurred(radius: Int) -> [UInt8] {
            guard radius > 0 else { return gray }
            var across = [Int32](repeating: 0, count: gray.count)
            var out = [UInt8](repeating: 0, count: gray.count)
            let size = Int32(radius * 2 + 1)
            for y in 0..<height {
                var sum: Int32 = 0
                for x in -radius...radius { sum += Int32(gray[y * width + min(max(x, 0), width - 1)]) }
                for x in 0..<width {
                    across[y * width + x] = sum
                    sum += Int32(gray[y * width + min(x + radius + 1, width - 1)]) - Int32(gray[y * width + max(x - radius, 0)])
                }
            }
            for x in 0..<width {
                var sum: Int32 = 0
                for y in -radius...radius { sum += across[min(max(y, 0), height - 1) * width + x] }
                for y in 0..<height {
                    out[y * width + x] = UInt8(sum / (size * size))
                    sum += across[min(y + radius + 1, height - 1) * width + x] - across[max(y - radius, 0) * width + x]
                }
            }
            return out
        }
    }

    /// How the new page has to be moved to lie on the old one: Vision's registration, with the page's turn. It is tried both ways round, and it only counts if the pages then really differ less.
    private static func alignment(of moving: CGImage, onto fixed: CGImage) throws -> CGAffineTransform? {
        let target = moving
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: target)
        let handler = VNImageRequestHandler(cgImage: fixed)
        try VisionLimit.blocking(on: fixed) { try handler.perform([request]) }
        guard let matrix = (request.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform else { return nil }
        // Vision counts from the bottom left in pixels, as Core Graphics does.
        let forward = CGAffineTransform(a: CGFloat(matrix.columns.0.x), b: CGFloat(matrix.columns.0.y), c: CGFloat(matrix.columns.1.x), d: CGFloat(matrix.columns.1.y), tx: CGFloat(matrix.columns.2.x), ty: CGFloat(matrix.columns.2.y))
        let width = fixed.width, height = fixed.height
        let base = PixelPage(fixed, width: width, height: height).blurred(radius: 2)
        func cost(_ page: PixelPage?) -> Int {
            guard let page else { return .max }
            let other = page.blurred(radius: 2)
            return zip(base, other).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        let plain = cost(PixelPage(moving, width: width, height: height))
        let choices = [forward, forward.inverted()].map { ($0, cost(warped(moving, by: $0, width: width, height: height))) }
        guard let winner = choices.min(by: { $0.1 < $1.1 }), winner.1 < plain else { return nil }
        return winner.0
    }

    private static func warped(_ image: CGImage, by transform: CGAffineTransform, width: Int, height: Int) -> PixelPage? {
        var page = PixelPage(image, width: 1, height: 1)
        page.width = width
        page.height = height
        page.gray = [UInt8](repeating: 255, count: width * height)
        page.gray.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.concatenate(transform)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return page
    }

    /// Places where the two pictures differ. Each small square of the page counts as different when enough of its points do; squares close to each other become one place.
    static func regions(_ a: PixelPage, _ b: PixelPage, tolerant: Bool) -> [CGRect] {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0 else { return [] }
        let x = a.blurred(radius: tolerant ? 2 : 0), y = b.blurred(radius: tolerant ? 2 : 0)
        let threshold = tolerant ? 75 : 40
        let cell = 6
        let columns = a.width / cell + 1, rows = a.height / cell + 1
        var counts = [Int](repeating: 0, count: columns * rows)
        for row in 0..<a.height {
            for column in 0..<a.width where abs(Int(x[row * a.width + column]) - Int(y[row * a.width + column])) > threshold {
                counts[(row / cell) * columns + column / cell] += 1
            }
        }
        let needed = tolerant ? cell * cell / 3 : cell * cell / 10
        var marked = counts.map { $0 >= max(needed, 1) }
        // On a scan, one square alone is dust.
        if tolerant {
            let before = marked
            for row in 0..<rows {
                for column in 0..<columns where before[row * columns + column] {
                    var neighbours = 0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let r = row + dy, c = column + dx
                            if r >= 0, c >= 0, r < rows, c < columns, before[r * columns + c] { neighbours += 1 }
                        }
                    }
                    if neighbours < 2 { marked[row * columns + column] = false }
                }
            }
        }
        var seen = [Bool](repeating: false, count: marked.count)
        var result: [CGRect] = []
        let reach = 3
        for start in marked.indices where marked[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minC = columns, maxC = 0, minR = rows, maxR = 0
            while let index = stack.popLast() {
                let c = index % columns, r = index / columns
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for dy in -reach...reach {
                    for dx in -reach...reach {
                        let nr = r + dy, nc = c + dx
                        guard nr >= 0, nc >= 0, nr < rows, nc < columns else { continue }
                        let other = nr * columns + nc
                        if marked[other], !seen[other] {
                            seen[other] = true
                            stack.append(other)
                        }
                    }
                }
            }
            let w = CGFloat(a.width), h = CGFloat(a.height), size = CGFloat(cell)
            result.append(CGRect(x: CGFloat(minC) * size / w, y: CGFloat(minR) * size / h, width: CGFloat(maxC - minC + 1) * size / w, height: CGFloat(maxR - minR + 1) * size / h)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
        return result
    }

    /// The pictures of one pair of pages, for the window and the report.
    struct Pictures: @unchecked Sendable {
        var old: CGImage?
        var new: CGImage?
        /// Both on top of each other, faint; what only the old one has in red, what only the new one has in green.
        var overlay: CGImage?
    }

    func pictures(of pair: PagePair, dpi: CGFloat = visualDPI) throws -> Pictures {
        let old = try pair.old.map { try AnnotationSaver.picture(ofPage: $0, in: oldURL, dpi: dpi).image }
        let new = try pair.new.map { try AnnotationSaver.picture(ofPage: $0, in: newURL, dpi: dpi).image }
        var overlay: CGImage?
        if let old, let new {
            let a = PixelPage(old, width: old.width, height: old.height)
            let scale = dpi / Self.visualDPI
            let scaledAlignment = pair.alignment.map { CGAffineTransform(a: $0.a, b: $0.b, c: $0.c, d: $0.d, tx: $0.tx * scale, ty: $0.ty * scale) }
            let b = scaledAlignment.flatMap { Self.warped(new, by: $0, width: old.width, height: old.height) } ?? PixelPage(new, width: old.width, height: old.height)
            overlay = Self.overlay(a, b, tolerant: pair.isScan)
        }
        return Pictures(old: old, new: new, overlay: overlay)
    }

    static func overlay(_ a: PixelPage, _ b: PixelPage, tolerant: Bool) -> CGImage? {
        let width = a.width, height = a.height
        let x = a.blurred(radius: tolerant ? 1 : 0), y = b.blurred(radius: tolerant ? 1 : 0)
        let threshold = tolerant ? 75 : 40
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let at = index * 4
            let difference = Int(y[index]) - Int(x[index])
            if abs(difference) > threshold {
                if difference > 0 {
                    pixels[at] = 225; pixels[at + 1] = 35; pixels[at + 2] = 35
                } else {
                    pixels[at] = 20; pixels[at + 1] = 165; pixels[at + 2] = 60
                }
            } else {
                let faint = UInt8(255 - (255 - (Int(x[index]) + Int(y[index])) / 2) * 3 / 10)
                pixels[at] = faint; pixels[at + 1] = faint; pixels[at + 2] = faint
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
