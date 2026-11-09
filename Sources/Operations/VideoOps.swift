import AVFoundation
import CoreImage
import Foundation

enum VideoOps {
    static func trim(_ url: URL, start: Double, end: Double, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let format = FileFormat.detect(url) ?? .mp4
        let range = AVExporter.timeRange(start: start, end: end)
        if VideoEngine.nativeTargets.contains(format), await MediaInfo.isNativelyReadable(url) {
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: format, preset: AVAssetExportPresetPassthrough, timeRange: range, progress: progress)
            return
        }
        let args = ["-ss", FFmpeg.timecode(start), "-to", FFmpeg.timecode(end), "-i", url.path, "-c", "copy", "-avoid_negative_ts", "make_zero", destination.path]
        try await FFmpeg.run(args, purpose: tr("Trimming video", "Video kürzen"), duration: end - start, progress: progress)
    }

    static func split(_ url: URL, at points: [Double], duration: Double, into folder: URL, progress: @escaping (Double) -> Void) async throws -> [URL] {
        let sorted = ([0] + points.filter { $0 > 0 && $0 < duration }.sorted() + [duration])
        var outputs: [URL] = []
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<(sorted.count - 1) {
            let start = sorted[index], end = sorted[index + 1]
            guard end - start > 0.05 else { continue }
            let output = folder.appendingPathComponent("\(base) \(tr("part", "Teil")) \(index + 1).\(url.pathExtension)")
            let count = Double(sorted.count - 1)
            try await trim(url, start: start, end: end, to: output) { p in progress((Double(index) + p) / count) }
            outputs.append(output)
        }
        return outputs
    }

    /// `filling`: the picture covers the output, a pixel lost to rounding is cut off rather than left black. `normalColours`: HDR becomes normal video colours.
    static func videoComposition(for asset: AVAsset, crop: CGRect?, outputSize: CGSize?, filter: ((CIImage, CMTime) -> CIImage)? = nil,
                                 filling: Bool = false, normalColours: Bool = false, frameRateLimit: Double? = nil) async throws -> AVVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw AppError.invalidInput(tr("No video track found.", "Keine Videospur gefunden.")) }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let cropRect = crop ?? CGRect(origin: .zero, size: orientedSize)
        let renderSize = outputSize ?? cropRect.size

        let composition = AVMutableVideoComposition(asset: asset) { request in
            var image = request.sourceImage
            let flippedCrop = CGRect(x: cropRect.minX, y: orientedSize.height - cropRect.maxY, width: cropRect.width, height: cropRect.height)
            if let filter { image = filter(image, request.compositionTime) }
            image = image.cropped(to: flippedCrop)
            image = image.transformed(by: CGAffineTransform(translationX: -flippedCrop.minX, y: -flippedCrop.minY))
            let scale = filling ? max(renderSize.width / flippedCrop.width, renderSize.height / flippedCrop.height)
                : min(renderSize.width / flippedCrop.width, renderSize.height / flippedCrop.height)
            if abs(scale - 1) > 0.001 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            request.finish(with: image.cropped(to: CGRect(origin: .zero, size: renderSize)), context: nil)
        }
        composition.renderSize = CGSize(width: (renderSize.width / 2).rounded(.down) * 2, height: (renderSize.height / 2).rounded(.down) * 2)
        let rate = fps > 0 ? Double(fps).rounded() : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(rate, frameRateLimit ?? rate)))
        if normalColours {
            composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
            composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }
        return composition
    }

    static func crop(_ url: URL, rect: CGRect, outputSize: CGSize?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        if await MediaInfo.isNativelyReadable(url) {
            let composition = try await videoComposition(for: asset, crop: rect, outputSize: outputSize)
            try await AVExporter.export(asset: asset, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, videoComposition: composition, progress: progress)
            return
        }
        var filters = ["crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))"]
        if let outputSize { filters.append("scale=\(Int(outputSize.width)):\(Int(outputSize.height))") }
        try await VideoEngine.ffmpegConvert(source: url, destination: destination, target: .mp4, videoFilters: filters, progress: progress)
    }

    static func changeSpeed(_ url: URL, factor: Double, preservePitch: Bool, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        guard await MediaInfo.isNativelyReadable(url) else {
            let videoFilter = "setpts=\(1 / factor)*PTS"
            var audioFilter = preservePitch ? atempoChain(factor) : "asetrate=44100*\(factor),aresample=44100"
            if audioFilter.isEmpty { audioFilter = "anull" }
            let duration = (await FFmpeg.probeDuration(url) ?? 0) / factor
            let args = ["-i", url.path, "-filter_complex", "[0:v]\(videoFilter)[v];[0:a]\(audioFilter)[a]", "-map", "[v]", "-map", "[a]?"] + VideoEngine.codecArguments(for: .mp4) + [destination.path]
            try await FFmpeg.run(args, purpose: tr("Changing speed", "Tempo ändern"), duration: duration, progress: progress)
            return
        }
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        let scaled = CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        for source in videoTracks {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(fullRange, of: source, at: .zero)
            track.scaleTimeRange(fullRange, toDuration: scaled)
            track.preferredTransform = try await source.load(.preferredTransform)
        }
        for source in audioTracks {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(fullRange, of: source, at: .zero)
            track.scaleTimeRange(fullRange, toDuration: scaled)
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
            audioMixParams.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioMixParams
        try await AVExporter.export(asset: composition, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, audioMix: audioMixParams.isEmpty ? nil : mix, progress: progress)
    }

    static func atempoChain(_ factor: Double) -> String {
        var remaining = factor
        var parts: [String] = []
        while remaining > 2.0 { parts.append("atempo=2.0"); remaining /= 2.0 }
        while remaining < 0.5 { parts.append("atempo=0.5"); remaining /= 0.5 }
        parts.append(String(format: "atempo=%.4f", remaining))
        return parts.joined(separator: ",")
    }

    static func join(_ urls: [URL], to destination: URL, progress: @escaping (Double) -> Void) async throws {
        var allNative = true
        for url in urls {
            if !(await MediaInfo.isNativelyReadable(url)) { allNative = false }
        }
        if allNative {
            let composition = AVMutableComposition()
            let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            var cursor = CMTime.zero
            var canvas: CGSize?
            var instructions: [AVVideoCompositionInstruction] = []
            for url in urls {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: duration)
                if let source = try await asset.loadTracks(withMediaType: .video).first, let videoTrack {
                    try videoTrack.insertTimeRange(range, of: source, at: cursor)
                    let natural = try await source.load(.naturalSize)
                    let transform = try await source.load(.preferredTransform)
                    let oriented = CGRect(origin: .zero, size: natural).applying(transform)
                    let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                    if canvas == nil { canvas = size }
                    let target = canvas ?? size
                    let scale = min(target.width / size.width, target.height / size.height)
                    let translate = CGAffineTransform(translationX: (target.width - size.width * scale) / 2 - oriented.minX * scale, y: (target.height - size.height * scale) / 2 - oriented.minY * scale)
                    var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
                    layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(translate), at: cursor)
                    instructions.append(AVVideoCompositionInstruction(configuration: .init(layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                                                                                           timeRange: CMTimeRange(start: cursor, duration: duration))))
                }
                if let source = try await asset.loadTracks(withMediaType: .audio).first, let audioTrack {
                    try audioTrack.insertTimeRange(range, of: source, at: cursor)
                }
                cursor = CMTimeAdd(cursor, duration)
            }
            let videoComposition = AVVideoComposition(configuration: .init(frameDuration: CMTime(value: 1, timescale: 30), instructions: instructions,
                                                                           renderSize: canvas ?? CGSize(width: 1920, height: 1080)))
            try await AVExporter.export(asset: composition, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, videoComposition: videoComposition, progress: progress)
            return
        }
        var args: [String] = []
        for url in urls { args += ["-i", url.path] }
        let first = await MediaInfo.load(urls[0])
        let w = Int(first.naturalSize.width), h = Int(first.naturalSize.height)
        var filter = ""
        for index in urls.indices {
            filter += "[\(index):v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(index)];"
            filter += "[\(index):a]aresample=48000,aformat=channel_layouts=stereo[a\(index)];"
        }
        filter += urls.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(urls.count):v=1:a=1[v][a]"
        args += ["-filter_complex", filter, "-map", "[v]", "-map", "[a]"] + VideoEngine.codecArguments(for: .mp4) + [destination.path]
        var total = 0.0
        for url in urls { total += await FFmpeg.probeDuration(url) ?? 0 }
        try await FFmpeg.run(args, purpose: tr("Joining videos", "Videos verbinden"), duration: total, progress: progress)
    }

    static func snapshot(_ url: URL, at seconds: Double) async throws -> CGImage {
        let picture = await TimeLimit.optional(seconds: MediaInfo.answerSeconds, what: "Reading a video frame") { () -> CGImage? in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
        if let picture { return picture }
        try Task.checkCancellation()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try await FFmpeg.run(["-ss", FFmpeg.timecode(seconds), "-i", url.path, "-frames:v", "1", temp.path], purpose: tr("Extracting frame", "Standbild sichern"))
        guard let frame = try? ImageIOBridge.load(temp) else { throw AppError.unreadable(url) }
        return frame
    }

    /// Covers places of the picture for their times, then checks the result (`MediaRedactionCheck`): only the first picture track and
    /// the sound come along, no subtitles, cover picture, chapters or metadata. If the check finds anything, it throws and nothing is saved.
    static func redact(_ url: URL, redactions: [Redaction], displaySize: CGSize, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let filled: Bool
        if await MediaInfo.isNativelyReadable(url) {
            filled = false
            try await redactNatively(url, redactions: redactions, displaySize: displaySize, to: destination) { progress($0 * 0.9) }
        } else {
            filled = true
            var filters: [String] = []
            for r in redactions {
                let x = Int(r.rect.minX), y = Int(r.rect.minY), w = Int(r.rect.width), h = Int(r.rect.height)
                let enable = r.end.isFinite ? ":enable='between(t,\(r.start),\(r.end))'" : ":enable='gte(t,\(r.start))'"
                switch r.style {
                case .solid: filters.append("drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill\(enable)")
                case .blur, .pixelate: filters.append("drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=gray:t=fill\(enable)")
                }
            }
            filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
            // The first real picture stream (V: not a cover picture) and the sound; no subtitles, data, chapters or metadata.
            let args = ["-i", url.path, "-map", "0:V:0", "-map", "0:a?", "-sn", "-dn"] + Privacy.removeAllArguments
                + ["-vf", filters.joined(separator: ",")] + VideoEngine.codecArguments(for: .mp4) + [destination.path]
            try await FFmpeg.run(args, purpose: tr("Redacting", "Wird geschwärzt"), duration: await FFmpeg.probeDuration(url), privacy: false) { progress($0 * 0.9) }
        }
        try Task.checkCancellation()
        try MediaRedactionCheck.requireNothing(await MediaRedactionCheck.videoProblems(original: url, output: destination, redactions: redactions,
                                                                                         displaySize: displaySize, filled: filled), what: "video redaction")
        progress(1)
    }

    private static func redactNatively(_ url: URL, redactions: [Redaction], displaySize: CGSize, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        // A new composition with only what the result needs: the first picture track and the sound tracks. Subtitles, captions,
        // timecode, a second camera angle and chapters of the original stay behind.
        let duration = try await asset.load(.duration)
        let whole = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()
        guard let picture = try await asset.loadTracks(withMediaType: .video).first,
              let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError.invalidInput(tr("No video track found.", "Keine Videospur gefunden."))
        }
        try target.insertTimeRange(whole, of: picture, at: .zero)
        target.preferredTransform = try await picture.load(.preferredTransform)
        for sound in try await asset.loadTracks(withMediaType: .audio) {
            if let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(whole, of: sound, at: .zero)
            }
        }
        let video = try await videoComposition(for: composition, crop: nil, outputSize: nil) { image, time in
            let seconds = CMTimeGetSeconds(time)
            let active = redactions.filter { seconds >= $0.start && seconds <= $0.end }
            guard !active.isEmpty else { return image }
            let scaleX = image.extent.width / displaySize.width
            let scaleY = image.extent.height / displaySize.height
            let scaled = active.map { r -> Redaction in
                var copy = r
                copy.rect = CGRect(x: r.rect.minX * scaleX, y: r.rect.minY * scaleY, width: r.rect.width * scaleX, height: r.rect.height * scaleY)
                return copy
            }
            return ImageOps.redact(image, redactions: scaled, flipped: true)
        }
        // No metadata at all: the original's title or place could name what is covered.
        try await AVExporter.export(asset: composition, to: destination, format: .mp4, preset: AVAssetExportPresetHighestQuality, videoComposition: video,
                                    metadata: [], progress: progress)
    }

    static func compress(_ url: URL, preset: CompressionPreset, targetBytes: Int64?, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        let target = FileFormat.detect(url) ?? .mp4
        let outputFormat: FileFormat = VideoEngine.nativeTargets.contains(target) ? target : .mp4
        if let targetBytes, info.duration > 0 {
            let totalBits = Double(targetBytes) * 8 * 0.94
            let audioBits = Double(min(preset.audioBitrate, 128_000))
            let videoBitrate = max(150_000, Int(totalBits / info.duration - audioBits))
            let scale = preset.videoScale
            var filters: [String] = []
            if scale < 1 { filters.append("scale=trunc(iw*\(scale)/2)*2:trunc(ih*\(scale)/2)*2") }
            try await VideoEngine.ffmpegConvert(source: url, destination: destination, target: outputFormat, videoFilters: filters, videoBitrate: videoBitrate, audioBitrate: Int(audioBits), progress: progress)
            return
        }
        if await MediaInfo.isNativelyReadable(url) {
            let longEdge = max(info.naturalSize.width, info.naturalSize.height) * preset.videoScale
            let presetName: String
            if preset == .strong || longEdge <= 1280 {
                presetName = longEdge > 1280 ? AVAssetExportPreset1280x720 : (longEdge > 960 ? AVAssetExportPreset960x540 : AVAssetExportPreset640x480)
            } else {
                presetName = longEdge > 1920 ? AVAssetExportPreset1920x1080 : AVAssetExportPreset1280x720
            }
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: outputFormat, preset: presetName, progress: progress)
            return
        }
        let videoBitrate = Int(max(300_000, info.estimatedBitrate * preset.videoBitrateFactor))
        var filters: [String] = []
        if preset.videoScale < 1 { filters.append("scale=trunc(iw*\(preset.videoScale)/2)*2:trunc(ih*\(preset.videoScale)/2)*2") }
        try await VideoEngine.ffmpegConvert(source: url, destination: destination, target: outputFormat, videoFilters: filters, videoBitrate: videoBitrate, audioBitrate: preset.audioBitrate, progress: progress)
    }
}

