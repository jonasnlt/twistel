import AVFoundation
import CoreGraphics
import Foundation

/// The check after redacting a video or bleeping a recording, like `RedactionCheck` for PDFs and `ImageRedactor` for pictures: before
/// the result is saved, it is read back. Of the original nothing may be left at the covered places and times, nor in another track,
/// subtitles, a cover picture, chapters or the metadata. Any finding means nothing is saved. Messages name the kind of problem, never
/// content.
enum MediaRedactionCheck {
    #if DEBUG
    /// Tests: a finding as if the check had found something, to see that nothing is saved.
    nonisolated(unsafe) static var simulatedProblem: String?
    #endif

    /// Throws the readable error when `problems` found something.
    static func requireNothing(_ problems: [String], what: String) throws {
        #if DEBUG
        let problems = problems + (simulatedProblem.map { [$0] } ?? [])
        #endif
        guard !problems.isEmpty else { return }
        DiagnosticLog.log("\(what) check failed: \(problems)")
        throw AppError.invalidInput(tr("The check found that something of the original could still be seen or heard, so nothing was saved: \(problems.joined(separator: "; ")).",
                                       "Die Prüfung hat gefunden, dass vom Original noch etwas zu sehen oder zu hören ist, deshalb wurde nichts gesichert: \(problems.joined(separator: "; "))."))
    }

    // MARK: Video

