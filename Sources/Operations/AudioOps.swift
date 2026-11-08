import AVFoundation
import Foundation

struct LoudnessStats {
    var integrated: Double
    var truePeak: Double
    var range: Double
}

enum AudioOps {
    static func outputFormat(for url: URL) -> FileFormat {
        let format = FileFormat.detect(url) ?? .m4a
        if AudioEngine.nativeTargets.contains(format) || FFmpeg.isAvailable { return format }
        return .m4a
    }

    static func trim(_ url: URL, start: Double, end: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        let range = AVExporter.timeRange(start: start, end: end)
        if AudioEngine.nativeTargets.contains(format), await MediaInfo.isNativelyReadable(url) {
            let asset = AVURLAsset(url: url)
            if format == .m4a {
                try await AVExporter.export(asset: asset, to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, timeRange: range, progress: progress)
            } else {
                try await AVExporter.exportAudioPCM(asset: asset, to: destination, format: format, timeRange: range, progress: progress)
            }
            return
        }
        var args = ["-ss", FFmpeg.timecode(start), "-to", FFmpeg.timecode(end), "-i", url.path, "-vn"]
        args += AudioEngine.codecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
        try await FFmpeg.run(args, purpose: tr("Trimming audio", "Audio kürzen"), duration: end - start, progress: progress)
    }

    static func detectSilence(_ url: URL, threshold: Float = 0.01) async -> (leading: Double, trailing: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        do { try file.read(into: buffer) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var first = -1
        var last = -1
        for frame in 0..<count {
            var peak: Float = 0
            for c in 0..<channelCount { peak = max(peak, abs(channels[c][frame])) }
            if peak > threshold {
                if first < 0 { first = frame }
                last = frame
            }
        }
        guard first >= 0 else { return nil }
        let rate = format.sampleRate
        return (Double(first) / rate, Double(last + 1) / rate)
    }

    static func waveform(_ url: URL, buckets: Int) async -> [Float] {
        if let file = try? AVAudioFile(forReading: url) {
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            if frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount), (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData {
                let count = Int(buffer.frameLength)
                let per = max(1, count / buckets)
                var result: [Float] = []
                result.reserveCapacity(buckets)
                for b in 0..<buckets {
                    let start = b * per
                    let end = min(count, start + per)
                    guard start < end else { result.append(0); continue }
                    var peak: Float = 0
                    var frame = start
                    while frame < end {
                        for c in 0..<Int(format.channelCount) { peak = max(peak, abs(channels[c][frame])) }
                        frame += max(1, per / 64)
                    }
                    result.append(peak)
                }
                return result
            }
        }
        guard FFmpeg.isAvailable else { return [] }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-wave-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try await FFmpeg.run(["-i", url.path, "-ac", "1", "-ar", "8000", "-c:a", "pcm_s16le", temp.path], purpose: tr("Waveform", "Wellenform"))
        } catch { return [] }
        guard FileManager.default.fileExists(atPath: temp.path) else { return [] }
        return await waveformFromFile(temp, buckets: buckets)
    }

