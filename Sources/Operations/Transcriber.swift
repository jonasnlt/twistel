import Foundation

/// Speech to text with whisper-cli (whisper.cpp), called as a separate program: German, large-v3 model (or large-v3-turbo),
/// silent parts skipped by the Silero voice activity model. The text lands as a .txt file, or as subtitles (.srt, .vtt).
enum Transcriber {
    static let modelName = "ggml-large-v3.bin"
    /// The smaller model for Macs with 8 GB (about half the memory, a little less exact). Used when `modelName` is not there.
    static let smallerModelName = "ggml-large-v3-turbo.bin"
    static let silenceModelName = "ggml-silero-v5.1.2.bin"
    /// The language spoken in the recording; whisper can also detect it.
    enum Language: String, CaseIterable, Identifiable {
        case german = "de"
        case english = "en"
        case automatic = "auto"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .german: return tr("German", "Deutsch")
            case .english: return tr("English", "Englisch")
            case .automatic: return tr("Detect", "Erkennen")
            }
        }
    }

    enum Output: String, CaseIterable, Identifiable {
        case text, srt, vtt

        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: return tr("Text", "Text")
            case .srt: return tr("Subtitles SRT", "Untertitel SRT")
            case .vtt: return tr("Subtitles VTT", "Untertitel VTT")
            }
        }
        var format: FileFormat {
            switch self {
            case .text: return .txt
            case .srt: return .srt
            case .vtt: return .vtt
            }
        }
    }

    static var modelsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("whisper-models", isDirectory: true) }
    static var whisperPath: String? { Shell.which("whisper-cli") }

    /// Formats whisper-cli reads by itself; everything else (video, M4A, …) is first turned into WAV with ffmpeg.
    static let directlyReadable: Set<FileFormat> = [.wav, .mp3, .flac, .ogg]

    /// A large model takes about 3 GB of memory, so transcriptions run one after another.
    private static let oneAtATime = AsyncSemaphore(limit: 1)

    enum Problem: Equatable {
        case whisperMissing
        case modelMissing(String)
    }

    /// The speech model to use: large-v3 when it is there, else large-v3-turbo; nil when neither is.
    static func model(in modelsFolder: URL, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL? {
        [modelName, smallerModelName].lazy.map { modelsFolder.appendingPathComponent($0) }.first { fileExists($0.path) }
    }

    static func problems(whisper: String?, modelsFolder: URL, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> [Problem] {
        var problems: [Problem] = []
        if whisper == nil { problems.append(.whisperMissing) }
        if model(in: modelsFolder, fileExists: fileExists) == nil { problems.append(.modelMissing(modelName)) }
        if !fileExists(modelsFolder.appendingPathComponent(silenceModelName).path) { problems.append(.modelMissing(silenceModelName)) }
        return problems
    }

    /// A message that says what is missing and how to fix it; nil when everything is there.
    static func hint(for problems: [Problem], modelsFolder: URL) -> String? {
        guard !problems.isEmpty else { return nil }
        var parts: [String] = []
        if problems.contains(.whisperMissing) {
            parts.append(tr("Transcription needs whisper-cli. To install it, run \u{201C}brew install whisper-cpp\u{201D} in Terminal.", "Zum Transkribieren brauchst du whisper-cli. Zum Installieren gib im Terminal \u{201E}brew install whisper-cpp\u{201C} ein."))
        }
        let models = problems.compactMap { problem -> String? in
            if case let .modelMissing(name) = problem { return name }
            return nil
        }
        if !models.isEmpty {
            let folder = modelsFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            parts.append(tr("The speech model file\(models.count == 1 ? "" : "s") \(models.joined(separator: " and ")) "
                + "\(models.count == 1 ? "is" : "are") missing in \(folder). Put \(models.count == 1 ? "it" : "them") there and try again.",
                "\(models.count == 1 ? "Die Sprachmodell-Datei" : "Die Sprachmodell-Dateien") \(models.joined(separator: " und ")) "
                + "\(models.count == 1 ? "fehlt" : "fehlen") in \(folder). Leg sie dort ab und versuch es noch einmal."))
            if models.contains(modelName) {
                parts.append(tr("On a Mac with 8 GB of memory, the smaller \(smallerModelName) works instead of \(modelName).",
                                "Auf einem Mac mit 8 GB Arbeitsspeicher geht statt \(modelName) auch das kleinere \(smallerModelName)."))
            }
        }
        return parts.joined(separator: " ")
    }

    static func arguments(audio: URL, outputBase: URL, modelsFolder: URL, language: Language, threads: Int, output: Output = .text,
                          fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> [String] {
        // For subtitles a time for each word: whisper's own lines (-ml 42) leave single words on their own ("werden."), `SubtitleMaker` does better.
        let wanted = output == .text ? ["-otxt"] : ["-osrt", "-ml", "1", "-sow"]
        return [
            "-m", (model(in: modelsFolder, fileExists: fileExists) ?? modelsFolder.appendingPathComponent(modelName)).path,
            "-l", language.rawValue,
            "-f", audio.path,
            "--vad", "-vm", modelsFolder.appendingPathComponent(silenceModelName).path,
        ] + wanted + [
            "-of", outputBase.path,
            "-pp", "-np",
            "-t", "\(threads)",
        ]
    }

    /// whisper-cli reports "whisper_print_progress_callback: progress =  45%".
    static func progress(inLine line: String) -> Double? {
        guard let range = line.range(of: "progress =") else { return nil }
        let number = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " %"))
        return Double(number).map { min(1, max(0, $0 / 100)) }
    }

    /// Each word spoken in `url` with its time, for subtitles that follow the speech word by word.
    static func words(of url: URL, language: Language = .german, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [SubtitleCue] {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-words-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("words.srt")
        try await transcribe(url, to: file, language: language, output: .srt, words: true, progress: progress)
        return SubtitleParser.parse(try TextFile.read(file), hint: .srt)
    }

    /// Writes the transcript of `url` to `destination`. Throws a readable error if something is missing,
    /// `CancellationError` when cancelled. Nothing is left behind on failure.
    /// `words`: for subtitles, one cue per word as whisper heard it, not yet put together into subtitles.
    static func transcribe(_ url: URL, to destination: URL, language: Language = .german, output: Output = .text, words: Bool = false, modelsFolder: URL = modelsFolder,
                           whisper: String? = whisperPath, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let found = problems(whisper: whisper, modelsFolder: modelsFolder)
        if let hint = hint(for: found, modelsFolder: modelsFolder) { throw AppError.invalidInput(hint) }
        guard let whisper, let format = FileFormat.detect(url) else { throw AppError.unreadable(url) }

        await oneAtATime.wait()
        do {
            try Task.checkCancellation()
            try await run(whisper: whisper, url: url, format: format, destination: destination, language: language, output: output, words: words, modelsFolder: modelsFolder, progress: progress)
            await oneAtATime.signal()
        } catch {
            await oneAtATime.signal()
            throw error
        }
    }

    private static func run(whisper: String, url: URL, format: FileFormat, destination: URL, language: Language, output: Output, words: Bool, modelsFolder: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-transcribe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Task.checkCancellation()
        progress(0)

        // Sound track as 16 kHz mono WAV, the format whisper works in; the first 5 % of the bar.
        let audio: URL
        if FFmpeg.isAvailable {
            audio = work.appendingPathComponent("audio.wav")
            let duration = await FFmpeg.probeDuration(url)
            try await FFmpeg.run(["-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-f", "wav", audio.path],
                                 purpose: tr("Preparing the sound for transcription", "Ton für die Transkription vorbereiten"), duration: duration) { progress($0 * 0.05) }
        } else if directlyReadable.contains(format) {
            audio = url
        } else {
            throw AppError.ffmpegMissing(tr("Transcribing \(format.displayName) files", "\(format.displayName)-Dateien transkribieren"))
        }
        try Task.checkCancellation()

        let outputBase = work.appendingPathComponent("transcript")
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        let args = arguments(audio: audio, outputBase: outputBase, modelsFolder: modelsFolder, language: language, threads: threads, output: output)
        let start = Date()
        let result = try await Shell.run(whisper, args, limit: .work, stream: .standardError) { line in
            if let value = Transcriber.progress(inLine: line) { progress(0.05 + value * 0.95) }
        }
        try Task.checkCancellation()
        let transcript = outputBase.appendingPathExtension(output == .text ? "txt" : "srt")
        guard result.succeeded, FileManager.default.fileExists(atPath: transcript.path) else {
            // whisper's own message may name files, so only the exit status goes into the log.
            DiagnosticLog.log("transcription failed: whisper-cli exit status \(result.status)")
            throw AppError.invalidInput(tr("The speech recognition stopped with an error (exit status \(result.status)). It needs about 3 GB of free memory: close other apps and try again.", "Die Spracherkennung wurde mit einem Fehler beendet (Status \(result.status)). Sie braucht etwa 3 GB freien Arbeitsspeicher: Schließ andere Apps und versuch es noch einmal."))
        }
        var text = (try? String(contentsOf: transcript, encoding: .utf8)) ?? ""
        if output != .text {
            let heard = SubtitleParser.parse(text, hint: .srt)
            let cues = words ? SubtitleMaker.spoken(heard) : SubtitleMaker.cues(fromWords: heard)
            text = cues.isEmpty ? "" : SubtitleParser.serialize(cues, as: output.format)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.invalidInput(tr("No speech was found in \(url.lastPathComponent).", "In \(url.lastPathComponent) wurde keine Sprache gefunden."))
        }
        if output != .text { try text.write(to: transcript, atomically: false, encoding: .utf8) }
        // Written in the temporary folder and moved at the end, so no half-written or hidden file shows up next to the original.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: transcript, to: destination)
        DiagnosticLog.log(String(format: "transcription: %@ input, language %@, %.1f s, %d characters, %d threads",
                                 format.rawValue, language.rawValue, Date().timeIntervalSince(start), text.count, threads))
        progress(1)
    }
}