    /// `redactions`: places in `displaySize` (origin top left) with their times. `filled`: every place was filled with one colour
    /// (ffmpeg draws blurring and pixelating as grey boxes).
    static func videoProblems(original: URL, output: URL, redactions: [Redaction], displaySize: CGSize, filled: Bool) async -> [String] {
        var problems = await containerProblems(original: original, output: output, video: 1, audioAtMost: await trackCount(original, .audio))
        let asset = AVURLAsset(url: output)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return problems + [tr("the result has no picture to check", "das Ergebnis hat kein Bild, das sich prüfen ließe")]
        }
        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 30)
        let frame = 1 / (fps > 0 ? fps : 30)
        var uncovered = false, detail = false, face = false
        for redaction in redactions {
            for time in sampleTimes(start: max(0, redaction.start), end: min(redaction.end, duration), frame: frame) {
                guard let shown = try? await VideoOps.snapshot(output, at: time) else {
                    problems.append(tr("a frame of the result cannot be read", "ein Bild des Ergebnisses lässt sich nicht lesen"))
                    return problems
                }
                let place = scaled(redaction.rect, from: displaySize, to: CGSize(width: shown.width, height: shown.height))
                if filled || redaction.style == .solid {
                    if !isUniform(shown, in: place) { uncovered = true }
                    continue
                }
                guard let before = try? await VideoOps.snapshot(original, at: time) else { continue }
                let placeBefore = scaled(redaction.rect, from: displaySize, to: CGSize(width: before.width, height: before.height))
                if fineDetailKept(before, placeBefore, shown, place) { detail = true }
                if await faceStays(before, placeBefore, shown, place) { face = true }
            }
        }
        if uncovered { problems.append(tr("a covered place is not covered in every frame", "eine abgedeckte Stelle ist nicht in jedem Bild abgedeckt")) }
        if detail { problems.append(tr("a blurred or pixelated place still shows the original's fine detail", "eine weichgezeichnete oder verpixelte Stelle zeigt noch Einzelheiten des Originals")) }
        if face { problems.append(tr("a blurred or pixelated face can still be recognized; use Solid", "ein weichgezeichnetes oder verpixeltes Gesicht ist noch erkennbar; wähle „Deckend“")) }
        return problems
    }

    /// Up to five times inside the range, a frame and a half away from its ends (where a frame may belong to either side).
    static func sampleTimes(start: Double, end: Double, frame: Double) -> [Double] {
        guard end > start else { return [] }
        let first = start + 1.5 * frame, last = end - 1.5 * frame
        guard last > first else { return [(start + end) / 2] }
        return (0...4).map { first + (last - first) * Double($0) / 4 }
    }

    static func scaled(_ rect: CGRect, from size: CGSize, to target: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let sx = target.width / size.width, sy = target.height / size.height
        return CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy)
            .intersection(CGRect(origin: .zero, size: target))
    }

    /// One colour inside the place (a few pixels in from its edge, where compression blurs), within what video coding leaves.
    static func isUniform(_ image: CGImage, in place: CGRect) -> Bool {
        guard let area = Pixels(image, place.insetBy(dx: max(4, place.width * 0.04), dy: max(4, place.height * 0.04))) else { return true }
        let middle = area.median
        return area.all { pixel in (0..<3).allSatisfy { abs(Int(pixel[$0]) - Int(middle[$0])) <= 40 } }
    }

    /// Whether the fine detail of the original (what is left after taking out the smooth parts) is still in the result: a
    /// correlation of the two above 0.5. A place that had no fine detail has nothing to give away.
    static func fineDetailKept(_ before: CGImage, _ placeBefore: CGRect, _ after: CGImage, _ placeAfter: CGRect) -> Bool {
        let side = 96
        guard let a = Pixels(before, placeBefore.insetBy(dx: 3, dy: 3), side: side)?.highPass(),
              let b = Pixels(after, placeAfter.insetBy(dx: 3, dy: 3), side: side)?.highPass() else { return false }
        let energy = a.reduce(0) { $0 + $1 * $1 } / Double(a.count)
        guard energy > 4 else { return false }
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let norm = sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })
        return norm > 0 && dot / norm > 0.5
    }

    /// A face the original showed at the place is still found there.
    static func faceStays(_ before: CGImage, _ placeBefore: CGRect, _ after: CGImage, _ placeAfter: CGRect) async -> Bool {
        func overlapping(_ image: CGImage, _ place: CGRect) async -> Bool {
            let size = CGSize(width: image.width, height: image.height)
            guard let faces = try? await RedactionFinder.faces(in: image) else { return false }
            return faces.contains { face in
                let shown = CGRect(x: face.minX * size.width, y: face.minY * size.height, width: face.width * size.width, height: face.height * size.height)
                return TextRecognizer.overlap(shown, place) > 0.5
            }
        }
        guard await overlapping(before, placeBefore) else { return false }
        return await overlapping(after, placeAfter)
    }

    // MARK: Audio

    /// `ranges` in seconds; `frequency`: the bleep tone (nil: silence). In each range only the tone may be heard, in every channel.
    static func audioProblems(original: URL, output: URL, ranges: [AudioOps.BleepRange], frequency: Double?) async -> [String] {
        var problems = await containerProblems(original: original, output: output, video: 0, audioAtMost: 1)
        var heard = false, unreadable = false
        for range in ranges where range.end > range.start {
            // Coding spreads a sound by some 50 ms; the middle of short ranges is checked.
            let inset = range.end - range.start > 0.3 ? 0.08 : max(0, (range.end - range.start - 0.08) / 2)
            guard let channels = await samples(output, from: range.start + inset, to: range.end - inset) else { unreadable = true; continue }
            for (signal, rate) in channels where residual(signal, rate: rate, frequency: frequency) > 0.01 { heard = true }
        }
        if unreadable { problems.append(tr("the result's sound cannot be read", "der Ton des Ergebnisses lässt sich nicht lesen")) }
        if heard { problems.append(tr("in a bleeped range something other than the tone can still be heard", "in einem zensierten Bereich ist noch etwas anderes als der Ton zu hören")) }
        return problems
    }

    /// What is left of `signal` after taking out the best-fitting tone (RMS, 0…1; 0.01 is -40 dBFS). Silence and the pure tone are 0.
    static func residual(_ signal: [Float], rate: Double, frequency: Double?) -> Double {
        guard !signal.isEmpty else { return 0 }
        var residual = signal.map(Double.init)
        if let frequency, frequency > 0 {
            var ss = 0.0, cc = 0.0, sc = 0.0, xs = 0.0, xc = 0.0
            for (n, x) in residual.enumerated() {
                let phase = 2 * Double.pi * frequency * Double(n) / rate
                let s = sin(phase), c = cos(phase)
                ss += s * s; cc += c * c; sc += s * c; xs += x * s; xc += x * c
            }
            let det = ss * cc - sc * sc
            if abs(det) > 1e-9 {
                let a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det
                for n in residual.indices {
                    let phase = 2 * Double.pi * frequency * Double(n) / rate
                    residual[n] -= a * sin(phase) + b * cos(phase)
                }
            }
        }
        return sqrt(residual.reduce(0) { $0 + $1 * $1 } / Double(residual.count))
    }

    /// Each channel of `url` between the two times, as samples. Apple reads most formats; the others (OGG, Opus, WMA) through ffmpeg.
    static func samples(_ url: URL, from start: Double, to end: Double) async -> [([Float], Double)]? {
        if let read = read(url, from: start, to: end) { return read }
        guard FFmpeg.isAvailable else { return nil }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        guard (try? await FFmpeg.run(["-i", url.path, "-c:a", "pcm_f32le", wav.path], purpose: tr("Checking the sound", "Ton prüfen"), privacy: false)) != nil else { return nil }
        return read(wav, from: start, to: end)
    }

    private static func read(_ url: URL, from start: Double, to end: Double) -> [([Float], Double)]? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, start) * rate)
        let count = AVAudioFrameCount(max(0, min(end * rate, Double(file.length)) - Double(first)))
        guard count > 0, first < file.length, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        file.framePosition = first
        guard (try? file.read(into: buffer, frameCount: count)) != nil, let data = buffer.floatChannelData else { return nil }
        return (0..<Int(file.processingFormat.channelCount)).map { (Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))), rate) }
    }

    // MARK: Tracks, subtitles, cover pictures, chapters, metadata

    /// The result has `video` picture tracks and at most `audioAtMost` sound tracks, nothing else (no subtitles, captions, timecode or
    /// data), no cover picture, no chapters, and no metadata of its own (technical entries aside; a recording date only if it is not
    /// the original's).
    static func containerProblems(original: URL, output: URL, video: Int, audioAtMost: Int) async -> [String] {
        var problems: [String] = []
        let asset = AVURLAsset(url: output)
        if let tracks = try? await asset.load(.tracks) {
            let videoTracks = tracks.filter { $0.mediaType == .video }.count
            let audioTracks = tracks.filter { $0.mediaType == .audio }.count
            if videoTracks > video { problems.append(tr("the result has another picture track", "das Ergebnis hat eine weitere Bildspur")) }
            if audioTracks > audioAtMost { problems.append(tr("the result has another sound track", "das Ergebnis hat eine weitere Tonspur")) }
            if tracks.contains(where: { ![AVMediaType.video, .audio].contains($0.mediaType) }) {
                problems.append(tr("the result has subtitles or another track besides picture and sound", "das Ergebnis hat Untertitel oder eine weitere Spur neben Bild und Ton"))
            }
        }
        if let items = try? await asset.load(.metadata) {
            var named = false
            for item in items {
                if item.commonKey == .commonKeyArtwork { named = true; continue }
                if let text = try? await item.load(.stringValue), !text.trimmingCharacters(in: .whitespaces).isEmpty { named = true }
                else if (try? await item.load(.dataValue))?.isEmpty == false { named = true }
            }
            if named { problems.append(tr("the result still has metadata", "das Ergebnis enthält noch Metadaten")) }
        }
        if let locales = try? await asset.load(.availableChapterLocales), !locales.isEmpty {
            problems.append(tr("the result still has chapters", "das Ergebnis enthält noch Kapitel"))
        }
        // ffprobe sees what AVFoundation leaves out: cover pictures as a stream, data streams, tags of other containers.
        if let found = await probe(output) {
            let streams = (found["streams"] as? [[String: Any]]) ?? []
            if streams.contains(where: { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1 }) {
                problems.append(tr("the result still has a cover picture", "das Ergebnis enthält noch ein Titelbild"))
            }
            let kinds = streams.compactMap { $0["codec_type"] as? String }
            if kinds.contains(where: { !["video", "audio"].contains($0) }) || kinds.filter({ $0 == "video" }).count > video {
                problems.append(tr("the result has subtitles or another stream", "das Ergebnis hat Untertitel oder einen weiteren Datenstrom"))
            }
            if !((found["chapters"] as? [Any]) ?? []).isEmpty { problems.append(tr("the result still has chapters", "das Ergebnis enthält noch Kapitel")) }
            let originalDates = Set(tags(of: await probe(original) ?? [:]).filter { $0.key == "creation_time" }.map(\.value))
            let left = tags(of: found).filter { tag in
                guard !tag.value.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                if tag.key == "creation_time" { return originalDates.contains(tag.value) }
                return !technicalTags.contains(tag.key)
            }
            if !left.isEmpty { problems.append(tr("the result still has metadata", "das Ergebnis enthält noch Metadaten")) }
        }
        return Array(NSOrderedSet(array: problems)) as? [String] ?? problems
    }

    /// Entries the container itself writes, which say nothing about the recording.
    static let technicalTags: Set<String> = ["major_brand", "minor_version", "compatible_brands", "handler_name", "vendor_id", "language", "encoder"]

    static func tags(of probe: [String: Any]) -> [(key: String, value: String)] {
        var all: [(String, String)] = []
        let blocks = [probe["format"] as? [String: Any]] + ((probe["streams"] as? [[String: Any]]) ?? []).map(Optional.some)
        for block in blocks.compactMap({ $0 }) {
            for (key, value) in (block["tags"] as? [String: Any]) ?? [:] { all.append((key.lowercased(), "\(value)")) }
        }
        return all
    }

    static func probe(_ url: URL) async -> [String: Any]? {
        guard let ffprobe = FFmpeg.probePath else { return nil }
        guard let result = try? await Shell.run(ffprobe, ["-v", "error", "-show_entries", "format_tags:stream=codec_type:stream_tags:stream_disposition=attached_pic:chapter=id",
                                                          "-of", "json", url.path], limit: .quick),
              let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func trackCount(_ url: URL, _ type: AVMediaType) async -> Int {
        if let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: type), !tracks.isEmpty { return tracks.count }
        let streams = ((await probe(url))?["streams"] as? [[String: Any]]) ?? []
        return streams.filter { $0["codec_type"] as? String == (type == .audio ? "audio" : "video") }.count
    }
}

