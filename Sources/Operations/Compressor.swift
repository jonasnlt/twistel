import AVFoundation
import Foundation

enum Compressor {
    static func compress(_ url: URL, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let format = FileFormat.detect(url) else { throw AppError.unreadable(url) }
        switch format.category {
        case .image:
            try await compressImage(url, format: format, preset: preset, resizeLongEdge: resizeLongEdge, targetBytes: targetBytes, to: destination, progress: progress)
        case .video:
            try await VideoOps.compress(url, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .audio:
            try await compressAudio(url, format: format, preset: preset, targetBytes: targetBytes, to: destination, progress: progress)
        case .document where format == .pdf:
            let report = UncheckedBox(progress)
            try await PDFCompression.compress(url, preset: preset, to: destination, progress: { report.value($0) })
        default:
            throw AppError.invalidInput(tr("\(format.displayName) files can't be compressed. Convert to ZIP instead.", "\(format.displayName)-Dateien lassen sich nicht verkleinern. Wandle sie stattdessen in ZIP um."))
        }
    }

    static func outputFormat(for url: URL) -> FileFormat {
        guard let format = FileFormat.detect(url) else { return .jpg }
        switch format.category {
        case .image:
            switch format {
            case .png, .bmp, .tiff, .svg: return .jpg
            case .avif, .webp: return ImageIOBridge.canEncodeNatively(format) || FFmpeg.isAvailable ? format : .jpg
            default: return format
            }
        case .video:
            return VideoEngine.nativeTargets.contains(format) ? format : (FFmpeg.isAvailable ? format : .mp4)
        case .audio:
            return format == .mp3 && FFmpeg.isAvailable ? .mp3 : .m4a
        default:
            return format
        }
    }

    static func compressImage(_ url: URL, format: FileFormat, preset: CompressionPreset, resizeLongEdge: Int, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        var image = try ImageIOBridge.load(url)
        if resizeLongEdge > 0 { image = ImageIOBridge.resized(image, longEdge: resizeLongEdge) }
        let output = outputFormat(for: url)
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipLast && image.alphaInfo != .noneSkipFirst
        let finalFormat: FileFormat = (output == .jpg && hasAlpha && format == .png) ? .png : output
        progress(0.2)

        guard let targetBytes else {
            if finalFormat == .png {
                let scaled = preset == .strong ? ImageIOBridge.resized(image, longEdge: Int(Double(max(image.width, image.height)) * 0.7)) : image
                try ImageIOBridge.write(scaled, to: destination, format: .png)
            } else {
                try await ImageIOBridge.writeAnyFormat(image, to: destination, format: finalFormat, quality: preset.imageQuality)
            }
            progress(1)
            return
        }

        var low = 0.15, high = 0.95
        var candidate = image
        var attempts = 0
        var best: Double?
        while attempts < 12 {
            attempts += 1
            let quality = (low + high) / 2
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat == .png ? .jpg : finalFormat, quality: quality)
            let size = FileSizeFormatter.size(of: destination)
            progress(0.2 + 0.7 * Double(attempts) / 12)
            if size <= targetBytes {
                best = quality
                low = quality
                if Double(size) > Double(targetBytes) * 0.9 { break }
            } else {
                high = quality
            }
            if high - low < 0.03 {
                if best == nil {
                    let shrink = 0.8
                    candidate = ImageIOBridge.scaled(candidate, to: CGSize(width: Double(candidate.width) * shrink, height: Double(candidate.height) * shrink))
                    low = 0.15
                    high = 0.95
                    guard candidate.width > 64 else { break }
                } else {
                    break
                }
            }
        }
        if let best {
            try await ImageIOBridge.writeAnyFormat(candidate, to: destination, format: finalFormat == .png ? .jpg : finalFormat, quality: best)
        }
        progress(1)
    }

    static func compressAudio(_ url: URL, format: FileFormat, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        let bitrate = audioBitrate(preset: preset, targetBytes: targetBytes, duration: info.duration, sourceBitrate: info.estimatedBitrate)
        let output = outputFormat(for: url)
        if output == .m4a, await MediaInfo.isNativelyReadable(url) {
            // The encoder may overshoot a little (a real recording: 300.9 KB for a 300 KB target); then once more, 10 % lower.
            try await VideoEngine.nativeWithFallback(destination: destination) {
                var rate = bitrate
                for attempt in 0..<3 {
                    try await AVExporter.exportAAC(asset: AVURLAsset(url: url), to: destination, bitrate: rate, progress: progress)
                    guard let targetBytes, FileSizeFormatter.size(of: destination) > targetBytes, attempt < 2, rate > 24_000 else { return }
                    rate = max(24_000, Int(Double(rate) * 0.9 * Double(targetBytes) / Double(FileSizeFormatter.size(of: destination))))
                }
            } fallback: {
                try await AudioEngine.ffmpegConvert(source: url, destination: destination, target: output, bitrate: bitrate, progress: progress)
            }
            return
        }
        try await AudioEngine.ffmpegConvert(source: url, destination: destination, target: output, bitrate: bitrate, progress: progress)
    }

