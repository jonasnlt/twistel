import AVFoundation
import Foundation

struct MediaInfo {
    var duration: Double = 0
    var naturalSize: CGSize = .zero
    var frameRate: Double = 0
    var hasAudio: Bool = false
    var hasVideo: Bool = false
    var estimatedBitrate: Double = 0
    var channelCount: Int = 0
    var sampleRate: Double = 0

    /// Longest wait for AVFoundation to read what is in a file; such a question normally takes a fraction of a second.
    static let answerSeconds = 60.0

    static func load(_ url: URL) async -> MediaInfo {
        var info = await TimeLimit.optional(seconds: answerSeconds, what: "Reading the media file") { await nativeInfo(url) } ?? MediaInfo()
        if info.duration == 0 || (!info.hasAudio && !info.hasVideo) {
            if let probed = await FFmpeg.probeDuration(url) { info.duration = probed }
            // Apple can't read MKV, AVI, WMV and the like. Without a size, Crop and Redact would ask ffmpeg for a picture of 0 × 0.
            if let streams = await FFmpeg.probeStreams(url) {
                info.hasVideo = streams.size != nil
                info.naturalSize = streams.size ?? .zero
                info.hasAudio = streams.sampleRate != nil
                info.sampleRate = streams.sampleRate ?? 0
            }
        }
        return info.checked
    }

    /// The numbers as a file gave them can be anything (a duration of "not a number", a picture of 10^20 pixels): what makes no
    /// sense counts as unknown, so later arithmetic never meets such a value.
    var checked: MediaInfo {
        var info = self
        info.duration = SafeNumber.seconds(duration) ?? 0
        let sides = 0...100_000.0
        if !naturalSize.width.isFinite || !naturalSize.height.isFinite || !sides.contains(Double(naturalSize.width)) || !sides.contains(Double(naturalSize.height)) {
            info.naturalSize = .zero
        }
        if !frameRate.isFinite || !(0...1_000).contains(frameRate) { info.frameRate = 0 }
        if !estimatedBitrate.isFinite || estimatedBitrate < 0 { info.estimatedBitrate = 0 }
        if !sampleRate.isFinite || !(0...10_000_000).contains(sampleRate) { info.sampleRate = 0 }
        if !(0...1_024).contains(channelCount) { info.channelCount = 0 }
        return info
    }

    private static func nativeInfo(_ url: URL) async -> MediaInfo {
        var info = MediaInfo()
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            info.duration = CMTimeGetSeconds(duration)
        }
        if let tracks = try? await asset.load(.tracks) {
            for track in tracks {
                if track.mediaType == .video {
                    info.hasVideo = true
                    if let size = try? await track.load(.naturalSize),
                       let transform = try? await track.load(.preferredTransform) {
                        let rect = CGRect(origin: .zero, size: size).applying(transform)
                        info.naturalSize = CGSize(width: abs(rect.width), height: abs(rect.height))
                    }
                    if let fps = try? await track.load(.nominalFrameRate) { info.frameRate = Double(fps) }
                    if let rate = try? await track.load(.estimatedDataRate) { info.estimatedBitrate += Double(rate) }
                } else if track.mediaType == .audio {
                    info.hasAudio = true
                    if let rate = try? await track.load(.estimatedDataRate) { info.estimatedBitrate += Double(rate) }
                    if let descriptions = try? await track.load(.formatDescriptions),
                       let first = descriptions.first,
                       let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
                        info.channelCount = Int(asbd.pointee.mChannelsPerFrame)
                        info.sampleRate = asbd.pointee.mSampleRate
                    }
                }
            }
        }
        return info
    }

    /// False also when AVFoundation does not answer: then ffmpeg takes over.
    static func isNativelyReadable(_ url: URL) async -> Bool {
        await TimeLimit.optional(seconds: answerSeconds, what: "Reading the media file") {
            let asset = AVURLAsset(url: url)
            guard let readable = try? await asset.load(.isReadable), readable else { return false }
            let tracks = (try? await asset.load(.tracks)) ?? []
            return !tracks.isEmpty
        } ?? false
    }
}

enum FileSizeFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}

enum TimeFormatter {
    static func clock(_ seconds: Double, fractionDigits: Int = 2) -> String {
        let clamped = SafeNumber.clampedSeconds(seconds)
        let minutes = Int(clamped) / 60
        let secs = clamped - Double(minutes * 60)
        return String(format: "%d:%0\(3 + fractionDigits).\(fractionDigits)f", minutes, secs)
    }

    static func parseClock(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { String($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return Double(text).flatMap(SafeNumber.seconds) }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return SafeNumber.seconds(total)
    }
}
