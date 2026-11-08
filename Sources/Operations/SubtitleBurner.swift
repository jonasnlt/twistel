import AVFoundation
import AppKit
import CoreImage
import CoreText
import Foundation

/// Writes subtitles into the picture of a video, for places that take no .srt file, such as Reels. Goes the way of the video presets: each picture through Core Image, H.264, sound as AAC.
enum SubtitleBurner {
    /// What is behind the writing.
    enum Style: String, CaseIterable, Identifiable, Sendable {
        case outline, box, none
        var id: String { rawValue }
        var title: String {
            switch self {
            case .outline: return tr("Outline", "Kontur")
            case .box: return tr("Box", "Kasten")
            case .none: return tr("None", "Ohne")
            }
        }
    }

    enum Position: String, CaseIterable, Identifiable, Sendable {
        case bottom, middle, top
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bottom: return tr("Bottom", "Unten")
            case .middle: return tr("Middle", "Mitte")
            case .top: return tr("Top", "Oben")
            }
        }
    }

    /// The whole subtitle, the subtitle with the word being spoken in the second colour, or only that word, larger (as on Reels).
    enum Words: String, CaseIterable, Identifiable, Sendable {
        case whole, highlight, single
        var id: String { rawValue }
        var title: String {
            switch self {
            case .whole: return tr("Whole", "Ganz")
            case .highlight: return tr("Highlight", "Hervorheben")
            case .single: return tr("One word", "Ein Wort")
            }
        }
    }

    enum Size: String, CaseIterable, Identifiable, Sendable {
        case small, medium, large
        var id: String { rawValue }
        var title: String {
            switch self {
            case .small: return tr("Small", "Klein")
            case .medium: return tr("Medium", "Mittel")
            case .large: return tr("Large", "Groß")
            }
        }
        /// Of the short side of the picture: so a Reel and a wide video look right alike.
        var share: CGFloat {
            switch self {
            case .small: return 0.042
            case .medium: return 0.052
            case .large: return 0.065
            }
        }
    }

    struct Options: Equatable, Sendable {
        var style = Style.outline
        var size = Size.medium
        var position = Position.bottom
        var color = MarkColor(red: 1, green: 1, blue: 1)
        /// The word being spoken, when words are highlighted.
        var highlight = MarkColor(red: 1, green: 0.84, blue: 0)
        var words = Words.whole
    }

    /// One word of a subtitle and when it is spoken (seconds).
    struct TimedWord: Equatable, Sendable {
        var text: String
        var start: Double
    }

    /// A single word is set this much larger than a whole subtitle.
    static let singleScale: CGFloat = 1.6

    static func cues(in url: URL) throws -> [SubtitleCue] {
        let text = try TextFile.read(url)
        let cues = SubtitleParser.parse(text, hint: FileFormat.detect(url) ?? .srt).filter { $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cues.isEmpty else { throw AppError.invalidInput(tr("No subtitles found in \(url.lastPathComponent).", "In \(url.lastPathComponent) wurden keine Untertitel gefunden.")) }
        return cues.sorted { $0.start < $1.start }
    }

    /// The subtitle file next to the video, of the same name.
    static func matchingFile(for video: URL) -> URL? {
        let base = video.deletingPathExtension()
        return ["srt", "vtt"].map { base.appendingPathExtension($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Lines as written if they fit; a subtitle written for a wide picture is set anew for a narrow one.
    static func lines(of text: String, fontSize: CGFloat, width: CGFloat) -> [String] {
        let font = MarkPainter.font(size: fontSize, bold: true)
        func wide(_ line: String) -> CGFloat {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), nil, nil, nil)
        }
        let written = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if written.allSatisfy({ wide($0) <= width }) { return written }
        var result: [String] = []
        var line = ""
        for word in written.joined(separator: " ").split(separator: " ").map(String.init) {
            let longer = line.isEmpty ? word : line + " " + word
            if wide(longer) <= width || line.isEmpty {
                line = longer
            } else {
                result.append(line)
                line = word
            }
        }
        if !line.isEmpty { result.append(line) }
        // The last line alone with one word looks lost: lines of about the same length read better.
        return balanced(result, wide: wide, width: width)
    }

    private static func balanced(_ lines: [String], wide: (String) -> CGFloat, width: CGFloat) -> [String] {
        guard lines.count == 2 else { return lines }
        var first = lines[0].split(separator: " ").map(String.init), second = lines[1].split(separator: " ").map(String.init)
        while first.count > 1 {
            let nextSecond = [first[first.count - 1]] + second
            let a = first.dropLast().joined(separator: " "), b = nextSecond.joined(separator: " ")
            guard wide(b) <= width, abs(wide(a) - wide(b)) < abs(wide(first.joined(separator: " ")) - wide(second.joined(separator: " "))) else { break }
            first.removeLast()
            second = nextSecond
        }
        return [first.joined(separator: " "), second.joined(separator: " ")]
    }

    /// How far above the lower edge: in a tall video more, because Reels and Stories lay their buttons and captions over the lowest part.
    static func bottomMargin(pictureSize: CGSize) -> CGFloat {
        pictureSize.height > pictureSize.width ? pictureSize.height * 0.2 : pictureSize.height * 0.07
    }

    /// How far below the upper edge: in a tall video below the name and the title Reels and Stories show there.
    static func topMargin(pictureSize: CGSize) -> CGFloat {
        pictureSize.height > pictureSize.width ? pictureSize.height * 0.14 : pictureSize.height * 0.07
    }

    /// Black edge and box behind light writing, white behind dark writing.
    static func backing(for color: MarkColor) -> CGFloat {
        0.3 * color.red + 0.59 * color.green + 0.11 * color.blue < 0.45 ? 1 : 0
    }

    /// One subtitle as a picture as wide as the video, transparent around the writing; its lower edge at the place it belongs, in Core Image's coordinates.
    /// `lit`: the word (counted over the whole subtitle) in the highlight colour. `scale`: larger writing, for a single word.
    static func picture(of text: String, pictureSize: CGSize, options: Options, lit: Int? = nil, scale: CGFloat = 1) -> (image: CGImage, y: CGFloat)? {
        let fontSize = (min(pictureSize.width, pictureSize.height) * options.size.share * scale).rounded()
        let margin = pictureSize.width * 0.05
        let broken = lines(of: text, fontSize: fontSize, width: pictureSize.width - margin * 2)
        guard !broken.isEmpty else { return nil }
        let font = MarkPainter.font(size: fontSize, bold: true)
        let leading = (fontSize * 1.28).rounded()
        let edge = max(2, (fontSize * 0.09).rounded())
        let padding = (fontSize * 0.28).rounded()
        let height = Int(CGFloat(broken.count) * leading + padding * 2 + edge * 2)
        let width = Int(pictureSize.width)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let back = backing(for: options.color)
        var counted = 0
        for (index, line) in broken.enumerated() {
            let baseline = CGFloat(height) - padding - edge - leading * CGFloat(index + 1) + (leading - fontSize) * 0.75
            let words = line.split(separator: " ").map(String.init)
            // The line in its colours: the word being spoken in the second one.
            let written = NSMutableAttributedString()
            for (place, word) in words.enumerated() {
                if place > 0 { written.append(NSAttributedString(string: " ", attributes: [.font: font, .foregroundColor: options.color.cgColor()])) }
                let colour = lit == counted + place ? options.highlight : options.color
                written.append(NSAttributedString(string: word, attributes: [.font: font, .foregroundColor: colour.cgColor()]))
            }
            counted += words.count
            let plain = CTLineCreateWithAttributedString(written)
            let wide = CTLineGetTypographicBounds(plain, nil, nil, nil)
            let x = (pictureSize.width - wide) / 2
            switch options.style {
            case .box:
                context.setFillColor(CGColor(gray: back, alpha: 0.72))
                let band = CGRect(x: x - padding, y: CGFloat(height) - padding - edge - leading * CGFloat(index + 1), width: wide + padding * 2, height: leading)
                context.fill(band)
            case .outline:
                let dark = CGColor(gray: back, alpha: 0.9)
                context.setLineJoin(.round)
                context.setLineWidth(edge * 2)
                context.setTextDrawingMode(.stroke)
                context.setStrokeColor(dark)
                context.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: dark, kCTStrokeWidthAttributeName as NSAttributedString.Key: edge * 2 / fontSize * 100, kCTStrokeColorAttributeName as NSAttributedString.Key: dark])), context)
                context.setTextDrawingMode(.fill)
            case .none:
                break
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(plain, context)
        }
        guard let image = context.makeImage() else { return nil }
        let y: CGFloat
        switch options.position {
        case .bottom: y = bottomMargin(pictureSize: pictureSize)
        case .middle: y = ((pictureSize.height - CGFloat(height)) / 2).rounded()
        case .top: y = pictureSize.height - topMargin(pictureSize: pictureSize) - CGFloat(height)
        }
        return (image, y)
    }

    /// The words of each subtitle with the times whisper heard them. The subtitle's own words count (they may have been corrected): whisper's words near the subtitle's time
    /// are matched to them in order (the longest common run of words, letters only, any case); a word not heard gets a time between its neighbours by its length.
    /// No word heard at all: the subtitle's time shared out by the length of its words.
    static func timedWords(_ cues: [SubtitleCue], spoken: [SubtitleCue]) -> [[TimedWord]] {
        func key(_ word: String) -> String {
            String(word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        return cues.map { cue in
            let words = cue.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { return [] }
            let heard = spoken.filter { ($0.start + $0.end) / 2 >= cue.start - 0.5 && ($0.start + $0.end) / 2 <= cue.end + 0.5 }
            let mine = words.map(key), theirs = heard.map { key($0.text) }
            // Longest common run, then back along it.
            var table = [[Int]](repeating: [Int](repeating: 0, count: theirs.count + 1), count: mine.count + 1)
            for i in stride(from: mine.count - 1, through: 0, by: -1) {
                for j in stride(from: theirs.count - 1, through: 0, by: -1) {
                    table[i][j] = !mine[i].isEmpty && mine[i] == theirs[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var times = [Double?](repeating: nil, count: words.count)
            var i = 0, j = 0
            while i < mine.count, j < theirs.count {
                if !mine[i].isEmpty, mine[i] == theirs[j] {
                    times[i] = min(max(heard[j].start, cue.start), cue.end)
                    i += 1; j += 1
                } else if table[i + 1][j] >= table[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
            // The rest between the words with a time, by their length; the first word not before the subtitle.
            var index = 0
            while index < words.count {
                guard times[index] == nil else { index += 1; continue }
                var end = index
                while end < words.count, times[end] == nil { end += 1 }
                let from = index > 0 ? times[index - 1]! : cue.start
                let to = end < words.count ? times[end]! : cue.end
                let lengths = words[index..<end].map { Double(max(1, $0.count)) }
                let total = lengths.reduce(0, +) + (index > 0 ? Double(max(1, words[index - 1].count)) : 0)
                var at = index > 0 ? Double(max(1, words[index - 1].count)) : 0
                for (offset, length) in lengths.enumerated() {
                    times[index + offset] = from + (to - from) * at / max(total, 1)
                    at += length
                }
                index = end
            }
            var result: [TimedWord] = []
            for (word, time) in zip(words, times) {
                result.append(TimedWord(text: word, start: max(time ?? cue.start, result.last?.start ?? cue.start)))
            }
            return result
        }
    }

    /// The subtitle of a moment. Pictures of the video arrive on Apple's threads, in order for the most part: one subtitle is kept ready.
    final class Overlay: @unchecked Sendable {
        private let cues: [SubtitleCue]
        private let words: [[TimedWord]]
        private let pictureSize: CGSize
        private let options: Options
        private let lock = NSLock()
        private var ready: (index: Int, word: Int?, image: CIImage)?

        /// `words`: from `timedWords`, needed when words are highlighted or shown one by one.
        init(cues: [SubtitleCue], words: [[TimedWord]] = [], pictureSize: CGSize, options: Options) {
            self.cues = cues
            self.words = words
            self.pictureSize = pictureSize
            self.options = options
        }

        /// The word being spoken: the last one begun.
        func word(in index: Int, at seconds: Double) -> Int? {
            guard options.words != .whole, words.indices.contains(index) else { return nil }
            return words[index].lastIndex { $0.start <= seconds }
        }

        func apply(to frame: CIImage, at seconds: Double) -> CIImage {
            guard let index = cues.firstIndex(where: { seconds >= $0.start && seconds < $0.end }) else { return frame }
            let word = word(in: index, at: seconds)
            // One word at a time: nothing before the first is spoken.
            if options.words == .single, word == nil { return frame }
            let image: CIImage? = lock.withLock {
                if let ready, ready.index == index, ready.word == word { return ready.image }
                let made: (image: CGImage, y: CGFloat)?
                switch options.words {
                case .single where word != nil: made = SubtitleBurner.picture(of: words[index][word!].text, pictureSize: pictureSize, options: options, scale: SubtitleBurner.singleScale)
                case .highlight: made = SubtitleBurner.picture(of: cues[index].text, pictureSize: pictureSize, options: options, lit: word)
                default: made = SubtitleBurner.picture(of: cues[index].text, pictureSize: pictureSize, options: options)
                }
                guard let made else { return nil }
                let placed = CIImage(cgImage: made.image).transformed(by: CGAffineTransform(translationX: 0, y: made.y))
                ready = (index, word, placed)
                return placed
            }
            return image?.composited(over: frame).cropped(to: frame.extent) ?? frame
        }
    }

    /// As much data for the picture as the original, so that it does not get worse.
    static func bitrate(source: Double, size: CGSize) -> Int {
        let least = size.width * size.height * 30 * 0.1
        return Int(max(source * 1.1, least))
    }

    /// `spoken`: whisper's words, when the window already has them; otherwise heard here when words are highlighted or shown one by one.
    static func save(_ url: URL, subtitles: URL, options: Options, spoken: [SubtitleCue]? = nil, language: Transcriber.Language = .german, to destination: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let cues = try cues(in: subtitles)
        guard await MediaInfo.isNativelyReadable(url) else { throw AppError.invalidInput(tr("\(url.lastPathComponent) is in a format Apple's video tools cannot read. Convert it to MP4 first, then burn in the subtitles.", "\(url.lastPathComponent) hat ein Format, das Apples Videowerkzeuge nicht lesen können. Wandle es zuerst in MP4 um und brenn dann die Untertitel ein.")) }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AppError.invalidInput(tr("No video track found.", "Keine Videospur gefunden.")) }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let box = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(box.width), height: abs(box.height))
        // H.264 needs even sizes.
        let even = CGSize(width: (size.width / 2).rounded(.down) * 2, height: (size.height / 2).rounded(.down) * 2)
        let rate = Double(try await track.load(.nominalFrameRate))
        let source = Double(try await track.load(.estimatedDataRate))
        var words: [[TimedWord]] = []
        var share = 0.0
        if options.words != .whole {
            if let spoken {
                words = timedWords(cues, spoken: spoken)
            } else if Transcriber.problems(whisper: Transcriber.whisperPath, modelsFolder: Transcriber.modelsFolder).isEmpty {
                // Listening takes about as long as writing the video: the first half of the bar.
                share = 0.5
                words = timedWords(cues, spoken: try await Transcriber.words(of: url, language: language) { progress($0 * 0.5) })
            } else {
                words = timedWords(cues, spoken: [])
            }
        }
        let overlay = Overlay(cues: cues, words: words, pictureSize: size, options: options)
        try await VideoPresets.write(url, crop: nil, output: even, frameRateLimit: rate > 0 ? rate : 30, videoBitrate: bitrate(source: source, size: even), audioBitrate: 160_000, overlay: { frame, time in
            overlay.apply(to: frame, at: CMTimeGetSeconds(time))
        }, to: destination, progress: { progress(share + $0 * (1 - share)) })
    }
}
