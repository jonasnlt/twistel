import AVFoundation
import Foundation

enum AVExporter {
    /// Longest time an export or a sound conversion may go on without moving forward (a whole film can take hours, but it keeps moving).
    nonisolated(unsafe) static var stallSeconds: Double = 300

    /// What AVFoundation reports is for the log ("The operation could not be completed"); the message says what matters.
    static func failure(_ error: Error?) -> AppError {
        let text = error?.localizedDescription ?? "unknown"
        DiagnosticLog.log("AVFoundation failed: \(text)")
        return .encodeFailed(text.lowercased().contains("disk full") ? tr("the result (disk full)", "das Ergebnis (Festplatte voll)") : tr("the result", "das Ergebnis"))
    }

    /// Ends the writer, with a limit: it can stop answering like the rest of AVFoundation.
    static func finish(_ writer: AVAssetWriter, limit: Double) async throws {
        let box = UncheckedBox(writer)
        try await TimeLimit.call(seconds: limit, what: tr("Apple's video processing", "Apples Videoverarbeitung")) { await box.value.finishWriting() }
        guard writer.status == .completed else { throw AVExporter.failure(writer.error) }
    }

    /// How far the export is, 0…1: the session's own number (Apple now points to `states`, see `export`; the compiler warns).
    static func fraction(of session: AVAssetExportSession) -> Double {
        let value = Double(session.progress)
        return value.isFinite ? min(1, max(0, value)) : 0
    }

    static func fileType(for format: FileFormat) -> AVFileType? {
        switch format {
        case .mp4: return .mp4
        case .mov: return .mov
        case .m4a: return .m4a
        case .wav: return .wav
        case .aiff: return .aiff
        default: return nil
        }
    }

    static func export(
        asset: AVAsset,
        to destination: URL,
        format: FileFormat,
        preset: String = AVAssetExportPresetHighestQuality,
        timeRange: CMTimeRange? = nil,
        videoComposition: AVVideoComposition? = nil,
        audioMix: AVAudioMix? = nil,
        metadata: [AVMetadataItem]? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        guard let type = fileType(for: format) else { throw AppError.unsupportedConversion(.mp4, format) }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError.encodeFailed(tr("export session for \(format.displayName)", "Export als \(format.displayName)"))
        }
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        if let audioMix { session.audioMix = audioMix }
        // Settings › Privacy. Without a list of its own, the session copies the original's metadata: then the filter for sharing
        // (Apple's, leaves out places and personal details), or none at all.
        if let metadata {
            session.metadata = Privacy.forExportSession(Privacy.filter(metadata) ?? [])
        } else if Privacy.current.removeAllMetadata {
            session.metadata = Privacy.forExportSession([])
        } else if Privacy.current.removeLocation {
            session.metadataItemFilter = .forSharing()
        }
        try? FileManager.default.removeItem(at: destination)

