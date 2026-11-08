import AVFoundation
import CoreImage
import Foundation

/// Videos for social media and for sending. All sizes are in this one table, so they are easy to change.
enum VideoPreset: String, CaseIterable, Identifiable {
    case reels, linkedInPortrait, linkedInSquare
    case whatsApp, email

    var id: String { rawValue }

    enum Kind: Equatable {
        /// Cut to this size in pixels (never enlarged), at about this many bits per second.
        case crop(width: Int, height: Int, bitrate: Int)
        /// Longest edge in pixels and the largest file size in bytes; nothing is cut off.
        case send(longEdge: Int, maxBytes: Int64)
    }

    // MARK: The sizes (checked by hand; change them here)

    var kind: Kind {
        switch self {
        // Full screen on a phone. All three platforms ask for 1080 px wide and recompress what they get, so a clean source of 5 to 8 Mbit/s
        // is enough (guides name 5 to 15 Mbit/s). A minute of it is about 60 MB, far below every limit.
        case .reels: return .crop(width: 1080, height: 1920, bitrate: 8_000_000)
        // The largest shape LinkedIn shows in the feed without bars; fewer pixels than 9:16, so less data for the same picture.
        case .linkedInPortrait: return .crop(width: 1080, height: 1350, bitrate: 6_000_000)
        case .linkedInSquare: return .crop(width: 1080, height: 1080, bitrate: 5_000_000)
        // 16 MB is the limit for sending a video the normal way; above it WhatsApp recompresses or refuses. 720p is sharp on a phone.
        case .whatsApp: return .send(longEdge: 1280, maxBytes: 16_000_000)
        // Mail servers take 20 to 25 MB, and an attachment grows by a third on the way (encoded as text): 20 MB becomes 15 MB of file.
        case .email: return .send(longEdge: 1280, maxBytes: 15_000_000)
        }
    }

    // MARK: Names

    var title: String {
        switch self {
        case .reels: return "Reels & Story 9:16"
        case .linkedInPortrait: return "LinkedIn 4:5"
        case .linkedInSquare: return "LinkedIn 1:1"
        case .whatsApp: return "WhatsApp"
        case .email: return tr("E-mail", "E-Mail")
        }
    }

    var detail: String {
        switch kind {
        case let .crop(width, height, _): return "\(width) × \(height)"
        case let .send(_, maxBytes): return tr("720p, up to \(maxBytes / 1_000_000) MB", "720p, bis \(maxBytes / 1_000_000) MB")
        }
    }

    /// Goes into the file name; a colon would show as a slash in the Finder.
    var fileSuffix: String {
        switch self {
        case .reels: return "Reels"
        case .linkedInPortrait: return "LinkedIn 4x5"
        case .linkedInSquare: return "LinkedIn 1x1"
        case .whatsApp: return "WhatsApp"
        case .email: return tr("E-mail", "E-Mail")
        }
    }

    var isCrop: Bool { if case .crop = kind { return true } else { return false } }
    static var crops: [VideoPreset] { allCases.filter(\.isCrop) }
    static var sends: [VideoPreset] { allCases.filter { !$0.isCrop } }

    /// Frames per second at most: sending does not need more than 30, and half the frames leave more data for each.
    var frameRateLimit: Double { isCrop ? 60 : 30 }
    var audioBitrate: Int { isCrop ? 128_000 : 96_000 }
}

enum VideoPresets {
    /// What to send a video at. Keeps to the size limit with a margin, not above what 720p can use (a short clip does not need 16 MB) nor what the
    /// source has. Less data than a size can carry: smaller pictures. The lowest values are what is still watchable; below that the limit gives way.
    static func sendingPlan(duration: Double, sourceBitrate: Double, sourceSize: CGSize, longEdge: Int, maxBytes: Int64, audioBitrate: Int) -> (videoBitrate: Int, longEdge: Int) {
        let available = duration > 0 ? Double(maxBytes) * 8 * 0.93 / duration - Double(audioBitrate) : 4_000_000
        var bitrate = min(4_000_000, available)
        // The pictures follow what the size can carry, not the source: a calm video needs little data at any size.
        let edge = bitrate >= 1_200_000 ? longEdge : (bitrate >= 500_000 ? min(longEdge, 854) : min(longEdge, 640))
        if sourceBitrate > 0 { bitrate = min(bitrate, max(sourceBitrate, 500_000)) }
        return (Int(max(150_000, bitrate)), min(edge, Int(max(sourceSize.width, sourceSize.height))))
    }

