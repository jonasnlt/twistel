import Foundation
import PDFKit

/// PDF compression with Ghostscript, called as a separate program. Its pdfwrite device keeps text as text,
/// so it stays selectable and searchable. Without Ghostscript, or if it fails, the built-in PDFKit method is used.
enum PDFCompression {
    enum Method: Equatable {
        case ghostscript
        case builtIn
    }

    static var ghostscriptMissingHint: String {
        tr("Ghostscript is not installed, so PDFs use the built-in method: it saves less, "
            + "and with Strong the text is no longer selectable. To fix this, run \u{201C}brew install ghostscript\u{201D} in Terminal.",
           "Ghostscript ist nicht installiert, deshalb werden PDFs mit der eingebauten Methode verkleinert: Sie spart weniger, "
            + "und mit \u{201E}Stark\u{201C} lässt sich der Text nicht mehr auswählen. Zum Beheben gib im Terminal \u{201E}brew install ghostscript\u{201C} ein.")
    }

    static var ghostscriptPath: String? { Shell.which("gs") }

    /// One Ghostscript run. Balanced runs `gentlePhotos` and `lossless` and keeps the smaller result. JPEG images are almost
    /// always photos, lossless ones screenshots or graphics: pages on which the photo pass would change a lossless image
    /// (fewer pixels or JPEG) are redone losslessly, see `pagesWithChangedLosslessImages`.
    enum Pass: Equatable {
        /// Photos above 320 dpi go to 256 dpi (on A4, about 3000 px on the long edge; see `pageScale`) with high-quality JPEG.
        /// JPEGs below the threshold are copied.
        case gentlePhotos
        /// No image gets fewer pixels, lossless images stay lossless, JPEGs are copied unchanged.
        case lossless
        /// Images above 180 dpi go to 150 dpi (on A4), JPEG at QFactor 0.5 (Ghostscript's /ebook and /screen use 0.76,
        /// which smears text in screenshots).
        case strong
    }

    static func passes(for preset: CompressionPreset) -> [Pass] {
        switch preset {
        case .balanced: return [.gentlePhotos, .lossless]
        case .strong: return [.strong]
        }
    }

    /// Ghostscript counts dpi against the page size. A page made from a camera photo is as large as the photo in points
    /// (4000 × 3000 pt), so its photo has only 72 dpi and would never be reduced. Pages larger than A4 therefore get
    /// proportionally lower dpi, so each page keeps about as many pixels as an A4 page would.
    static func pageScale(longEdge: CGFloat) -> Double {
        let a4LongEdge: CGFloat = 842
        let scale = longEdge > a4LongEdge ? Double(a4LongEdge / longEdge) : 1
        return (scale * 100).rounded() / 100
    }

    /// Consecutive pages (1-based, inclusive) that share one resolution scale; `lossless` pages keep all images as they are.
    struct Segment: Equatable {
        let first: Int
        let last: Int
        let scale: Double
        var lossless = false
    }

    /// Each page gets its own scale; neighbours with the same scale form one segment. Ghostscript then reads the PDF once
    /// per segment, which would duplicate bookmarks and break links and forms. So a PDF with those keeps one run, using the
    /// scale of its smallest page: larger pages are then reduced a little less, never more.
    static func segments(pageLongEdges: [CGFloat], canSplit: Bool, losslessPages: Set<Int> = []) -> [Segment] {
        guard !pageLongEdges.isEmpty else { return [Segment(first: 1, last: 1, scale: 1)] }
        let scales = pageLongEdges.map(pageScale(longEdge:))
        guard canSplit else { return [Segment(first: 1, last: scales.count, scale: scales.max() ?? 1)] }
        var result: [Segment] = []
        for (index, scale) in scales.enumerated() {
            let page = index + 1, lossless = losslessPages.contains(page)
            if let previous = result.last, previous.scale == scale, previous.lossless == lossless {
                result[result.count - 1] = Segment(first: previous.first, last: page, scale: scale, lossless: lossless)
            } else {
                result.append(Segment(first: page, last: page, scale: scale, lossless: lossless))
            }
        }
        return result
    }