    /// The preset's bitrate, or the one that fits the target size. Never more than 80 % of the source's own bitrate:
    /// a 96 kbit/s file re-encoded at 128 kbit/s would get bigger and worse.
    static func audioBitrate(preset: CompressionPreset, targetBytes: Int64?, duration: Double, sourceBitrate: Double) -> Int {
        var bitrate = preset.audioBitrate
        if let targetBytes, duration > 0 {
            bitrate = Int(Double(targetBytes) * 8 * 0.96 / duration)
        }
        if sourceBitrate > 0 { bitrate = min(bitrate, Int(sourceBitrate * 0.8)) }
        return max(24_000, min(320_000, bitrate))
    }
}

// MARK: Presets with a size limit (the fan of "Compress")

extension Compressor {
    /// The format a size-limited result gets: pictures and sound as with "Compress", videos always MP4 (H.264).
    static func strictOutputFormat(for url: URL) -> FileFormat {
        FileFormat.detect(url)?.category == .video ? .mp4 : outputFormat(for: url)
    }

    /// At most `limit` bytes, for sure: a result that is still larger is not saved, a message says so. A file already small enough
    /// gets a message too, not a copy.
    static func compressStrictly(_ url: URL, limit: Int64, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let format = FileFormat.detect(url) else { throw AppError.unreadable(url) }
        let size = FileSizeFormatter.size(of: url)
        if size <= limit {
            throw AppError.invalidInput(tr("\u{201C}\(url.lastPathComponent)\u{201D} is already smaller than \(FileSizeFormatter.string(limit)) (\(FileSizeFormatter.string(size))). Nothing was saved.",
                                           "\u{201E}\(url.lastPathComponent)\u{201C} ist schon kleiner als \(FileSizeFormatter.string(limit)) (\(FileSizeFormatter.string(size))). Es wurde nichts gesichert."))
        }
        switch format.category {
        case .image:
            try await compressImage(url, format: format, preset: .balanced, resizeLongEdge: 0, targetBytes: limit, to: destination, progress: progress)
        case .audio:
            try await compressAudio(url, format: format, preset: .balanced, targetBytes: limit, to: destination, progress: progress)
        case .video:
            try await compressVideoStrictly(url, limit: limit, to: destination, progress: progress)
        default:
            throw AppError.invalidInput(tr("\(format.displayName) files can't be compressed to a size.", "\(format.displayName)-Dateien lassen sich nicht auf eine Größe verkleinern."))
        }
        let written = FileSizeFormatter.size(of: destination)
        guard written > 0, written <= limit else {
            try? FileManager.default.removeItem(at: destination)
            throw AppError.invalidInput(tr("\u{201C}\(url.lastPathComponent)\u{201D} can\u{2019}t be made as small as \(FileSizeFormatter.string(limit)) (the smallest was \(FileSizeFormatter.string(written))). Nothing was saved; choose a larger size or \u{201C}Customize \u{2026}\u{201D}.",
                                           "\u{201E}\(url.lastPathComponent)\u{201C} lässt sich nicht auf \(FileSizeFormatter.string(limit)) verkleinern (am kleinsten: \(FileSizeFormatter.string(written))). Es wurde nichts gesichert; wähle eine größere Grenze oder \u{201E}Anpassen \u{2026}\u{201C}."))
        }
    }

    /// Like a video for sending (`VideoPresets`): data rate and picture size from the limit, then tried again with less until it fits.
    static func compressVideoStrictly(_ url: URL, limit: Int64, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        var size = info.naturalSize
        if size == .zero, let probed = await FFmpeg.probeStreams(url)?.size { size = probed }
        guard size != .zero, info.duration > 0 else { throw AppError.unreadable(url) }
        let audioBitrate = 96_000
        let plan = VideoPresets.sendingPlan(duration: info.duration, sourceBitrate: info.estimatedBitrate, sourceSize: size,
                                            longEdge: min(1920, Int(max(size.width, size.height))), maxBytes: limit, audioBitrate: audioBitrate)
        var rate = plan.videoBitrate, edge = plan.longEdge
        let tries = 4
        for attempt in 0..<tries {
            let done = 1 - pow(0.5, Double(attempt)), share = pow(0.5, Double(attempt + 1))
            try await VideoPresets.write(url, crop: nil, output: VideoPresets.fitted(size, longEdge: edge), frameRateLimit: 30, videoBitrate: rate,
                                         audioBitrate: audioBitrate, to: destination) { progress(done + $0 * share) }
            let written = FileSizeFormatter.size(of: destination)
            guard written > limit, attempt < tries - 1 else { break }
            DiagnosticLog.log("video to a size: \(written) bytes over the limit at \(edge) px, trying again")
            rate = max(150_000, Int(Double(rate) * Double(limit) / Double(written) * 0.9))
            if attempt > 0 { edge = edge > 854 ? 854 : 640 }
        }
        progress(1)
    }
}