        // An export that does not move any more is left behind, like a cancel that goes unanswered.
        let box = UncheckedBox(session)
        let limit = stallSeconds
        let moved = StallWatch(limit: limit)
        let answer = TimeLimit.Answer<Void>()
        let report = progress.map(UncheckedBox.init)
        // The progress is read four times a second, not through `states(updateInterval:)`: Apple's sequence of states stopped the
        // whole program (a trap inside AVFoundation, in a test run) while an export of an AVI was failing. Reading the
        // session's number can't do that.
        let ticker = Task.detached {
            var last = -1.0
            while !Task.isCancelled {
                let value = Self.fraction(of: box.value)
                if value > 0, value != last {
                    last = value
                    moved.touch(whenChanged: value)
                    await MainActor.run { report?.value(value) }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let exporting = Task.detached {
            do {
                try await box.value.export(to: destination, as: type)
                answer.finish(.success(()))
            } catch {
                answer.finish(.failure(error))
            }
        }
        let watcher = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(limit / 4, 5)))
                if moved.isStalled {
                    exporting.cancel()
                    answer.finish(.failure(TimeLimit.Exceeded(what: tr("Apple's video processing", "Apples Videoverarbeitung"), seconds: limit)))
                    return
                }
            }
        }
        defer {
            watcher.cancel()
            ticker.cancel()
        }
        do {
            try await withTaskCancellationHandler {
                try await answer.value()
            } onCancel: {
                exporting.cancel()
                DispatchQueue.global().asyncAfter(deadline: .now() + JobWatch.cancelGraceSeconds) { answer.finish(.failure(CancellationError())) }
            }
        } catch let error as TimeLimit.Exceeded {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw AVExporter.failure(error)
        }
        progress?(1)
    }

    /// Re-encodes the sound to AAC at a chosen bitrate. `AVAssetExportPresetAppleM4A` can't do this: it keeps the bitrate of
    /// an AAC source (an m4a came out byte for byte the same size).
    static func exportAAC(asset: AVAsset, to destination: URL, bitrate: Int, progress: ((Double) -> Void)? = nil) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AppError.invalidInput(tr("No audio track found.", "Keine Tonspur gefunden.")) }
        var channels = 2
        var sourceRate = 44_100.0
        if let first = try await track.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
            sourceRate = asbd.pointee.mSampleRate
        }
        channels = min(2, max(1, channels))
        let encoding = aacEncoding(bitrate, channels: channels, sourceSampleRate: sourceRate)
        try await writeAudio(asset: asset, tracks: tracks, to: destination, fileType: .m4a, readerSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: encoding.sampleRate,
            AVNumberOfChannelsKey: channels,
        ], writerSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: encoding.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: encoding.bitrate,
        ], timeRange: nil, audioMix: nil, metadata: try? await asset.load(.metadata), progress: progress)
    }

    /// Sample rate and bitrate for AAC: the highest sample rate (up to the source's) at which Apple's encoder accepts a
    /// bitrate at or below `wanted`, and the nearest such bitrate. Measured on macOS 27: 48 kHz stereo starts at
    /// 64 kbit/s, 48 kHz mono at 32 kbit/s; lower bitrates need 32, 24 or 16 kHz.
    static func aacEncoding(_ wanted: Int, channels: Int, sourceSampleRate: Double) -> (sampleRate: Double, bitrate: Int) {
        let all: [Double] = [48_000, 44_100, 32_000, 24_000, 22_050, 16_000]
        let candidates = all.filter { $0 <= sourceSampleRate }
        for rate in candidates.isEmpty ? [16_000] : candidates {
            let rates = applicableAACBitrates(channels: channels, sampleRate: rate)
            if rates.isEmpty { return (rate, wanted) }
            if let fit = rates.filter({ $0 <= wanted }).max() { return (rate, fit) }
        }
        let lowest = candidates.last ?? 16_000
        return (lowest, applicableAACBitrates(channels: channels, sampleRate: lowest).min() ?? wanted)
    }

    /// The bitrates Apple's AAC encoder accepts for this layout (empty if it can't be asked).
    static func applicableAACBitrates(channels: Int, sampleRate: Double) -> [Int] {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]),
              let converter = AVAudioConverter(from: pcm, to: aac) else { return [] }
        return converter.applicableEncodeBitRates?.map(\.intValue) ?? []
    }

    static func exportAudioPCM(asset: AVAsset, to destination: URL, format: FileFormat, timeRange: CMTimeRange? = nil, audioMix: AVAudioMix? = nil, progress: ((Double) -> Void)? = nil) async throws {
        try await withPCMWriter(asset: asset, to: destination, format: format, timeRange: timeRange, audioMix: audioMix, progress: progress)
    }

    private static func withPCMWriter(asset: AVAsset, to destination: URL, format: FileFormat, timeRange: CMTimeRange?, audioMix: AVAudioMix?, progress: ((Double) -> Void)?) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AppError.invalidInput(tr("No audio track found.", "Keine Tonspur gefunden.")) }
        let formatDescriptions = try await track.load(.formatDescriptions)
        var channels = 2
        var sampleRate = 44_100.0
        if let first = formatDescriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
            sampleRate = asbd.pointee.mSampleRate
        }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: format == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var writerSettings = pcm
        writerSettings[AVSampleRateKey] = sampleRate
        writerSettings[AVNumberOfChannelsKey] = channels
        var readerSettings = pcm
        if channels > 2 {
            // More than two channels without saying which is which end the app with an exception (found with an 8-channel WAV).
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)
            let data = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            writerSettings[AVChannelLayoutKey] = data
            readerSettings[AVSampleRateKey] = sampleRate
            readerSettings[AVNumberOfChannelsKey] = channels
            readerSettings[AVChannelLayoutKey] = data
        }
        try await writeAudio(asset: asset, tracks: tracks, to: destination, fileType: format == .aiff ? .aiff : .wav, readerSettings: readerSettings,
                             writerSettings: writerSettings, timeRange: timeRange, audioMix: audioMix, metadata: nil, progress: progress)
    }

    /// Reads the mixed audio tracks as PCM and writes them with `writerSettings`. Stops when the task is cancelled.
    private static func writeAudio(asset: AVAsset, tracks: [AVAssetTrack], to destination: URL, fileType: AVFileType, readerSettings: [String: Any],
                                   writerSettings: [String: Any], timeRange: CMTimeRange?, audioMix: AVAudioMix?, metadata: [AVMetadataItem]?,
                                   progress: ((Double) -> Void)?) async throws {
        let duration = try await asset.load(.duration)
        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readerSettings)
        output.audioMix = audioMix
        // Not sharing buffers: sharing crashed Apple's video reader under load (see `VideoPresets`).
        output.alwaysCopiesSampleData = true
        reader.add(output)
        if let timeRange { reader.timeRange = timeRange }

        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        if let metadata = Privacy.filter(metadata) { writer.metadata = metadata }
        // Settings it can't take would be an exception, not an error.
        guard writer.canApply(outputSettings: writerSettings, forMediaType: .audio) else { throw AppError.encodeFailed(tr("the sound", "der Ton")) }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AppError.encodeFailed(tr("audio settings not accepted", "Toneinstellungen nicht angenommen")) }
        writer.add(input)
        guard reader.startReading() else { throw AVExporter.failure(reader.error) }
        guard writer.startWriting() else { throw AVExporter.failure(writer.error) }
        let start = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: start)
        let total = CMTimeGetSeconds(timeRange?.duration ?? duration)

        final class Flag: @unchecked Sendable { var cancelled = false }
        let flag = Flag()
        let queue = DispatchQueue(label: "\(AppIdentity.bundleID).audio.writer")
        let moved = StallWatch(limit: stallSeconds)
        let answer = TimeLimit.Answer<Void>()
        let watcher = Task.detached { [limit = stallSeconds] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(limit / 4, 5)))
                if moved.isStalled {
                    answer.finish(.failure(TimeLimit.Exceeded(what: tr("Apple's sound processing", "Apples Tonverarbeitung"), seconds: limit)))
                    return
                }
            }
        }
        defer { watcher.cancel() }
        struct Parts: @unchecked Sendable {
            let input: AVAssetWriterInput, output: AVAssetReaderOutput, reader: AVAssetReader, writer: AVAssetWriter
        }
        let parts = Parts(input: input, output: output, reader: reader, writer: writer)
        do {
            try await withTaskCancellationHandler {
                parts.input.requestMediaDataWhenReady(on: queue) {
                    let input = parts.input, output = parts.output, reader = parts.reader, writer = parts.writer
                    while input.isReadyForMoreMediaData {
                        #if DEBUG
                        if simulatedStall { DispatchSemaphore(value: 0).wait() }
                        #endif
                        if !flag.cancelled, let sample = output.copyNextSampleBuffer() {
                            input.append(sample)
                            moved.touch()
                            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - CMTimeGetSeconds(start)
                            if total > 0 { let value = min(1, max(0, time / total)); DispatchQueue.main.async { progress?(value) } }
                        } else {
                            input.markAsFinished()
                            if flag.cancelled {
                                reader.cancelReading()
                                writer.cancelWriting()
                                answer.finish(.failure(AppError.cancelled))
                            } else if reader.status == .failed {
                                writer.cancelWriting()
                                answer.finish(.failure(AVExporter.failure(reader.error)))
                            } else {
                                moved.touch()
                                writer.finishWriting {
                                    if writer.status == .completed {
                                        answer.finish(.success(()))
                                    } else {
                                        answer.finish(.failure(AVExporter.failure(writer.error)))
                                    }
                                }
                            }
                            return
                        }
                    }
                }
                try await answer.value()
            } onCancel: {
                queue.async { flag.cancelled = true }
                // Also when the queue is stuck in the reader.
                DispatchQueue.global().asyncAfter(deadline: .now() + JobWatch.cancelGraceSeconds) { answer.finish(.failure(AppError.cancelled)) }
            }
        } catch {
            // On its queue: not while a sample is being appended. A stuck queue has nothing to clean up that matters: the file goes away below.
            queue.async { parts.writer.cancelWriting() }
            // No half-written file next to the original.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress?(1)
    }

    #if DEBUG
    /// Tests: the sound conversion hangs like Apple's reader can.
    nonisolated(unsafe) static var simulatedStall = false
    #endif

    static func timeRange(start: Double, end: Double) -> CMTimeRange {
        let s = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let e = CMTime(seconds: max(start, end), preferredTimescale: 600)
        return CMTimeRange(start: s, end: e)
    }
}

/// Something of Apple's that is safe to hand to another thread here but is not marked so.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Notices work that has stopped moving forward.
final class StallWatch: @unchecked Sendable {
    struct Stalled: Error {}
    private let limit: Double
    private let lock = NSLock()
    private var last = Date()
    private var lastValue = -1.0

    init(limit: Double) { self.limit = limit }

    func touch() { lock.withLock { last = Date() } }

    func touch(whenChanged value: Double) {
        lock.withLock {
            if value != lastValue {
                lastValue = value
                last = Date()
            }
        }
    }

    var isStalled: Bool { lock.withLock { Date().timeIntervalSince(last) > limit } }
}