/// The pixels of a place of a picture, as RGBA8 in sRGB; `side`: drawn at this size (for comparing two pictures of different sizes).
private struct Pixels {
    let width: Int, height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage, _ place: CGRect, side: Int? = nil) {
        let place = place.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard place.width >= 2, place.height >= 2, let cropped = image.cropping(to: place) else { return nil }
        let w = side ?? Int(place.width), h = side ?? Int(place.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w; height = h
        bytes = buffer
    }

    func all(_ test: ([UInt8]) -> Bool) -> Bool {
        stride(from: 0, to: bytes.count, by: 4).allSatisfy { test(Array(bytes[$0..<$0 + 3])) }
    }

    var median: [UInt8] {
        (0..<3).map { channel in
            let values = stride(from: channel, to: bytes.count, by: 4).map { bytes[$0] }.sorted()
            return values[values.count / 2]
        }
    }

    /// Brightness minus the mean of its 3 × 3 neighbourhood: the fine detail.
    func highPass() -> [Double] {
        let light = stride(from: 0, to: bytes.count, by: 4).map { 0.299 * Double(bytes[$0]) + 0.587 * Double(bytes[$0 + 1]) + 0.114 * Double(bytes[$0 + 2]) }
        var result: [Double] = []
        result.reserveCapacity(light.count)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum = 0.0
                for dy in -1...1 { for dx in -1...1 { sum += light[(y + dy) * width + x + dx] } }
                result.append(light[y * width + x] - sum / 9)
            }
        }
        return result
    }
}