    private static func waveformFromFile(_ url: URL, buckets: Int) async -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount), (try? file.read(into: buffer)) != nil, let channels = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        let per = max(1, count / buckets)
        return (0..<buckets).map { b in
            let start = b * per, end = min(count, start + per)
            guard start < end else { return 0 }
            var peak: Float = 0
            for frame in stride(from: start, to: end, by: max(1, per / 64)) { peak = max(peak, abs(channels[0][frame])) }
            return peak
        }
    }

    static func measureLoudness(_ url: URL) async -> LoudnessStats? {
        guard FFmpeg.isAvailable else { return nil }
        let result = try? await FFmpeg.run(["-i", url.path, "-af", "loudnorm=print_format=json", "-f", "null", "-"], purpose: tr("Measuring loudness", "Lautstärke messen"))
        guard let text = result?.stderr, let start = text.range(of: "{"), let end = text.range(of: "}", options: .backwards) else { return nil }
        let json = String(text[start.lowerBound...end.lowerBound])
        guard let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
        return LoudnessStats(
            integrated: Double(object["input_i"] ?? "") ?? -23,
            truePeak: Double(object["input_tp"] ?? "") ?? -2,
            range: Double(object["input_lra"] ?? "") ?? 7
        )
    }

    /// The source's rate where the format can store it; Opus always works at 48 kHz.
    static func sampleRate(forNormalized format: FileFormat, source: Double) -> Int {
        guard source > 0 else { return 48_000 }
        switch format {
        case .opus: return 48_000
        case .wav, .aiff, .flac: return Int(source)
        default: return min(48_000, Int(source))
        }
    }

    static func normalize(_ url: URL, targetLUFS: Double, range: Double, truePeak: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        if FFmpeg.isAvailable {
            let duration = await FFmpeg.probeDuration(url)
            let filter = "loudnorm=I=\(targetLUFS):LRA=\(range):TP=\(truePeak)"
            // The filter works at 192 kHz and hands that on: a WAV came out four times as big, WMA failed. So back to the source's rate.
            let rate = sampleRate(forNormalized: format, source: await MediaInfo.load(url).sampleRate)
            var args = ["-i", url.path, "-vn", "-af", filter, "-ar", "\(rate)"]
            args += AudioEngine.codecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
            try await FFmpeg.run(args, purpose: tr("Normalizing", "Lautstärke angleichen"), duration: duration, progress: progress)
            return
        }
        let peak = await peakAmplitude(url) ?? 1
        let targetLinear = pow(10, truePeak / 20)
        let gain = Float(min(4, max(0.1, targetLinear / max(Double(peak), 0.0001))))
        try await applyGain(url, left: gain, right: gain, to: destination, format: format, progress: progress)
    }

    static func peakAmplitude(_ url: URL) async -> Float? {
        let samples = await waveform(url, buckets: 2048)
        return samples.max()
    }

    static func applyGain(_ url: URL, left: Float, right: Float, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AppError.invalidInput(tr("No audio track found.", "Keine Tonspur gefunden.")) }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume((left + right) / 2, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        if format == .m4a {
            try await AVExporter.export(asset: asset, to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, audioMix: mix, progress: progress)
        } else {
            try await AVExporter.exportAudioPCM(asset: asset, to: destination, format: AudioEngine.nativeTargets.contains(format) ? format : .wav, audioMix: mix, progress: progress)
        }
    }

    enum ChannelMode: String, CaseIterable, Identifiable {
        case stereo, mono, leftOnly, rightOnly, swap
        var id: String { rawValue }
        var title: String {
            switch self {
            case .stereo: return tr("Stereo", "Stereo")
            case .mono: return tr("Mono (mix down)", "Mono (zusammengemischt)")
            case .leftOnly: return tr("Left channel to both", "Linker Kanal auf beide Seiten")
            case .rightOnly: return tr("Right channel to both", "Rechter Kanal auf beide Seiten")
            case .swap: return tr("Swap left and right", "Links und rechts tauschen")
            }
        }
    }

    static func convertChannels(_ url: URL, mode: ChannelMode, leftGain: Double, rightGain: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        guard FFmpeg.isAvailable else {
            try await applyGain(url, left: Float(leftGain), right: Float(rightGain), to: destination, format: format, progress: progress)
            return
        }
        let pan: String
        switch mode {
        case .stereo: pan = "pan=stereo|c0=\(leftGain)*c0|c1=\(rightGain)*c1"
        case .mono: pan = "pan=mono|c0=\(leftGain * 0.5)*c0+\(rightGain * 0.5)*c1"
        case .leftOnly: pan = "pan=stereo|c0=\(leftGain)*c0|c1=\(leftGain)*c0"
        case .rightOnly: pan = "pan=stereo|c0=\(rightGain)*c1|c1=\(rightGain)*c1"
        case .swap: pan = "pan=stereo|c0=\(rightGain)*c1|c1=\(leftGain)*c0"
        }
        let duration = await FFmpeg.probeDuration(url)
        var args = ["-i", url.path, "-vn", "-af", pan]
        args += AudioEngine.codecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
        try await FFmpeg.run(args, purpose: tr("Converting channels", "Audiokanäle umwandeln"), duration: duration, progress: progress)
    }

    struct BleepRange: Identifiable, Equatable {
        let id = UUID()
        var start: Double
        var end: Double
    }

    /// Mutes the ranges (with ffmpeg also a tone over them), then checks the result (`MediaRedactionCheck`): in each range only the
    /// tone, one sound track, no cover picture, chapters or metadata. If the check finds anything, it throws and nothing is saved.
    static func bleep(_ url: URL, ranges: [BleepRange], frequency: Double, to destination: URL, format: FileFormat, progress: @escaping (Double) -> Void) async throws {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { throw AppError.invalidInput(tr("Add at least one bleep range.", "Füge mindestens einen Bereich zum Zensieren hinzu.")) }
        let tone: Double?
        if FFmpeg.isAvailable {
            tone = Double(Int(frequency))
            let duration = await FFmpeg.probeDuration(url)
            let mute = sorted.map { "between(t,\($0.start),\($0.end))" }.joined(separator: "+")
            let toneEnable = sorted.map { "between(t,\($0.start),\($0.end))" }.joined(separator: "+")
            let filter = "[0:a]volume=enable='\(mute)':volume=0[muted];sine=frequency=\(Int(frequency)):sample_rate=48000,volume=0.5,volume=enable='not(\(toneEnable))':volume=0[tone];[muted][tone]amix=inputs=2:duration=first:dropout_transition=0,volume=2[out]"
            // Only the bleeped sound: no cover picture, chapters or metadata (a title or lyrics could say what was bleeped).
            var args = ["-i", url.path, "-filter_complex", filter, "-map", "[out]"] + Privacy.removeAllArguments
            args += AudioEngine.codecArguments(for: format) + AudioEngine.containerArguments(for: format) + [destination.path]
            try await FFmpeg.run(args, purpose: tr("Bleeping audio", "Audio zensieren"), duration: duration, privacy: false) { progress($0 * 0.9) }
        } else {
            tone = nil
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw AppError.invalidInput(tr("No audio track found.", "Keine Tonspur gefunden.")) }
            // Only the first sound track, in a new composition: chapters and cover pictures of the original stay behind.
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw AppError.invalidInput(tr("No audio track found.", "Keine Tonspur gefunden."))
            }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source, at: .zero)
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(1, at: .zero)
            for range in sorted {
                params.setVolume(0, at: CMTime(seconds: range.start, preferredTimescale: 600))
                params.setVolume(1, at: CMTime(seconds: range.end, preferredTimescale: 600))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            let native: FileFormat = AudioEngine.nativeTargets.contains(format) ? format : .m4a
            if native == .m4a {
                try await AVExporter.export(asset: composition, to: destination, format: .m4a, preset: AVAssetExportPresetAppleM4A, audioMix: mix, metadata: []) { progress($0 * 0.9) }
            } else {
                try await AVExporter.exportAudioPCM(asset: composition, to: destination, format: native, audioMix: mix) { progress($0 * 0.9) }
            }
        }
        try Task.checkCancellation()
        try MediaRedactionCheck.requireNothing(await MediaRedactionCheck.audioProblems(original: url, output: destination, ranges: sorted, frequency: tone),
                                               what: "audio bleep")
        progress(1)
    }

    enum VisualizerStyle: String, CaseIterable, Identifiable {
        case waveform, bars, stillImage
        var id: String { rawValue }
        var title: String {
            switch self {
            case .waveform: return tr("Animated waveform", "Animierte Wellenform")
            case .bars: return tr("Frequency bars", "Frequenzbalken")
            case .stillImage: return tr("Still image", "Standbild")
            }
        }
    }

    enum VisualizerOrientation: String, CaseIterable, Identifiable {
        case landscape, portrait, square
        var id: String { rawValue }
        var title: String {
            switch self {
            case .landscape: return tr("Landscape", "Quer")
            case .portrait: return tr("Portrait", "Hoch")
            case .square: return tr("Square", "Quadratisch")
            }
        }
        var size: CGSize {
            switch self {
            case .landscape: return CGSize(width: 1920, height: 1080)
            case .portrait: return CGSize(width: 1080, height: 1920)
            case .square: return CGSize(width: 1080, height: 1080)
            }
        }
    }

    static func visualize(_ url: URL, style: VisualizerStyle, orientation: VisualizerOrientation, accent: String, background: String, image: URL?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let size = orientation.size
        let w = Int(size.width), h = Int(size.height)
        let duration = await FFmpeg.probeDuration(url)
        var args: [String] = ["-i", url.path]
        let filter: String
        switch style {
        case .waveform:
            filter = "[0:a]showwaves=s=\(w)x\(h / 3):mode=cline:colors=\(accent):rate=30[w];color=c=\(background):s=\(w)x\(h):r=30[bg];[bg][w]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
        case .bars:
            filter = "[0:a]showfreqs=s=\(w)x\(h / 2):mode=bar:colors=\(accent):fscale=log:ascale=sqrt:win_size=2048:rate=30[w];color=c=\(background):s=\(w)x\(h):r=30[bg];[bg][w]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
        case .stillImage:
            guard let image else { throw AppError.invalidInput(tr("Choose an image for the still-image visualizer.", "Wähle ein Bild für die Visualisierung mit Standbild.")) }
            args += ["-loop", "1", "-framerate", "30", "-i", image.path]
            filter = "[1:v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:color=\(background),format=yuv420p[v]"
        }
        args += ["-filter_complex", filter, "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", destination.path]
        try await FFmpeg.run(args, purpose: tr("Creating visualizer", "Visualisierung erstellen"), duration: duration, progress: progress)
    }
}
