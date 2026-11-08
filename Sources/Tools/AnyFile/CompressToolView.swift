import SwiftUI

@MainActor
struct CompressToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var useTarget = false
    @State private var targetValue: Double = 1
    @State private var targetUnit: SizeUnit = .megabytes
    @State private var resize = 0
    /// Trial sizes of the PDFs per preset, keyed by "path|preset".
    @State private var pdfEstimates: [String: Int64] = [:]

    enum SizeUnit: String, CaseIterable, Identifiable {
        case kilobytes = "KB"
        case megabytes = "MB"
        var id: String { rawValue }
        var multiplier: Double { self == .kilobytes ? 1_000 : 1_000_000 }
    }

    private var totalSize: Int64 { session.files.reduce(0) { $0 + FileSizeFormatter.size(of: $1) } }
    private var perFileTarget: Int64? {
        guard useTarget else { return nil }
        return Int64(targetValue * targetUnit.multiplier)
    }

    private enum ImageSize: Int, CaseIterable, Identifiable {
        case original = 0
        case large = 2560
        case medium = 1920
        case small = 1280

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .original: return tr("Original", "Original")
            case .large: return "2560 px"
            case .medium: return "1920 px"
            case .small: return "1280 px"
            }
        }
    }

    private var imageSize: Binding<ImageSize> {
        Binding(
            get: { ImageSize(rawValue: resize) ?? .original },
            set: { resize = $0.rawValue }
        )
    }

    private var hasImages: Bool { session.files.contains { FileFormat.detect($0)?.category == .image } }
    private var hasPDFs: Bool { session.files.contains { FileFormat.detect($0) == .pdf } }
    private var pdfFiles: [URL] { session.files.filter { FileFormat.detect($0) == .pdf } }

    private func estimateKey(_ url: URL, _ preset: CompressionPreset) -> String { "\(url.path)|\(preset.rawValue)" }

    private var littleSavingsNotes: [String] {
        let preset = settings.compressionPreset
        return pdfFiles.compactMap { url in
            guard let estimated = pdfEstimates[estimateKey(url, preset)] else { return nil }
            return PDFCompression.littleSavingsNote(fileName: url.lastPathComponent, original: FileSizeFormatter.size(of: url), estimated: estimated, preset: preset)
        }
    }

    /// Runs Ghostscript on each PDF into a temporary folder; cancelled when the window closes or the preset changes.
    private func estimatePDFs(for preset: CompressionPreset) async {
        for url in pdfFiles where pdfEstimates[estimateKey(url, preset)] == nil {
            guard FileSizeFormatter.size(of: url) <= 100_000_000 else { continue }
            guard let size = await PDFCompression.estimatedSize(of: url, preset: preset), !Task.isCancelled else { return }
            pdfEstimates[estimateKey(url, preset)] = size
        }
    }

    init(session: ToolSession) {
        self.session = session
        // The last values of this window (Option at the drop runs with them).
        let targetKB = ToolMemory.value(.compress, "targetKB", default: 0.0)
        _useTarget = State(initialValue: targetKB > 0)
        _targetUnit = State(initialValue: targetKB >= 1_000 ? .megabytes : (targetKB > 0 ? .kilobytes : .megabytes))
        _targetValue = State(initialValue: targetKB >= 1_000 ? targetKB / 1_000 : (targetKB > 0 ? targetKB : 1))
        _resize = State(initialValue: ToolMemory.value(.compress, "resize", default: AppSettings.shared.compressionResizeLongEdge))
    }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? tr("Compress", "Verkleinern") : tr("Compress \(session.files.count) files", "\(session.files.count) Dateien verkleinern"), onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(tr("\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · saves as \(Compressor.outputFormat(for: url).displayName)", "\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · wird als \(Compressor.outputFormat(for: url).displayName) gesichert"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            FormRow(title: tr("Compression", "Verkleinerung")) {
                SegmentedPicker(selection: $settings.compressionPreset, options: CompressionPreset.allCases.map { ($0, $0.title) })
            }
            FormHint(settings.compressionPreset == .balanced ? tr("Noticeably smaller with little visible change.", "Deutlich kleiner, kaum sichtbarer Unterschied.") : tr("Smallest output; quality loss is visible.", "So klein wie möglich, der Qualitätsverlust ist sichtbar."))
            if hasPDFs, PDFCompression.ghostscriptPath == nil {
                FormHint(PDFCompression.ghostscriptMissingHint)
            }
            ForEach(littleSavingsNotes, id: \.self) { note in
                FormHint(note)
            }

            if hasImages {
                FormRow(title: tr("Image size", "Bildgröße")) {
                    SegmentedPicker(selection: imageSize, options: ImageSize.allCases.map { ($0, $0.title) })
                }
                FormHint(tr("Longest edge of each image. Smaller images are never upscaled.", "Längste Seite jedes Bilds. Kleinere Bilder werden nie vergrößert."))
            }

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $useTarget.animation(.easeInOut(duration: 0.18))) {
                    Text(tr("Target file size", "Gewünschte Dateigröße"))
                }
                .toggleStyle(.switch)

                if useTarget {
                    HStack(spacing: 10) {
                        TextField(tr("Size", "Größe"), value: $targetValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)
                        SegmentedPicker(selection: $targetUnit, options: SizeUnit.allCases.map { ($0, $0.rawValue) })
                        Text(tr("per file", "pro Datei"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    FormHint(tr("Images use a quality search and downscale if needed. Videos and audio pick a bitrate from the duration (videos need FFmpeg). Audio goes down to about 24 kbit/s.", "Bei Bildern wird die passende Qualität gesucht und das Bild bei Bedarf verkleinert. Bei Videos und Audio richtet sich die Datenrate nach der Dauer (Videos brauchen FFmpeg). Audio geht bis etwa 24 kbit/s hinunter."))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            Text(tr("\(session.files.count) file\(session.files.count == 1 ? "" : "s"), \(FileSizeFormatter.string(totalSize)) total. Originals stay untouched; compressed copies are saved to \(settings.outputLocation.title.lowercased()).", "\(session.files.count) \(session.files.count == 1 ? "Datei" : "Dateien"), zusammen \(FileSizeFormatter.string(totalSize)). Die Originale bleiben unverändert. Ablageort der verkleinerten Kopien: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task(id: settings.compressionPreset) { await estimatePDFs(for: settings.compressionPreset) }
    }

    private func run() {
        ToolMemory.remember(.compress, ["preset": settings.compressionPreset.rawValue, "resize": "\(resize)",
                                        "targetKB": "\(perFileTarget.map { Double($0) / 1_000 } ?? 0)"])
        session.start(Self.jobs(session, Options(preset: settings.compressionPreset, resizeLongEdge: resize, targetBytes: perFileTarget)))
    }

    struct Options {
        var preset: CompressionPreset
        var resizeLongEdge: Int
        var targetBytes: Int64?
    }

    static func jobs(_ session: ToolSession, _ options: Options) -> [ToolJob] {
        session.files.map { url in
            let format = Compressor.outputFormat(for: url)
            let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
            let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url), baseName: base, suffix: tr("compressed", "komprimiert"), ext: format.fileExtension)
            var job = session.job(tr("Compressing", "Wird verkleinert"), detail: url.lastPathComponent) { progress in
                return [try await StagingArea.writing(destination) { destination in
                    try await Compressor.compress(url, preset: options.preset, resizeLongEdge: options.resizeLongEdge, targetBytes: options.targetBytes, to: destination, progress: progress)
                }]
            }
            job.inputs = [url]
            job.reportsSizes = true
            return job
        }
    }
}
