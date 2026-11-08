import Foundation

enum FFmpeg {
    static var path: String? {
        resolvePath(configured: AppSettings.shared.ffmpegPath, isExecutable: isProgram) {
            Shell.which("ffmpeg")
        }
    }

    /// Whether a path is an ffmpeg program: a file that is there and may run, a compiled program (no script), named "ffmpeg…", that
    /// nobody but its owner may change. The path in Settings is checked so each time it is used: another app could have written
    /// any program there (`defaults write`), and it would run with twistel's rights on every film.
    static func isProgram(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path) else { return false }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard real.lastPathComponent.lowercased().hasPrefix("ffmpeg") || real.lastPathComponent.lowercased().hasPrefix("ffprobe"),
              let attributes = try? fm.attributesOfItem(atPath: real.path), attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? Int, isSafelyOwned(permissions: permissions, owner: (attributes[.ownerAccountID] as? NSNumber)?.uint32Value),
              let handle = try? FileHandle(forReadingFrom: real) else { return false }
        defer { try? handle.close() }
        let magic = [UInt8]((try? handle.read(upToCount: 4)) ?? Data())
        // Mach-O 64 and 32 bit, universal and universal with 64-bit offsets.
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]].contains(magic)
    }

    /// Nobody else can have changed it: not writable by all, and if its group may write (some Homebrew setups), it belongs to this
    /// user or to root.
    static func isSafelyOwned(permissions: Int, owner: UInt32?) -> Bool {
        guard permissions & 0o002 == 0 else { return false }
        guard permissions & 0o020 != 0 else { return true }
        return owner == getuid() || owner == 0
    }

    /// Why the ffmpeg path in Settings can't be used; nil when it is empty (then the installed one) or a real ffmpeg.
    static var settingsProblem: String? {
        let configured = AppSettings.shared.ffmpegPath.trimmingCharacters(in: .whitespaces)
        guard !configured.isEmpty, !isProgram(configured) else { return nil }
        return tr("The ffmpeg path in Settings (\((configured as NSString).lastPathComponent)) is not an ffmpeg program that can be used. Choose ffmpeg again in Settings, or empty the field to use the installed one.",
                  "Der ffmpeg-Pfad in den Einstellungen (\((configured as NSString).lastPathComponent)) ist kein verwendbares ffmpeg-Programm. Wähle ffmpeg in den Einstellungen neu aus, oder leere das Feld, um das installierte zu verwenden.")
    }

    /// Homebrew's ffmpeg-full is keg-only (not on PATH) but has more encoders (WebP, Vorbis, AV1),
    /// so it wins over the plain ffmpeg when installed.
    static let fullBuildPaths = ["/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/usr/local/opt/ffmpeg-full/bin/ffmpeg"]

    /// Order: the path set in Settings, then ffmpeg-full, then the ffmpeg found on the usual paths.
    static func resolvePath(configured: String, isExecutable: (String) -> Bool, fallback: () -> String?) -> String? {
        let configured = configured.trimmingCharacters(in: .whitespaces)
        if !configured.isEmpty, isExecutable(configured) { return configured }
        if let full = fullBuildPaths.first(where: isExecutable) { return full }
        return fallback()
    }

    static var probePath: String? {
        if let ffmpeg = path {
            let sibling = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
            if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        }
        return Shell.which("ffprobe")
    }

    static var isAvailable: Bool { path != nil }

    enum Health: Equatable {
        case missing
        case broken(path: String, reason: String)
        case ready(path: String, version: String)
    }

    static func checkHealth() async -> Health {
        guard let ffmpeg = path else { return .missing }
        do {
            let result = try await Shell.run(ffmpeg, ["-hide_banner", "-version"], limit: .quick)
            let firstLine = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
            guard result.succeeded, firstLine.hasPrefix("ffmpeg version") else {
                return .broken(path: ffmpeg, reason: summarize(result.stderr.isEmpty ? result.stdout : result.stderr))
            }
            let version = firstLine.replacingOccurrences(of: "ffmpeg version ", with: "")
                .split(separator: " ").first.map(String.init) ?? ""
            return .ready(path: ffmpeg, version: version)
        } catch {
            return .broken(path: ffmpeg, reason: error.localizedDescription)
        }
    }

    static func summarize(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let dyld = lines.first(where: { $0.contains("Library not loaded") }) {
            let library = dyld.components(separatedBy: "Library not loaded: ").last.map { ($0 as NSString).lastPathComponent } ?? ""
            return tr("missing library \(library). Reinstall ffmpeg and its dependencies (for example \u{201C}brew reinstall ffmpeg\u{201D}).",
                      "Die Programmbibliothek \(library) fehlt. Installiere ffmpeg und alles, was es braucht, neu (zum Beispiel mit \u{201E}brew reinstall ffmpeg\u{201C}).")
        }
        return lines.last(where: { !$0.hasPrefix("Referenced from") && !$0.hasPrefix("Reason:") }) ?? output
    }

    /// ffmpeg's way of saying that the file is not what its name says, in words.
    static func unusableInput(_ output: String, name: String) -> String? {
        if ["Error opening input", "Invalid data found when processing input", "moov atom not found"].contains(where: output.contains) {
            return tr("\(name) could not be read. It is damaged, empty or not really this kind of file.", "\(name) konnte nicht gelesen werden. Die Datei ist beschädigt, leer oder keine echte Datei dieser Art.")
        }
        if ["Nothing was written into output file", "Error opening output files: Invalid argument", "Error binding filtergraph", "Error writing trailer: Invalid argument", "does not contain any stream"].contains(where: output.contains) {
            return tr("\(name) has nothing in it that can be used for this. It may be damaged, too short or not really this kind of file.",
                      "\(name) enthält nichts, was sich dafür verwenden lässt. Die Datei ist vielleicht beschädigt, zu kurz oder keine echte Datei dieser Art.")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Conversion failed!") {
            return tr("\(name) could not be converted. It may be damaged.", "\(name) konnte nicht umgewandelt werden. Die Datei ist vielleicht beschädigt.")
        }
        return nil
    }

    /// `privacy`: Settings › Privacy apply to what is written (`withPrivacy`); off only for the metadata tool, which writes what is chosen in it.
    @discardableResult
    static func run(_ arguments: [String], purpose: String, duration: Double? = nil, privacy: Bool = true, progress: ((Double) -> Void)? = nil) async throws -> ShellResult {
        if let problem = settingsProblem { throw AppError.invalidInput(problem) }
        guard let ffmpeg = path else { throw AppError.ffmpegMissing(purpose) }
        let arguments = privacy ? withPrivacy(arguments, tagKeys: await tagKeys(of: inputs(in: arguments))) : arguments
        if let available = await encoders(of: ffmpeg), let missing = missingEncoders(in: arguments, available: available).first {
            throw AppError.ffmpegEncoderMissing(purpose, missing)
        }
        var args = ["-hide_banner", "-y", "-nostdin"]
        if progress != nil { args += ["-progress", "pipe:1", "-loglevel", "error"] }
        args += arguments
        let result: ShellResult
        if let progress, let duration, duration > 0 {
            result = try await Shell.run(ffmpeg, args, limit: .work) { line in
                if line.hasPrefix("out_time_ms="), let ms = Double(line.dropFirst(12)) {
                    let fraction = min(1, max(0, ms / 1_000_000 / duration))
                    DispatchQueue.main.async { progress(fraction) }
                }
            }
        } else {
            result = try await Shell.run(ffmpeg, args, limit: .work)
        }
        try Task.checkCancellation()
        guard result.succeeded else {
            let output = result.stderr.isEmpty ? result.stdout : result.stderr
            let input = zip(arguments, arguments.dropFirst()).first { $0.0 == "-i" }.map { ($0.1 as NSString).lastPathComponent }
            if let input, let reason = unusableInput(output, name: input) { throw AppError.invalidInput(reason) }
            throw AppError.toolFailed("ffmpeg", summarize(output))
        }
        return result
    }

    /// Settings › Privacy for every ffmpeg call: ffmpeg itself copies all metadata of the first input unless told otherwise, so a trimmed
    /// or louder recording kept its place, title and artist. The rules go right before the output (the last argument); a call that
    /// already says what to do with metadata only gets the places of its inputs left out. Nothing for a call without a file to write.
    static func withPrivacy(_ arguments: [String], rules: Privacy.Rules = Privacy.current, tagKeys: Set<String>) -> [String] {
        guard let output = arguments.last, !output.hasPrefix("-") || output == "-", arguments.count >= 2,
              !zip(arguments, arguments.dropFirst()).contains(where: { $0 == "-f" && $1 == "null" }) else { return arguments }
        let rules = arguments.contains("-map_metadata")
            ? Privacy.locationArguments(rules: rules, tagKeys: tagKeys)
            : Privacy.ffmpegArguments(keepsMetadata: true, rules: rules, tagKeys: tagKeys)
        return arguments.dropLast() + rules + [output]
    }

    /// The files after "-i".
    static func inputs(in arguments: [String]) -> [URL] {
        zip(arguments, arguments.dropFirst()).compactMap { $0 == "-i" && $1.hasPrefix("/") ? URL(fileURLWithPath: $1) : nil }
    }

    /// The names of the metadata tags of these files, in the file and in its streams ("title", "LOCATION", "com.apple.quicktime.location.ISO6709").
    static func tagKeys(of files: [URL]) async -> Set<String> {
        guard let probe = probePath else { return [] }
        var keys = Set<String>()
        for file in files {
            guard let result = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format_tags:stream_tags", "-of", "json", file.path], limit: .quick),
                  result.succeeded, let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else { continue }
            if let tags = (object["format"] as? [String: Any])?["tags"] as? [String: Any] { keys.formUnion(tags.keys) }
            for stream in object["streams"] as? [[String: Any]] ?? [] {
                if let tags = stream["tags"] as? [String: Any] { keys.formUnion(tags.keys) }
            }
        }
        return keys
    }

    static func probeDuration(_ url: URL) async -> Double? {
        guard let probe = probePath else { return nil }
        let result = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", url.path], limit: .quick)
        return result.flatMap { Double($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap(SafeNumber.seconds)
    }

    private static let encoderCache = EncoderCache()

    /// The encoders this ffmpeg build offers, cached per executable; nil if the list cannot be read.
    static func encoders(of ffmpeg: String) async -> Set<String>? {
        if let cached = encoderCache.get(ffmpeg) { return cached }
        guard let result = try? await Shell.run(ffmpeg, ["-hide_banner", "-encoders"], limit: .quick), result.succeeded else { return nil }
        let list = parseEncoders(result.stdout)
        guard !list.isEmpty else { return nil }
        encoderCache.set(ffmpeg, list)
        return list
    }

    /// Reads the names from `ffmpeg -encoders` (the second column after the "------" line).
    static func parseEncoders(_ output: String) -> Set<String> {
        var names = Set<String>()
        var inList = false
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if !inList {
                inList = fields.first == "------"
                continue
            }
            if fields.count >= 2 { names.insert(String(fields[1])) }
        }
        return names
    }

    /// Encoders named with -c:v / -c:a / -c that this build does not have ("copy" needs none).
    static func missingEncoders(in arguments: [String], available: Set<String>) -> [String] {
        zip(arguments, arguments.dropFirst()).compactMap { flag, value in
            guard flag == "-c" || flag.hasPrefix("-c:"), value != "copy", !available.contains(value) else { return nil }
            return value
        }
    }

    /// The picture size (turned as it is shown) and the sound's sample rate; nil when ffprobe is not available or fails.
    static func probeStreams(_ url: URL) async -> (size: CGSize?, sampleRate: Double?)? {
        guard let probe = probePath,
              let result = try? await Shell.run(probe, ["-v", "error", "-show_entries", "stream=codec_type,width,height,sample_rate:stream_side_data=rotation", "-of", "json", url.path], limit: .quick),
              result.succeeded, let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]] else { return nil }
        var size: CGSize?
        var sampleRate: Double?
        for stream in streams {
            if stream["codec_type"] as? String == "video", size == nil, let width = stream["width"] as? Int, let height = stream["height"] as? Int {
                let rotation = (stream["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first ?? 0
                size = abs(rotation) % 180 == 90 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            } else if stream["codec_type"] as? String == "audio", sampleRate == nil, let rate = (stream["sample_rate"] as? String).flatMap(Double.init) {
                sampleRate = rate
            }
        }
        return (size, sampleRate)
    }

    /// Whether the file has at least one audio stream; nil when ffprobe is not available or fails.
    static func probeHasAudio(_ url: URL) async -> Bool? {
        guard let probe = probePath,
              let result = try? await Shell.run(probe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", url.path], limit: .quick),
              result.succeeded else { return nil }
        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func timecode(_ seconds: Double) -> String {
        let clamped = SafeNumber.clampedSeconds(seconds)
        let hours = Int(clamped) / 3600
        let minutes = (Int(clamped) % 3600) / 60
        let secs = clamped - Double(hours * 3600 + minutes * 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, secs)
    }
}

private final class EncoderCache: @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [String: Set<String>] = [:]

    func get(_ path: String) -> Set<String>? {
        lock.lock(); defer { lock.unlock() }
        return lists[path]
    }

    func set(_ path: String, _ list: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        lists[path] = list
    }
}
