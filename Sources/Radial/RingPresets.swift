import AppKit
import Foundation

/// A preset in a tool's fan: the tool with fixed values, run at once without its window ("16:9", "90° left", "5 MB", "720p"),
/// or "Customize …", which opens the window.
struct RingPreset: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        /// Cut to this aspect around what matters in the picture (faces, people, the main object), else the middle; full resolution.
        case crop(width: Int, height: Int)
        /// Quarter turns clockwise: 1 right, 3 left, 2 upside down.
        case rotate(turns: Int)
        /// At most this many megabytes per file; a result that does not fit is not saved (a message says why).
        case compressTo(megabytes: Int)
        /// A video no larger than 1920 × 1080 or 1280 × 720 (turned as it is shown).
        case videoSize(lines: Int)
        /// The tool's window.
        case customize
    }

    let tool: ToolID
    let action: Action

    /// For the "More …" list's search and the log, e.g. "crop.16x9".
    var key: String {
        switch action {
        case let .crop(width, height): return "crop.\(width)x\(height)"
        case let .rotate(turns): return "rotate.\(turns)"
        case let .compressTo(megabytes): return "compress.\(megabytes)mb"
        case let .videoSize(lines): return "video.\(lines)p"
        case .customize: return "customize"
        }
    }

    /// The short word in the fan (ring words, both languages).
    var shortLabel: String {
        switch action {
        case let .crop(width, height): return "\(width):\(height)"
        case .rotate(1): return tr("90° right", "90° rechts")
        case .rotate(3): return tr("90° left", "90° links")
        case .rotate: return "180°"
        case let .compressTo(megabytes): return "\(megabytes) MB"
        case let .videoSize(lines): return "\(lines)p"
        case .customize: return tr("Customize …", "Anpassen …")
        }
    }

    /// What it does, in the name pill under the ring, in "More …" and for VoiceOver (after the tool's name).
    var detail: String {
        switch action {
        case .crop(1, 1): return tr("Square 1:1", "Quadratisch 1:1")
        case let .crop(width, height) where width > height:
            return width * 9 == height * 16 ? tr("Widescreen 16:9", "Breitbild 16:9") : tr("Landscape \(width):\(height)", "Querformat \(width):\(height)")
        case let .crop(width, height):
            return width * 16 == height * 9 ? tr("Portrait 9:16 (story)", "Hochformat 9:16 (Story)") : tr("Portrait \(width):\(height)", "Hochformat \(width):\(height)")
        case .rotate(1): return tr("90° to the right", "90° nach rechts")
        case .rotate(3): return tr("90° to the left", "90° nach links")
        case .rotate: return tr("180° (upside down)", "180° (auf den Kopf)")
        case let .compressTo(megabytes): return tr("At most \(megabytes) MB", "Höchstens \(megabytes) MB")
        case .videoSize(1080): return tr("At most 1080p (Full HD)", "Höchstens 1080p (Full HD)")
        case let .videoSize(lines): return tr("At most \(lines)p (HD)", "Höchstens \(lines)p (HD)")
        case .customize: return tr("Open the window", "Fenster öffnen")
        }
    }

    /// "Crop: Widescreen 16:9".
    var title: String { "\(RingWords.toolLabel(tool)): \(detail)" }

    /// SF Symbol, or "ratio.W.H" for the outline of an aspect ratio (drawn by the ring).
    var symbol: String {
        switch action {
        case let .crop(width, height): return "ratio.\(width).\(height)"
        case .rotate(1): return "rotate.right"
        case .rotate(3): return "rotate.left"
        case .rotate: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .compressTo: return "arrow.down.to.line"
        case .videoSize: return "film"
        case .customize: return "slider.horizontal.3"
        }
    }

    var entry: RingEntry {
        RingEntry(id: .preset(self), shortLabel: shortLabel, title: title, symbol: symbol, missing: nil)
    }

    /// The suffix of the result's name: "cropped 16x9", "rotated", "compressed", "1080p".
    var fileSuffix: String {
        switch action {
        case let .crop(width, height): return tr("cropped", "zugeschnitten") + " \(width)x\(height)"
        case .rotate: return tr("rotated", "gedreht")
        case .compressTo: return tr("compressed", "komprimiert")
        case let .videoSize(lines): return "\(lines)p"
        case .customize: return ""
        }
    }
}

/// Which items of the tools ring open a fan, and with what.
enum RingPresets {
    static let aspects: [(Int, Int)] = [(1, 1), (4, 3), (3, 2), (16, 9), (9, 16), (4, 5)]
    static let megabytes = [1, 5, 10, 25]