    /// The size of the whole picture with its longest edge at `longEdge`, in even numbers; never larger than it was.
    static func fitted(_ size: CGSize, longEdge: Int) -> CGSize {
        let scale = min(1, CGFloat(longEdge) / max(size.width, size.height, 1))
        return CGSize(width: max(2, (size.width * scale / 2).rounded() * 2), height: max(2, (size.height * scale / 2).rounded() * 2))
    }

    /// The cut in even numbers inside the picture (H.264 needs them) and the size it is saved at: the preset's, or the cut's own if that is smaller.
    static func cropPlan(window: CGRect, imageSize: CGSize, width: Int, height: Int) -> (rect: CGRect, output: CGSize) {
        let cut = CGSize(width: (window.width / 2).rounded(.down) * 2, height: (window.height / 2).rounded(.down) * 2)
        let rect = CGRect(x: min(window.minX.rounded(), imageSize.width - cut.width), y: min(window.minY.rounded(), imageSize.height - cut.height), width: cut.width, height: cut.height)
        return (rect, cut.width >= CGFloat(width) ? CGSize(width: width, height: height) : cut)
    }

    static func outputURL(for url: URL, preset: VideoPreset) -> URL {
        ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                   baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: preset.fileSuffix, ext: "mp4")
    }

    /// `chosen`: a cut placed by hand (fractions of the picture, origin top left). Without it the cut follows the face or subject in the middle of the video; it does not move with them.
    static func save(_ url: URL, preset: VideoPreset, chosen: CGRect? = nil, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        var size = info.naturalSize
        // Containers Apple cannot read.
        if size == .zero { size = CGSize(width: try await VideoOps.snapshot(url, at: 0).width, height: try await VideoOps.snapshot(url, at: 0).height) }
        switch preset.kind {
        case let .crop(width, height, bitrate):
            let aspect = CGSize(width: width, height: height)
            let window: CGRect
            if let chosen {
                window = SmartCrop.window(fraction: chosen, imageSize: size, aspect: aspect)
            } else {
                let frame = try await VideoOps.snapshot(url, at: info.duration / 2)
                window = SmartCrop.window(imageSize: size, aspect: aspect, important: await SmartCrop.importantRegion(in: frame).rect)
            }
            let plan = cropPlan(window: window, imageSize: size, width: width, height: height)
            // Not more than the source has, but enough for a cut that is enlarged by nothing and only loses pixels.
            let rate = info.estimatedBitrate > 0 ? min(bitrate, max(Int(info.estimatedBitrate), 2_000_000)) : bitrate
            try await write(url, crop: plan.rect, output: plan.output, frameRateLimit: preset.frameRateLimit, videoBitrate: rate, audioBitrate: preset.audioBitrate, to: destination, progress: progress)
        case let .send(longEdge, maxBytes):
            let plan = sendingPlan(duration: info.duration, sourceBitrate: info.estimatedBitrate, sourceSize: size, longEdge: longEdge, maxBytes: maxBytes, audioBitrate: preset.audioBitrate)
            var rate = plan.videoBitrate, edge = plan.longEdge
            // Apple's encoder does not always keep to the rate: with a lot of detail it overshoots at any rate (18.5 MB instead of 16 at 720p, twice).
            // So tries follow what came out, and after the first one the pictures get smaller as well.
            let tries = 4
            for attempt in 0..<tries {
                let done = 1 - pow(0.5, Double(attempt)), share = pow(0.5, Double(attempt + 1))
                try await write(url, crop: nil, output: fitted(size, longEdge: edge), frameRateLimit: preset.frameRateLimit, videoBitrate: rate, audioBitrate: preset.audioBitrate, to: destination) { progress(done + $0 * share) }
                let written = FileSizeFormatter.size(of: destination)
                guard written > maxBytes, attempt < tries - 1 else { break }
                DiagnosticLog.log("video for sending: \(written) bytes over the limit at \(edge) px, trying again")
                rate = max(150_000, Int(Double(rate) * Double(maxBytes) / Double(written) * 0.9))
                if attempt > 0 { edge = edge > 854 ? 854 : 640 }
            }
            let written = FileSizeFormatter.size(of: destination)
            if written > maxBytes {
                JobNotes.add(tr("This video does not fit \(preset.title): even at the lowest quality it is \(FileSizeFormatter.string(written)), the limit is \(FileSizeFormatter.string(maxBytes)). Shorten it, or send it another way.", "Dieses Video passt nicht für \(preset.title): Selbst in der niedrigsten Qualität hat es \(FileSizeFormatter.string(written)), die Grenze liegt bei \(FileSizeFormatter.string(maxBytes)). Kürze es oder verschick es auf anderem Weg."))
            }
        }
        progress(1)
    }

    /// One way for every video Apple can read: always H.264 in normal colours (an iPhone's HDR is converted; ffmpeg here cannot do that),
    /// sound as AAC, no location or other metadata. Written in the temporary folder and moved at the end. Others go through ffmpeg.
    /// `overlay`: drawn on each picture, for Apple's way only.
    static func write(_ url: URL, crop: CGRect?, output: CGSize, frameRateLimit: Double, videoBitrate: Int, audioBitrate: Int, overlay: (@Sendable (CIImage, CMTime) -> CIImage)? = nil, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-video-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("video.mp4")
        if await MediaInfo.isNativelyReadable(url) {
            do {
                try await encode(AVURLAsset(url: url), crop: crop, output: output, frameRateLimit: frameRateLimit, videoBitrate: videoBitrate, audioBitrate: audioBitrate, overlay: overlay, to: file, progress: progress)
            } catch is Stalled {
                DiagnosticLog.log("video reader stopped answering, trying once more")
                try? FileManager.default.removeItem(at: file)
                do {
                    try await encode(AVURLAsset(url: url), crop: crop, output: output, frameRateLimit: frameRateLimit, videoBitrate: videoBitrate, audioBitrate: audioBitrate, overlay: overlay, to: file, progress: progress)
                } catch is Stalled {
                    throw AppError.encodeFailed(tr("Apple's video processing stopped answering. Please try again, or restart the Mac if it keeps happening.", "Apples Videoverarbeitung hat nicht mehr geantwortet. Bitte versuch es noch einmal oder starte den Mac neu, wenn es wieder passiert."))
                }
            }
        } else {
            var filters: [String] = []
            if let crop { filters.append("crop=\(Int(crop.width)):\(Int(crop.height)):\(Int(crop.minX)):\(Int(crop.minY))") }
            filters += ["scale=\(Int(output.width)):\(Int(output.height))", "fps='min(\(Int(frameRateLimit)),source_fps)'"]
            try await VideoEngine.ffmpegConvert(source: url, destination: file, target: .mp4, videoFilters: filters, videoBitrate: videoBitrate, audioBitrate: audioBitrate, keepsMetadata: false, progress: progress)
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    /// Apple's reader sometimes never hands over the next picture, and then a job would run for ever (seen in one of ten runs under load): the same idea as `VisionLimit`.
    struct Stalled: Error {}
    /// Far more than the slowest picture of a huge video takes.
    nonisolated(unsafe) static var stallSeconds: Double = 120
    #if DEBUG
    /// Tests: how many of the next writes stop answering, as Apple's reader does.
    nonisolated(unsafe) static var simulatedStalls = 0
    #endif

    private final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var ends: [() -> Void] = []
        private(set) var stalled = false

        func touch() { lock.withLock { last = Date() } }
        func onStall(_ end: @escaping () -> Void) { lock.withLock { ends.append(end) } }

        /// Whether it just stalled; then everything waiting is let go.
        func check(limit: Double) -> Bool {
            let waiting: [() -> Void]? = lock.withLock {
                guard !stalled, Date().timeIntervalSince(last) > limit else { return nil }
                stalled = true
                return ends
            }
            waiting?.forEach { $0() }
            return waiting != nil
        }
    }

    private static func encode(_ asset: AVURLAsset, crop: CGRect?, output: CGSize, frameRateLimit: Double, videoBitrate: Int, audioBitrate: Int, overlay: (@Sendable (CIImage, CMTime) -> CIImage)?, to file: URL, progress: @escaping (Double) -> Void) async throws {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw AppError.invalidInput(tr("No video track found.", "Keine Videospur gefunden.")) }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let rate = Double(try await videoTrack.load(.nominalFrameRate))

        let composition = try await VideoOps.videoComposition(for: asset, crop: crop, outputSize: output, filter: overlay, filling: true, normalColours: true, frameRateLimit: frameRateLimit)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.videoComposition = composition
        // Sharing the reader's buffers crashed in Apple's reader once in about ten runs under load.
        videoOutput.alwaysCopiesSampleData = true
        reader.add(videoOutput)
        let channels = 2, sampleRate = 44_100
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(mix)
            audioOutput = mix
        }

        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let keyFrames = max(30, Int(min(rate > 0 ? rate : 30, frameRateLimit)) * 2)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(output.width), AVVideoHeightKey: Int(output.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitrate, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoMaxKeyFrameIntervalKey: keyFrames],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: audioBitrate])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw AVExporter.failure(reader.error) }
        guard writer.startWriting() else { throw AVExporter.failure(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let watch = Watch()
        let gate = ReaderGate()
        #if DEBUG
        let stallHere = simulatedStalls > 0
        if stallHere { simulatedStalls -= 1 }
        #else
        let stallHere = false
        #endif
        /// Hands over samples whenever the encoder can take them, until none are left.
        func pump(_ source: AVAssetReaderOutput, into input: AVAssetWriterInput, name: String, report: Bool) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let finished = NSLock()
                var ended = false
                let end = {
                    finished.withLock {
                        if !ended { ended = true; done.resume() }
                    }
                }
                watch.onStall(end)
                let pair = UncheckedBox((input, source))
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "twistel.video.\(name)")) {
                    let (input, source) = pair.value
                    while input.isReadyForMoreMediaData {
                        // A hang like Apple's: this thread is simply left behind.
                        if stallHere { DispatchSemaphore(value: 0).wait() }
                        guard let sample = gate.next(from: source), !gate.isClosed, input.append(sample) else {
                            input.markAsFinished()
                            end()
                            return
                        }
                        watch.touch()
                        if report, duration > 0 { progress(min(0.99, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / duration)) }
                    }
                }
            }
        }
        let limit = stallSeconds
        let watcher = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(limit / 4, 5)))
                if watch.check(limit: limit) { gate.cancel(reader) }
            }
        }
        defer { watcher.cancel() }
        let readerBox = UncheckedBox(reader)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await pump(videoOutput, into: videoInput, name: "picture", report: true) }
                if let audioOutput, let audioInput { group.addTask { await pump(audioOutput, into: audioInput, name: "sound", report: false) } }
            }
        } onCancel: {
            // Not on the caller's thread (Cancel is clicked on the main thread) and not while a picture is being read: see `ReaderGate`.
            DispatchQueue.global().async { gate.cancel(readerBox.value) }
        }
        if watch.stalled {
            writer.cancelWriting()
            throw Stalled()
        }
        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw AVExporter.failure(reader.error)
        }
        try await AVExporter.finish(writer, limit: stallSeconds)
    }
}

