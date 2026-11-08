import AppKit
import PDFKit

/// What happens when a tool is chosen in a ring.
enum ToolGroup: String, CaseIterable {
    /// Nothing to set: runs at once.
    case immediate
    /// Has settings: its window opens with the last values, Return starts. With Option at the drop it runs with them, no window.
    case window
    /// Needs something only the window can give (a part of the picture, times, marks, a password) or shows its result there:
    /// always the window, also with Option.
    case windowOnly
}

extension ToolID {
    var group: ToolGroup {
        switch self {
        case .extractImages, .pdfArchive:
            return .immediate
        case .compress, .recognizeText, .resizeImage, .rotateImage, .createPDF, .createCollage, .changeVideoSpeed, .normalizeAudio,
             .audioToVideo, .audioChannels, .transcribe, .mergePDF, .joinVideos, .watermarkPDF, .pageNumbersPDF, .splitPDF,
             .socialMedia, .videoPresets, .removeBackground:
            return .window
        case .editMetadata, .editImage, .cropImage, .redactImage, .trimVideo, .cropVideo, .videoSnapshots, .splitVideo, .redactVideo,
             .trimAudio, .redactAudio, .organizePDF, .redactPDF, .annotate, .signPDF, .comparePDF, .readQR, .pdfPassword,
             .frameImage, .burnSubtitles:
            return .windowOnly
        }
    }
}

/// The last values of each tool's window, kept in the app's settings ("toolMemory.<tool>"), with the same names the test access uses
/// for its options (`ToolOptions`). The window writes them when its main button is clicked; Option at the drop runs with them.
enum ToolMemory {
    /// The remembered values, each number within what the tool's window offers: another app could write anything into the settings
    /// (`defaults write`), and a collage of 10^9 pixels or a speed of 10^300 would fill the memory or end the app.
    static func values(_ tool: ToolID, settings: AppSettings = .shared) -> [String: String] {
        checked(settings.toolMemory(tool), for: tool)
    }

    /// Numbers out of range are brought to its nearest end (as the window's field does, `NumberField`); infinite or not a number
    /// they go, and the tool takes its own default.
    static func checked(_ values: [String: String], for tool: ToolID) -> [String: String] {
        guard let ranges = limits[tool] else { return values }
        return values.reduce(into: [:]) { result, item in
            let (key, text) = item
            guard let range = ranges[key] else { return result[key] = text }
            guard let number = Double(text), number.isFinite else { return }
            let kept = min(max(number, range.lowerBound), range.upperBound)
            result[key] = kept == number ? text : (kept.rounded() == kept ? "\(Int(kept))" : "\(kept)")
        }
    }

    /// What each window offers (its sliders and fields). The fields take no more (`NumberField.range`).
    static let limits: [ToolID: [String: ClosedRange<Double>]] = [
        .changeVideoSpeed: ["factor": 0.1...8],
        .createCollage: ["width": 64...10_000, "height": 64...10_000, "spacing": 0...200, "corner": 0...200],
        .resizeImage: ["longEdge": 1...20_000, "percent": 1...400, "width": 0...20_000, "height": 0...20_000],
        .splitPDF: ["every": 1...100_000],
        .watermarkPDF: ["size": 24...160, "opacity": 0.05...1],
        .pageNumbersPDF: ["start": -100_000...100_000],
        .normalizeAudio: ["target": -30...(-8), "range": 1...20, "truePeak": -9...0],
        .audioChannels: ["left": 0...2, "right": 0...2],
        .compress: ["targetKB": 0...10_000_000, "resize": 0...20_000],
    ]

    static func remember(_ tool: ToolID, _ values: [String: String], settings: AppSettings = .shared) {
        settings.setToolMemory(values, for: tool)
    }

    /// Reads one remembered value, or the window's default.
    static func value<T: LosslessStringConvertible>(_ tool: ToolID, _ key: String, default fallback: T) -> T {
        values(tool)[key].flatMap(T.init) ?? fallback
    }

    static func value<T: RawRepresentable>(_ tool: ToolID, _ key: String, default fallback: T) -> T where T.RawValue == String {
        values(tool)[key].flatMap(T.init(rawValue:)) ?? fallback
    }
}