    /// The presets of a tool for these files; empty: no fan. "Customize …" comes last where the window can take these files.
    static func presets(for tool: ToolID, formats: [FileFormat], ffmpeg: Bool = FFmpeg.isAvailable) -> [RingPreset] {
        guard !formats.isEmpty else { return [] }
        let categories = Set(formats.map(\.category))
        guard categories.count == 1, let category = categories.first else { return [] }
        var actions: [RingPreset.Action]
        switch (tool, category) {
        case (.cropImage, .image):
            actions = aspects.map { .crop(width: $0.0, height: $0.1) }
        case (.rotateImage, .image):
            actions = [.rotate(turns: 3), .rotate(turns: 1), .rotate(turns: 2)]
        case (.compress, .image), (.compress, .audio):
            actions = megabytes.map { .compressTo(megabytes: $0) }
        case (.compress, .video):
            // GIFs have their own way of getting smaller.
            guard !formats.contains(.gif) else { return [] }
            // Apple reads MP4 and MOV; the rest only FFmpeg.
            let native = formats.allSatisfy(VideoOps.nativeAudioRemoval.contains)
            actions = native || ffmpeg ? [.videoSize(lines: 1080), .videoSize(lines: 720)] : []
            // A size limit for videos only with FFmpeg installed; each result is tried again until it fits, or not saved
            // (Compressor.compressStrictly).
            if ffmpeg { actions += megabytes.map { .compressTo(megabytes: $0) } }
        default:
            return []
        }
        guard !actions.isEmpty else { return [] }
        if tool.applies(to: formats) { actions.append(.customize) }
        return actions.map { RingPreset(tool: tool, action: $0) }
    }

    /// A tool the ring offers only through its presets: cropping several pictures (the window takes one).
    static func onlyThroughPresets(_ tool: ToolID, formats: [FileFormat]) -> Bool {
        !tool.applies(to: formats) && !presets(for: tool, formats: formats).isEmpty
    }

    // MARK: Running

    /// The jobs of a preset (not for "Customize …").
    @MainActor
    static func jobs(_ preset: RingPreset, files: [URL]) -> [ToolJob] {
        let session = ToolSession(tool: preset.tool, files: files)
        switch preset.action {
        case let .crop(width, height):
            return files.map { cropJob(session, url: $0, aspect: CGSize(width: width, height: height), suffix: preset.fileSuffix) }
        case let .rotate(turns):
            return RotateImageToolView.jobs(session, quarterTurns: turns, flipH: false, flipV: false)
        case let .compressTo(megabytes):
            return files.map { url in
                let limit = Int64(megabytes) * 1_000_000
                let format = Compressor.strictOutputFormat(for: url)
                let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                                             baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent),
                                                             suffix: preset.fileSuffix, ext: format.fileExtension)
                var job = session.job(tr("Compressing", "Wird verkleinert"), detail: url.lastPathComponent) { progress in
                    [try await StagingArea.writing(destination) { destination in
                        try await Compressor.compressStrictly(url, limit: limit, to: destination, progress: progress)
                    }]
                }
                job.inputs = [url]
                job.reportsSizes = true
                return job
            }
        case let .videoSize(lines):
            return files.map { url in
                let format = FileFormat.mp4
                let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                                             baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent),
                                                             suffix: preset.fileSuffix, ext: format.fileExtension)
                var job = session.job(tr("Compressing", "Wird verkleinert"), detail: url.lastPathComponent) { progress in
                    [try await StagingArea.writing(destination) { destination in
                        try await VideoOps.shrink(url, lines: lines, to: destination, progress: progress)
                    }]
                }
                job.inputs = [url]
                job.reportsSizes = true
                return job
            }
        case .customize:
            return []
        }
    }

    /// One picture cut to an aspect around what matters in it, at full resolution, in its own format (as the crop window saves it).
    private static func cropJob(_ session: ToolSession, url: URL, aspect: CGSize, suffix: String) -> ToolJob {
        let output = ImageToolSupport.outputFormat(for: url)
        let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                                     baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: suffix, ext: output.fileExtension)
        let quality = AppSettings.shared.jpegQuality
        let metadata = ImageIOBridge.properties(url)
        var job = session.job(tr("Cropping", "Wird zugeschnitten"), detail: url.lastPathComponent) { progress in
            [try await StagingArea.writing(destination) { destination in
                try await ImageToolSupport.renderAndWrite(render: {
                    let original = try ImageIOBridge.load(url)
                    progress(0.2)
                    return try await croppedAroundSubject(original, aspect: aspect)
                }, to: destination, format: output, quality: quality, metadata: metadata, progress: progress)
            }]
        }
        job.inputs = [url]
        return job
    }

    /// The largest cut of this aspect, placed around faces, people or the main object (as for social media), else in the middle.
    static func croppedAroundSubject(_ image: CGImage, aspect: CGSize) async throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let (region, _) = await SmartCrop.importantRegion(in: image)
        try Task.checkCancellation()
        return ImageIOBridge.cropped(image, to: SmartCrop.window(imageSize: size, aspect: aspect, important: region))
    }

    /// When several pictures are dropped on "Crop" itself: its window takes one picture, the fan's presets take them all.
    static func severalFilesNote(_ tool: ToolID, files: [URL]) -> ToolJob {
        ToolJob(title: tool.progressTitle, detail: tr("\(files.count) files", "\(files.count) Dateien"), symbol: tool.symbol, work: { (_: @escaping (Double) -> Void) async throws -> [URL] in
            throw AppError.invalidInput(tr("The window of \u{201C}\(tool.title)\u{201D} takes one picture. For several, hold the pointer on \u{201C}\(RingWords.toolLabel(tool))\u{201D} and choose an aspect in the arc that opens.",
                                           "Das Fenster von \u{201E}\(tool.title)\u{201C} nimmt ein Bild. Für mehrere den Zeiger kurz auf \u{201E}\(RingWords.toolLabel(tool))\u{201C} halten und im Bogen ein Seitenverhältnis wählen."))
        })
    }
}
