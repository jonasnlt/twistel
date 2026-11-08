import Foundation

/// Subtitles from whisper's words with their times. At most two lines of 42 characters (the usual rule for Latin letters) and 7 seconds
/// on screen, at least a second if there is room. A pause in the speech always starts a new subtitle; long stretches are divided evenly,
/// preferably at the end of a sentence or after a comma, so that no word is left alone at the end.
enum SubtitleMaker {
    static let lineLength = 42
    static let longest = 7.0
    static let shortest = 1.0
    /// A gap this long (seconds) is a pause in the speech.
    static let pause = 0.5

    /// `words`: one cue per word, as whisper writes them with "-ml 1 -sow".
    static func cues(fromWords words: [SubtitleCue]) -> [SubtitleCue] {
        let spoken = spoken(words)
        var stretches: [[SubtitleCue]] = []
        for word in spoken {
            if let last = stretches.last?.last, word.start - last.end < pause {
                stretches[stretches.count - 1].append(word)
            } else {
                stretches.append([word])
            }
        }
        var cues = stretches.flatMap(divided).map { part in
            SubtitleCue(start: part[0].start, end: part[part.count - 1].end, text: lines(part.map(\.text)))
        }
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].start : Double.infinity
            cues[index].end = min(max(cues[index].end, cues[index].start + shortest), next)
        }
        return cues
    }

    /// The words alone: whisper's marks for the start of a stretch and for timestamps are not words.
    static func spoken(_ words: [SubtitleCue]) -> [SubtitleCue] {
        words.compactMap { word -> SubtitleCue? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text.hasPrefix("[_") ? nil : SubtitleCue(start: word.start, end: word.end, text: text)
        }
    }

    private static func length(_ words: ArraySlice<SubtitleCue>) -> Int { words.map(\.text.count).reduce(0, +) + max(0, words.count - 1) }

    /// How good it is to end a line or subtitle after this word.
    private static func weight(_ word: String, sentence: Int, comma: Int) -> Int {
        guard let last = word.last(where: { !"\"”“'»)".contains($0) }) else { return 0 }
        if ".?!…".contains(last) { return sentence }
        return ",;:".contains(last) ? comma : 0
    }

    /// The words of one stretch without a pause, as subtitles of about the same length.
    private static func divided(_ stretch: [SubtitleCue]) -> [[SubtitleCue]] {
        var rest = stretch[...], parts: [[SubtitleCue]] = []
        let most = lineLength * 2
        while let first = rest.first, let last = rest.last {
            let characters = length(rest), seconds = last.end - first.start
            let count = max(Int((Double(characters) / Double(most)).rounded(.up)), Int((seconds / longest).rounded(.up)))
            guard count > 1, rest.count > 1 else {
                parts.append(Array(rest))
                break
            }
            let target = characters / count
            // The place nearest the target that fits; an end of a sentence may be some way off, a comma less.
            var best: (place: Int, score: Int)?
            for place in rest.indices.dropFirst() {
                let left = rest[rest.startIndex..<place]
                guard length(left) <= most, rest[place - 1].end - first.start <= longest else { continue }
                let score = abs(length(left) - target) - weight(rest[place - 1].text, sentence: 30, comma: 12)
                if best == nil || score < best!.score { best = (place, score) }
            }
            let place = best?.place ?? rest.startIndex + 1
            parts.append(Array(rest[rest.startIndex..<place]))
            rest = rest[place...]
        }
        return parts
    }

    /// The text of one subtitle: one line if it fits, otherwise two of about the same length, broken after a punctuation mark if that is near.
    private static func lines(_ words: [String]) -> String {
        let text = words.joined(separator: " ")
        guard text.count > lineLength, words.count > 1 else { return text }
        var best: (place: Int, score: Int)?
        for place in 1..<words.count {
            let top = words[..<place].joined(separator: " ").count, bottom = words[place...].joined(separator: " ").count
            let tooLong = max(0, max(top, bottom) - lineLength) * 100
            let score = abs(top - bottom) + tooLong - weight(words[place - 1], sentence: 16, comma: 8)
            if best == nil || score < best!.score { best = (place, score) }
        }
        let place = best?.place ?? 1
        return words[..<place].joined(separator: " ") + "\n" + words[place...].joined(separator: " ")
    }
}