// MARK: Remove the sound

extension VideoOps {
    /// The containers Apple writes without re-encoding: everything else (MKV, WebM, AVI, WMV) goes through ffmpeg.
    static let nativeAudioRemoval: Set<FileFormat> = [.mp4, .mov]

    /// The video without its sound, in the same container. The pictures are copied, never encoded again: every packet stays the same,
    /// and with it rotation, HDR and Dolby Vision. A video without sound gets a message, not a copy.
    static func removeAudio(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let format = FileFormat.detect(url) ?? .mp4
        if nativeAudioRemoval.contains(format), await MediaInfo.isNativelyReadable(url) {
            let asset = AVURLAsset(url: url)
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw noSound(url) }
            let videos = try await asset.loadTracks(withMediaType: .video)
            guard !videos.isEmpty else { throw AppError.invalidInput(tr("No video track found.", "Keine Videospur gefunden.")) }
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            let composition = AVMutableComposition()
            for track in videos {
                guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try copy.insertTimeRange(range, of: track, at: .zero)
                copy.preferredTransform = try await track.load(.preferredTransform)
            }
            // Apple's timed metadata (e.g. the camera's tracks of an iPhone video) stays; places are filtered with the file's metadata.
            for track in try await asset.loadTracks(withMediaType: .metadata) {
                if let copy = composition.addMutableTrack(withMediaType: .metadata, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? copy.insertTimeRange(range, of: track, at: .zero)
                }
            }
            let metadata = try await asset.load(.metadata)
            try await AVExporter.export(asset: composition, to: destination, format: format, preset: AVAssetExportPresetPassthrough,
                                        metadata: metadata, progress: progress)
            return
        }
        guard FFmpeg.isAvailable else { throw AppError.ffmpegMissing(tr("removing the sound from \(format.displayName) videos", "das Entfernen des Tons aus \(format.displayName)-Videos")) }
        guard await FFmpeg.probeHasAudio(url) ?? true else { throw noSound(url) }
        let tags = await FFmpeg.tagKeys(of: [url])
        // All streams but sound (pictures, subtitles, attachments); data streams Apple writes stop ffmpeg ("codec none"), so they stay out.
        let args = ["-i", url.path, "-map", "0", "-map", "-0:a", "-map", "-0:d?", "-c", "copy"]
            + Privacy.ffmpegArguments(keepsMetadata: true, tagKeys: tags) + [destination.path]
        try await FFmpeg.run(args, purpose: tr("Removing the sound", "Ton entfernen"), duration: await FFmpeg.probeDuration(url), progress: progress)
    }

    static func noSound(_ url: URL) -> AppError {
        .invalidInput(tr("\u{201C}\(url.lastPathComponent)\u{201D} has no sound to remove.", "\u{201E}\(url.lastPathComponent)\u{201C} hat keinen Ton, der sich entfernen ließe."))
    }
}