/// Builds a tool's jobs without its window, from option values: the test access passes them on the command line, Option at the drop
/// passes the remembered ones (`ToolMemory`). Returns nil for tools that need their window.
@MainActor
enum QuickRun {
    static func jobs(_ id: ToolID, session: ToolSession, options: inout ToolOptions) async throws -> [ToolJob]? {
        let files = session.files
        switch id {
        case .extractImages:
            return ExtractImagesToolView.jobs(session)
        case .pdfArchive:
            return PDFArchiveToolView.jobs(session)
        case .compress:
            let targetKB = try options.value("targetKB", Double.self, default: 0)
            return CompressToolView.jobs(session, .init(
                preset: try options.value("preset", CompressionPreset.self, default: AppSettings.shared.compressionPreset),
                resizeLongEdge: try options.value("resize", Int.self, default: AppSettings.shared.compressionResizeLongEdge),
                targetBytes: targetKB > 0 ? Int64(targetKB * 1_000) : nil))
        case .recognizeText:
            return RecognizeTextToolView.jobs(session, output: try options.value("output", TextRecognizer.PDFOutput.self, default: .standard))
        case .resizeImage:
            return ResizeImageToolView.jobs(session, .init(
                mode: try options.value("mode", ResizeImageToolView.Mode.self, default: .longEdge),
                longEdge: try options.value("longEdge", Int.self, default: 1920), percent: try options.value("percent", Int.self, default: 50),
                width: try options.value("width", Int.self, default: 0), height: try options.value("height", Int.self, default: 0),
                lockAspect: try options.value("lockAspect", Bool.self, default: true)))
        case .rotateImage:
            return RotateImageToolView.jobs(session, quarterTurns: try options.value("turns", Int.self, default: 1),
                                            flipH: try options.value("flipH", Bool.self, default: false), flipV: try options.value("flipV", Bool.self, default: false))
        case .createPDF:
            return CreatePDFToolView.jobs(session, files: files,
                                          layout: try options.value("layout", PDFRenderer.ImagePageLayout.self, default: AppSettings.shared.imagesToPDFLayout))
        case .createCollage:
            var collage = ImageOps.CollageOptions()
            collage.layout = try options.value("layout", ImageOps.CollageLayout.self, default: .grid)
            collage.width = CGFloat(max(64, try options.value("width", Int.self, default: Int(collage.width))))
            collage.height = CGFloat(max(64, try options.value("height", Int.self, default: Int(collage.height))))
            collage.spacing = CGFloat(try options.value("spacing", Double.self, default: Double(collage.spacing)))
            collage.cornerRadius = CGFloat(try options.value("corner", Double.self, default: Double(collage.cornerRadius)))
            return CollageToolView.jobs(session, files: files, options: collage)
        case .changeVideoSpeed:
            return VideoSpeedToolView.jobs(session, factor: try options.value("factor", Double.self, default: 2),
                                           preservePitch: try options.value("preservePitch", Bool.self, default: true))
        case .joinVideos:
            return JoinVideosToolView.jobs(session, files: files)
        case .mergePDF:
            return MergePDFToolView.jobs(session, files: files)
        case .normalizeAudio:
            return NormalizeAudioToolView.jobs(session, target: try options.value("target", Double.self, default: -16),
                                               range: try options.value("range", Double.self, default: 11),
                                               truePeak: try options.value("truePeak", Double.self, default: -1.5))
        case .audioToVideo:
            return AudioToVideoToolView.jobs(session, style: try options.value("style", AudioOps.VisualizerStyle.self, default: .waveform),
                                             orientation: try options.value("orientation", AudioOps.VisualizerOrientation.self, default: .landscape),
                                             accentHex: NSColor.systemOrange.ffmpegHex, backgroundHex: NSColor.black.ffmpegHex, imageURL: nil)
        case .audioChannels:
            return AudioChannelsToolView.jobs(session, mode: try options.value("mode", AudioOps.ChannelMode.self, default: .stereo),
                                              left: try options.value("left", Double.self, default: 1), right: try options.value("right", Double.self, default: 1))
        case .transcribe:
            return TranscribeToolView.jobs(session, language: try options.value("language", Transcriber.Language.self, default: AppSettings.shared.transcriptionLanguage),
                                           output: try options.value("output", Transcriber.Output.self, default: .text))
        case .splitPDF:
            let count = PDFDocument(url: session.primary)?.pageCount ?? 0
            return SplitPDFToolView.jobs(session, mode: try options.value("mode", PDFOps.SplitMode.self, default: .everyPage),
                                         every: try options.value("every", Int.self, default: 2), ranges: options.string("ranges", default: "1-\(count)"))
        case .watermarkPDF:
            var watermark = PDFStamp.Watermark()
            watermark.text = options.string("text", default: watermark.text)
            watermark.fontSize = CGFloat(try options.value("size", Double.self, default: Double(watermark.fontSize)))
            watermark.opacity = CGFloat(try options.value("opacity", Double.self, default: Double(watermark.opacity)))
            watermark.direction = try options.value("direction", PDFStamp.Watermark.Direction.self, default: watermark.direction)
            watermark.position = try options.value("position", PDFStamp.Watermark.Position.self, default: watermark.position)
            return WatermarkPDFToolView.jobs(session, watermark: watermark)
        case .pageNumbersPDF:
            var numbers = PDFStamp.PageNumbers()
            numbers.position = try options.value("position", PDFStamp.PageNumbers.Position.self, default: numbers.position)
            numbers.format = try options.value("format", PDFStamp.PageNumbers.Format.self, default: numbers.format)
            numbers.start = try options.value("start", Int.self, default: numbers.start)
            numbers.skipFirstPage = try options.value("skipFirst", Bool.self, default: numbers.skipFirstPage)
            return PageNumbersPDFToolView.jobs(session, numbers: numbers)
        case .socialMedia:
            let window = try options.optionalList("window")
            if let window, window.count != 4 { throw ToolOptions.Problem("window needs x,y,width,height as fractions.") }
            return SocialMediaToolView.jobs(session, preset: try options.value("preset", SocialPreset.self, default: .instagramPortrait),
                                            chosen: window.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) })
        case .videoPresets:
            let window = try options.optionalList("window")
            if let window, window.count != 4 { throw ToolOptions.Problem("window needs x,y,width,height as fractions.") }
            return VideoPresetsToolView.jobs(session, preset: try options.value("preset", VideoPreset.self, default: .reels),
                                             chosen: window.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) })
        case .removeBackground:
            return RemoveBackgroundToolView.jobs(session, subject: try options.optionalList("subject")?.first.map { Int($0) })
        default:
            return nil
        }
    }
}