/// Keeps `cancelReading` away from a running `copyNextSampleBuffer`: AVFoundation frees the reader's insides at once while the other thread is still in
/// them, and the app crashes (found with a crash report: one thread in each; about once in eight test runs under load, also when clicking Cancel).
final class ReaderGate: @unchecked Sendable {
    private var reading = pthread_rwlock_t()
    private let lock = NSLock()
    private var closed = false

    init() { pthread_rwlock_init(&reading, nil) }
    deinit { pthread_rwlock_destroy(&reading) }

    var isClosed: Bool { lock.withLock { closed } }

    /// The next sample, or nil once the reader is cancelled. Several outputs can read at the same time.
    func next(from output: AVAssetReaderOutput) -> CMSampleBuffer? {
        pthread_rwlock_rdlock(&reading)
        defer { pthread_rwlock_unlock(&reading) }
        return isClosed ? nil : output.copyNextSampleBuffer()
    }

    /// Cancels once nobody is reading. A read that does not come back (the hang this is also for) is left behind: then the reader stays as it is, nobody reads from it any more.
    func cancel(_ reader: AVAssetReader, waiting seconds: Double = 2) {
        lock.withLock { closed = true }
        let end = Date().addingTimeInterval(seconds)
        while pthread_rwlock_trywrlock(&reading) != 0 {
            guard Date() < end else { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { pthread_rwlock_unlock(&reading) }
        reader.cancelReading()
    }
}
