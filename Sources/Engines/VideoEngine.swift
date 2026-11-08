import AVFoundation
import Foundation

struct VideoEngine: ConversionEngine {
    static let nativeTargets: Set<FileFormat> = [.mp4, .mov]

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from.category == .video else { return false }
        return to.category == .video || to == .mp3
    }

    func convert(_ request: ConversionRequest) async throws {
        if Self.nativeTargets.contains(request.target), request.sourceFormat != .gif, await MediaInfo.isNativelyReadable(request.source) {
            try await Self.nativeWithFallback(destination: request.destination) {
                let asset = AVURLAsset(url: request.source)
                try await AVExporter.export(asset: asset, to: request.destination, format: request.target, preset: AVAssetExportPresetHighestQuality, progress: request.progress)
            } fallback: {
                try await Self.ffmpegConvert(source: request.source, destination: request.destination, target: request.target, progress: request.progress)
            }
            return
        }
        if request.target == .mp3 {
            guard await Self.hasAudio(request.source) else { throw AppError.noAudioTrack(request.source.lastPathComponent) }
            try await AudioEngine.ffmpegConvert(source: request.source, destination: request.destination, target: .mp3, progress: request.progress)
            return
        }
        try await Self.ffmpegConvert(source: request.source, destination: request.destination, target: request.target, progress: request.progress)
    }

    /// AVFoundation first; ffprobe for containers it cannot open (MKV, WebM, …).
    /// If neither can tell, assume sound and let ffmpeg report the problem.
    static func hasAudio(_ url: URL) async -> Bool {
        if await MediaInfo.load(url).hasAudio { return true }
        return await FFmpeg.probeHasAudio(url) ?? true
    }

    /// AVFoundation can report a file (e.g. some AVI) as readable and still fail to export it.
    /// Then the conversion is retried with ffmpeg, unless the user cancelled.
    static func nativeWithFallback(destination: URL, native: () async throws -> Void, fallback: () async throws -> Void) async throws {
        do {
            try await native()
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            if case AppError.cancelled = error { throw error }
            DiagnosticLog.log("native export failed (\(error)), retrying with ffmpeg")
            try? FileManager.default.removeItem(at: destination)
            try await fallback()
        }
    }

    /// `keepAlpha` keeps transparency where the container allows it (WebM from GIF).
    static func codecArguments(for target: FileFormat, videoBitrate: Int? = nil, audioBitrate: Int? = nil, keepAlpha: Bool = false) -> [String] {
        var args: [String] = []
        switch target {
        case .mp4:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", "-f", "mp4"]
        case .mov:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "mov"]
        case .mkv:
            args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-f", "matroska"]
        case .webm:
            // Without an explicit pixel format ffmpeg picks gbrap for sources with alpha (GIF), which libvpx-vp9 refuses.
            args += ["-c:v", "libvpx-vp9", "-pix_fmt", keepAlpha ? "yuva420p" : "yuv420p", "-b:v", "0", "-crf", "32", "-row-mt", "1", "-c:a", "libopus", "-f", "webm"]
        case .avi:
            args += ["-c:v", "mpeg4", "-vtag", "xvid", "-q:v", "4", "-c:a", "libmp3lame", "-f", "avi"]
        case .wmv:
            args += ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2", "-f", "asf"]
        default:
            break
        }
        if let videoBitrate, target != .webm, target != .avi, target != .wmv {
            args += ["-b:v", "\(videoBitrate)", "-maxrate", "\(Int(Double(videoBitrate) * 1.4))", "-bufsize", "\(videoBitrate * 2)"]
        } else if target == .mp4 || target == .mov || target == .mkv {
            args += ["-crf", "20"]
        }
        if let audioBitrate, target != .avi, target != .wmv { args += ["-b:a", "\(audioBitrate)"] }
        return args
    }

    static func ffmpegConvert(source: URL, destination: URL, target: FileFormat, videoFilters: [String] = [], videoBitrate: Int? = nil, audioBitrate: Int? = nil, keepsMetadata: Bool = true, progress: @escaping (Double) -> Void) async throws {
        let duration = await FFmpeg.probeDuration(source)
        if target == .gif {
            let filters = videoFilters + ["fps=12", "scale='min(640,iw)':-2:flags=lanczos", "split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"]
            let args = ["-i", source.path, "-vf", filters.joined(separator: ","), "-loop", "0", "-f", "gif", destination.path]
            try await FFmpeg.run(args, purpose: tr("Creating GIF", "GIF erstellen"), duration: duration, progress: progress)
            return
        }
        var args = ["-i", source.path] + Privacy.ffmpegArguments(keepsMetadata: keepsMetadata)
        var filters = videoFilters
        if target == .mp4 || target == .mov || target == .mkv || target == .webm {
            filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        args += codecArguments(for: target, videoBitrate: videoBitrate, audioBitrate: audioBitrate, keepAlpha: FileFormat.detect(source) == .gif)
        args.append(destination.path)
        try await FFmpeg.run(args, purpose: tr("Converting to \(target.displayName)", "Umwandeln in \(target.displayName)"), duration: duration, progress: progress)
    }
}