    /// Pages on which a lossless image (screenshot, graphic) did not survive unchanged: it lost pixels or became JPEG.
    /// Compares, per page, the sizes of the lossless images before with the lossless images after.
    static func pagesWithChangedLosslessImages(before: [PDFDiagnosis.Image], after: [PDFDiagnosis.Image]) -> Set<Int> {
        let pages = Set(before.filter(\.isLossless).map(\.page))
        return pages.filter { page in
            var remaining = after.filter { $0.page == page && $0.isLossless }.map { [$0.width, $0.height] }
            for image in before where image.page == page && image.isLossless {
                guard let match = remaining.firstIndex(of: [image.width, image.height]) else { return true }
                remaining.remove(at: match)
            }
            return false
        }
    }

    /// Whether the PDF has bookmarks, named destinations, forms, embedded files or annotations such as links.
    /// If it can't be read, it counts as having them (the safe choice).
    static func hasDocumentStructure(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL), let catalog = document.catalog else { return true }
        var dictionary: CGPDFDictionaryRef?
        for key in ["Outlines", "AcroForm", "Names", "Dests"] where CGPDFDictionaryGetDictionary(catalog, key, &dictionary) {
            return true
        }
        guard document.numberOfPages > 0 else { return false }
        for number in 1...document.numberOfPages {
            var annotations: CGPDFArrayRef?
            if let page = document.page(at: number)?.dictionary, CGPDFDictionaryGetArray(page, "Annots", &annotations),
               let annotations, CGPDFArrayGetCount(annotations) > 0 {
                return true
            }
        }
        return false
    }

    static func ghostscriptArguments(pass: Pass, source: URL, destination: URL, segments: [Segment] = []) -> [String] {
        let firstScale = segments.first?.scale ?? 1
        // A lossless segment needs its own settings even when it is the only one.
        let split = pass != .lossless && (segments.count > 1 || segments.contains(where: \.lossless))
        var args = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.6",
            "-dDetectDuplicateImages=true",
            "-dSAFER",
            "-dNOPAUSE",
            "-dBATCH",
            // No -dQUIET: Ghostscript then prints "Page N" for each page, which drives the progress.
            "-dPassThroughJPEGImages=true",
        ]
        let jpeg: String?
        switch pass {
        case .gentlePhotos:
            args += ["-dAutoFilterColorImages=true", "-dAutoFilterGrayImages=true"] + downsampling(to: scaled(baseDPI(pass), firstScale), threshold: "1.25")
            jpeg = jpegSettings(quality: 0.15, subsampleColor: false)
        case .lossless:
            args += [
                "-dDownsampleColorImages=false",
                "-dDownsampleGrayImages=false",
                "-dDownsampleMonoImages=false",
                "-dAutoFilterColorImages=false",
                "-dAutoFilterGrayImages=false",
                "-dColorImageFilter=/FlateEncode",
                "-dGrayImageFilter=/FlateEncode",
            ]
            jpeg = nil
        case .strong:
            args += downsampling(to: scaled(baseDPI(pass), firstScale), threshold: "1.2")
            jpeg = jpegSettings(quality: 0.5, subsampleColor: true)
        }
        // Ghostscript reads % in the output name as a page-number pattern.
        args.append("-sOutputFile=\(destination.path.replacingOccurrences(of: "%", with: "%%"))")
        if let jpeg { args += ["-c", jpeg] }
        if split {
            // The same file once per segment, each with its own settings; pages stay in order.
            for segment in segments {
                let pages = segment.first == segment.last ? "\(segment.first)" : "\(segment.first)-\(segment.last)"
                args += ["-sPageList=\(pages)", "-c", segmentSettings(pass: pass, segment: segment), "-f", source.path]
            }
        } else {
            args += ["-f", source.path]
        }
        return args
    }

    /// Distiller settings for one segment of a split run.
    static func segmentSettings(pass: Pass, segment: Segment) -> String {
        let dpi = scaled(baseDPI(pass), segment.scale)
        switch pass {
        case .gentlePhotos where segment.lossless, .lossless:
            return "<< /DownsampleColorImages false /DownsampleGrayImages false /AutoFilterColorImages false /AutoFilterGrayImages false "
                + "/ColorImageFilter /FlateEncode /GrayImageFilter /FlateEncode >> setdistillerparams"
        case .gentlePhotos:
            return "<< /DownsampleColorImages true /DownsampleGrayImages true /AutoFilterColorImages true /AutoFilterGrayImages true "
                + "/ColorImageResolution \(dpi) /GrayImageResolution \(dpi) >> setdistillerparams"
        case .strong:
            return "<< /ColorImageResolution \(dpi) /GrayImageResolution \(dpi) >> setdistillerparams"
        }
    }

    /// The resolution a pass reduces images to on an A4 page; nil if it keeps all pixels.
    static func baseDPI(_ pass: Pass) -> Int? {
        switch pass {
        case .gentlePhotos: return 256
        case .lossless: return nil
        case .strong: return 150
        }
    }

    private static func scaled(_ dpi: Int?, _ scale: Double) -> Int { max(1, Int((Double(dpi ?? 72) * scale).rounded())) }

    /// Images above `threshold` × `dpi` are reduced to `dpi`.
    private static func downsampling(to dpi: Int, threshold: String) -> [String] {
        [
            "-dDownsampleColorImages=true",
            "-dDownsampleGrayImages=true",
            "-dColorImageDownsampleType=/Bicubic",
            "-dGrayImageDownsampleType=/Bicubic",
            "-dColorImageResolution=\(dpi)",
            "-dGrayImageResolution=\(dpi)",
            "-dColorImageDownsampleThreshold=\(threshold)",
            "-dGrayImageDownsampleThreshold=\(threshold)",
        ]
    }

    /// PostScript for the JPEG quality of re-encoded images. Gray is never subsampled.
    static func jpegSettings(quality: Double, subsampleColor: Bool) -> String {
        let q = String(format: "%.2f", quality)
        let samples = subsampleColor ? "[2 1 1 2]" : "[1 1 1 1]"
        let color = "<< /QFactor \(q) /Blend 1 /HSamples \(samples) /VSamples \(samples) >>"
        let gray = "<< /QFactor \(q) /Blend 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >>"
        return "<< /ColorACSImageDict \(color) /ColorImageDict \(color) /GrayACSImageDict \(gray) /GrayImageDict \(gray) >> setdistillerparams"
    }

    @discardableResult
    static func compress(_ url: URL, preset: CompressionPreset, to destination: URL, ghostscript: String? = ghostscriptPath,
                         purpose: String = "compress", progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Method {
        var diagnosis = PDFDiagnosis(purpose: purpose, preset: preset)
        diagnosis.originalBytes = FileSizeFormatter.size(of: url)
        if let document = PDFDocument(url: url) {
            diagnosis.pageCount = document.pageCount
            diagnosis.pageLongEdges = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox) }.map { max($0.width, $0.height) }
        }
        diagnosis.hasDocumentStructure = hasDocumentStructure(url)
        diagnosis.segments = segments(pageLongEdges: diagnosis.pageLongEdges, canSplit: !diagnosis.hasDocumentStructure)
        diagnosis.images = PDFDiagnosis.images(in: url)

        if let ghostscript {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-pdf-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let passes = passes(for: preset)
                let pageCount = max(1, diagnosis.pageCount)
                let segments = diagnosis.segments
                // First runs, possible redo of the photo pass, sharpness figure for the log.
                let firstShare = preset == .balanced ? 0.7 : 1.0, redoShare = 0.2
                progress(0)

                // Runs one Ghostscript pass and reports its pages into `share` of the bar, starting at `offset`.
                @Sendable func run(_ pass: Pass, _ segments: [Segment], name: String, tracker: PassProgress, index: Int) async throws -> (URL, Double) {
                    let start = Date()
                    let output = work.appendingPathComponent("\(name).pdf")
                    let args = ghostscriptArguments(pass: pass, source: plainNamed(url, in: work), destination: output, segments: segments)
                    // Its temporary files go into `work`: it leaves them behind when it fails.
                    let result = try await Shell.run(ghostscript, args, environment: ["TMPDIR": work.path + "/"], limit: .work) { line in
                        if let page = pageNumber(inGhostscriptLine: line) { tracker.update(index, Double(page) / Double(pageCount)) }
                    }
                    try Task.checkCancellation()
                    guard result.succeeded, FileManager.default.fileExists(atPath: output.path) else { throw GhostscriptFailure(status: result.status) }
                    tracker.update(index, 1)
                    return (output, Date().timeIntervalSince(start))
                }

                // The passes are independent, so they run at the same time.
                let tracker = PassProgress(passes: passes.count) { progress($0 * firstShare) }
                let outputs = try await withThrowingTaskGroup(of: (Int, URL, Double).self) { group in
                    for (index, pass) in passes.enumerated() {
                        group.addTask {
                            let (output, seconds) = try await run(pass, segments, name: "pass \(index)", tracker: tracker, index: index)
                            return (index, output, seconds)
                        }
                    }
                    var outputs: [Int: (url: URL, seconds: Double)] = [:]
                    for try await (index, output, seconds) in group { outputs[index] = (output, seconds) }
                    return outputs
                }

                var candidates: [(name: String, url: URL)] = []
                for (index, pass) in passes.enumerated() {
                    guard var output = outputs[index] else { continue }
                    var name = "\(pass)"
                    diagnosis.passes.append(PDFDiagnosis.Pass(name: name, bytes: FileSizeFormatter.size(of: output.url), seconds: output.seconds))
                    if pass == .gentlePhotos {
                        let after = PDFDiagnosis.images(in: output.url)
                        let protected = pagesWithChangedLosslessImages(before: diagnosis.images, after: after)
                        diagnosis.protectedPages = protected
                        if !protected.isEmpty {
                            // A PDF that can't be split can't keep single pages lossless, and with every page protected nothing
                            // is left for the photo pass: the lossless pass covers both.
                            guard !diagnosis.hasDocumentStructure, protected.count < diagnosis.pageCount else {
                                diagnosis.passes[diagnosis.passes.count - 1].accepted = false
                                continue
                            }
                            let redoSegments = PDFCompression.segments(pageLongEdges: diagnosis.pageLongEdges, canSplit: true, losslessPages: protected)
                            let redoTracker = PassProgress(passes: 1) { progress(firstShare + $0 * redoShare) }
                            let redo = try await run(.gentlePhotos, redoSegments, name: "photo pass redo", tracker: redoTracker, index: 0)
                            output = (redo.0, redo.1)
                            name = "photo pass with \(protected.count) lossless page(s)"
                            diagnosis.passes.append(PDFDiagnosis.Pass(name: name, bytes: FileSizeFormatter.size(of: output.url), seconds: output.seconds))
                        }
                        diagnosis.imagesAfterPhotoPass = PDFDiagnosis.images(in: output.url)
                    }
                    candidates.append((name, output.url))
                }
                guard let smallest = candidates.min(by: { FileSizeFormatter.size(of: $0.url) < FileSizeFormatter.size(of: $1.url) }) else {
                    throw AppError.encodeFailed(destination.lastPathComponent)
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: smallest.url, to: destination)
                let keptOriginal = try keepSmaller(original: url, compressed: destination)
                diagnosis.decision = decision(chosen: smallest.name, keptOriginal: keptOriginal, protectedPages: diagnosis.protectedPages)
                // Sharpness of what the user gets, for the log only; it decides nothing.
                if !keptOriginal, preset == .balanced, smallest.name != "\(Pass.lossless)" {
                    let start = Date()
                    diagnosis.pagePSNR = try PDFQuality.pagePSNRs(url, destination) { progress(firstShare + redoShare + $0 * (1 - firstShare - redoShare)) } ?? [:]
                    diagnosis.passes.append(PDFDiagnosis.Pass(name: "sharpness figure", bytes: 0, seconds: Date().timeIntervalSince(start),
                                                              psnr: diagnosis.pagePSNR.values.min()))
                }
                progress(1)
                DiagnosticLog.log(diagnosis.line)
                DiagnosticLog.log(diagnosis.pagesLine())
                return .ghostscript
            } catch {
                try? FileManager.default.removeItem(at: destination)
                if error is CancellationError || Task.isCancelled {
                    diagnosis.decision = "cancelled"
                    DiagnosticLog.log(diagnosis.line)
                    throw CancellationError()
                }
                // Ghostscript's own message may contain file paths, so only the exit status goes into the log.
                diagnosis.decision = "Ghostscript failed (\((error as? GhostscriptFailure).map { "exit status \($0.status)" } ?? "\(type(of: error))")), built-in method used"
            }
        } else {
            diagnosis.decision = "Ghostscript not installed, built-in method used"
        }
        try PDFOps.compress(url, strong: preset == .strong, to: destination)
        diagnosis.passes.append(PDFDiagnosis.Pass(name: "built-in", bytes: FileSizeFormatter.size(of: destination), seconds: 0))
        DiagnosticLog.log(diagnosis.line)
        progress(1)
        return .builtIn
    }

    /// Why the result is what it is, for the diagnosis line.
    static func decision(chosen: String, keptOriginal: Bool, protectedPages: Set<Int>) -> String {
        var text = keptOriginal ? "kept a copy of the original (no pass was smaller)" : "chose \(chosen) (smallest)"
        if !protectedPages.isEmpty {
            let pages = protectedPages.sorted().prefix(20).map(String.init).joined(separator: ",")
            text += "; lossless images would have changed on page(s) \(pages)\(protectedPages.count > 20 ? ",…" : ""), kept lossless there"
        }
        return text
    }

    /// The file under a plain name, for Ghostscript: in its safe mode it reads characters like | * ? in a path as patterns of its own and then refuses the
    /// file ("Permission denied", found with "a | b.pdf"). Nothing of the name reaches it this way.
    static func plainNamed(_ url: URL, in work: URL) -> URL {
        let link = work.appendingPathComponent("input-\(UUID().uuidString).pdf")
        guard (try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url.standardizedFileURL)) != nil else { return url }
        return link
    }

    /// Ghostscript prints "Page 3" when it starts page 3.
    static func pageNumber(inGhostscriptLine line: String) -> Int? {
        guard line.hasPrefix("Page ") else { return nil }
        return Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }

    /// Below this share saved, the window says there is little to gain.
    static let littleSavingsShare = 0.10

    /// Size the compressed copy would have, by compressing into a temporary folder. Nil without Ghostscript or on failure.
    static func estimatedSize(of url: URL, preset: CompressionPreset, ghostscript: String? = ghostscriptPath) async -> Int64? {
        guard ghostscript != nil else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-estimate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("estimate.pdf")
            guard try await compress(url, preset: preset, to: output, ghostscript: ghostscript, purpose: "window estimate") == .ghostscript else { return nil }
            return FileSizeFormatter.size(of: output)
        } catch {
            return nil
        }
    }

    /// The note for the Compress window when a preset would save little; nil when it is worth it.
    static func littleSavingsNote(fileName: String, original: Int64, estimated: Int64, preset: CompressionPreset) -> String? {
        guard original > 0, Double(original - estimated) / Double(original) < littleSavingsShare else { return nil }
        let result = estimated >= original
            ? tr("stays at \(FileSizeFormatter.string(original))", "bleibt bei \(FileSizeFormatter.string(original))")
            : tr("goes from \(FileSizeFormatter.string(original)) to about \(FileSizeFormatter.string(estimated))", "wird von \(FileSizeFormatter.string(original)) zu etwa \(FileSizeFormatter.string(estimated))")
        switch preset {
        case .balanced:
            return tr("\(fileName) \(result): there is little to save without losing sharpness, so Balanced keeps the images as they are. Strong makes it smaller, but less sharp.", "\(fileName) \(result): Ohne Schärfe zu verlieren, lässt sich hier wenig sparen, deshalb lässt \u{201E}Ausgewogen\u{201C} die Bilder, wie sie sind. \u{201E}Stark\u{201C} macht die Datei kleiner, aber weniger scharf.")
        case .strong:
            return tr("\(fileName) \(result): it is already compact, so even Strong saves little.", "\(fileName) \(result): Die Datei ist schon kompakt, deshalb spart selbst \u{201E}Stark\u{201C} wenig.")
        }
    }

    /// Ghostscript can make an already lean PDF bigger; then the compressed copy is the original itself.
    /// Returns whether the original was kept.
    @discardableResult
    static func keepSmaller(original: URL, compressed: URL) throws -> Bool {
        guard FileSizeFormatter.size(of: compressed) >= FileSizeFormatter.size(of: original) else { return false }
        try FileManager.default.removeItem(at: compressed)
        try FileManager.default.copyItem(at: original, to: compressed)
        return true
    }
}

/// Combines the progress of Ghostscript runs that happen at the same time.
private final class PassProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]
    private let report: (Double) -> Void

    init(passes: Int, report: @escaping (Double) -> Void) {
        values = Array(repeating: 0, count: max(1, passes))
        self.report = report
    }

    func update(_ pass: Int, _ value: Double) {
        let average: Double = lock.withLock {
            values[pass] = max(values[pass], min(1, value))
            return values.reduce(0, +) / Double(values.count)
        }
        report(average)
    }
}

/// A Ghostscript run that ended with an error.
private struct GhostscriptFailure: Error {
    let status: Int32
}