// MARK: 1080p and 720p (the fan of "Compress")

extension VideoOps {
    /// The box a video must fit in, turned as it is shown: 1920 × 1080 for 1080p (or 1080 × 1920 standing), 1280 × 720 for 720p.
    static func box(lines: Int, for size: CGSize) -> CGSize {
        let long = CGFloat(lines == 1080 ? 1920 : 1280), short = CGFloat(lines)
        return size.width >= size.height ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    /// The video made no larger than 1080p or 720p, as MP4 (H.264, HDR becomes normal colours as with "Compress"); never enlarged (a
    /// video that already fits gets a message). Apple's export presets were not used: they keep a standing 4:3 video at 1440 × 1920 and
    /// can make the file larger than an HEVC original. Here the size is exact and the data rate at most 8 (1080p) or 5 (720p) Mbit/s
    /// and never more than 80 % of the original's; a result that is not smaller than the original is not saved.
    static func shrink(_ url: URL, lines: Int, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let info = await MediaInfo.load(url)
        var size = info.naturalSize
        if size == .zero, let probed = await FFmpeg.probeStreams(url)?.size { size = probed }
        guard size != .zero else { throw AppError.unreadable(url) }
        let box = box(lines: lines, for: size)
        guard size.width > box.width || size.height > box.height else {
            throw AppError.invalidInput(tr("\u{201C}\(url.lastPathComponent)\u{201D} is already \(lines)p or smaller (\(Int(size.width)) × \(Int(size.height))). Nothing was saved.",
                                           "\u{201E}\(url.lastPathComponent)\u{201C} hat schon höchstens \(lines)p (\(Int(size.width)) × \(Int(size.height))). Es wurde nichts gesichert."))
        }
        let scale = min(box.width / size.width, box.height / size.height)
        let output = CGSize(width: max(2, (size.width * scale / 2).rounded(.down) * 2), height: max(2, (size.height * scale / 2).rounded(.down) * 2))
        let wanted = lines == 1080 ? 8_000_000 : 5_000_000
        let rate = info.estimatedBitrate > 0 ? min(wanted, max(Int(info.estimatedBitrate * 0.8), 1_000_000)) : wanted
        try await VideoPresets.write(url, crop: nil, output: output, frameRateLimit: 60, videoBitrate: rate, audioBitrate: 128_000, to: destination, progress: progress)
        let original = FileSizeFormatter.size(of: url), written = FileSizeFormatter.size(of: destination)
        if written >= original {
            try? FileManager.default.removeItem(at: destination)
            throw AppError.invalidInput(tr("\u{201C}\(url.lastPathComponent)\u{201D} would not get smaller at \(lines)p (\(FileSizeFormatter.string(written)) instead of \(FileSizeFormatter.string(original))). Nothing was saved.",
                                           "\u{201E}\(url.lastPathComponent)\u{201C} würde mit \(lines)p nicht kleiner (\(FileSizeFormatter.string(written)) statt \(FileSizeFormatter.string(original))). Es wurde nichts gesichert."))
        }
    }
}
