import AppKit
import PDFKit
import SwiftUI

@MainActor
struct ComparePDFToolView: View {
    enum Show: String, CaseIterable, Identifiable {
        case sideBySide, overlay
        var id: String { rawValue }
        var title: String { self == .sideBySide ? tr("Side by side", "Nebeneinander") : tr("On top of each other", "Übereinander") }
    }

    let session: ToolSession
    @State private var oldFile: URL?
    @State private var newFile: URL?
    @State private var result: PDFComparison?
    @State private var failure: String?
    @State private var step: String?
    @State private var progress = 0.0
    @State private var work: Task<Void, Never>?
    @State private var index = 0
    @State private var show = Show.sideBySide
    @State private var onlyDifferent = true
    @State private var pictures: PDFComparison.Pictures?

    init(session: ToolSession) {
        self.session = session
        let (old, new) = Self.oldAndNew(session.files)
        _oldFile = State(initialValue: old)
        _newFile = State(initialValue: new)
        _show = State(initialValue: session.start["show"].flatMap(Show.init(rawValue:)) ?? .sideBySide)
    }

    private var shown: [PDFComparison.PagePair] {
        guard let result else { return [] }
        let list = onlyDifferent ? result.pairs.filter(result.hasDifferences) : result.pairs
        return list
    }
    private var pair: PDFComparison.PagePair? { shown.indices.contains(index) ? shown[index] : nil }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Save report", "Bericht sichern"), saveEnabled: result != nil, onSave: save) {
            VStack(spacing: 8) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    content
                }
                // One PDF here is the second; two are both, the older as old.
                .fileDrop([.pdf], multiple: true) { urls in
                    if urls.count > 1 {
                        (oldFile, newFile) = Self.oldAndNew(urls)
                    } else if let first = oldFile {
                        (oldFile, newFile) = Self.oldAndNew([first, urls[0]])
                    } else {
                        oldFile = urls[0]
                    }
                    restart()
                }
                if shown.count > 1 {
                    HStack {
                        Button { index -= 1 } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                        Text(tr("\(index + 1) of \(shown.count)", "\(index + 1) von \(shown.count)")).font(.callout.monospacedDigit())
                        Button { index += 1 } label: { Image(systemName: "chevron.right") }.disabled(index >= shown.count - 1)
                    }
                    .padding(.bottom, 8)
                }
            }
        } sidebar: {
            SidebarSection(title: tr("Files", "Dateien")) {
                fileRow(tr("Old", "Alt"), file: oldFile) { oldFile = choose() ?? oldFile; restart() }
                    .fileDrop([.pdf]) { oldFile = $0[0]; restart() }
                Button {
                    swap(&oldFile, &newFile)
                    restart()
                } label: {
                    Label(tr("Swap old and new", "Alt und neu tauschen"), systemImage: "arrow.up.arrow.down").frame(maxWidth: .infinity)
                }
                .controlSize(.large).disabled(oldFile == nil || newFile == nil)
                .help(tr("The older file (by date changed) is taken as old", "Die ältere Datei (nach Änderungsdatum) gilt als alt"))
                fileRow(tr("New", "Neu"), file: newFile) { newFile = choose() ?? newFile; restart() }
                    .fileDrop([.pdf]) { newFile = $0[0]; restart() }
            }
            if let result {
                SidebarSection(title: tr("Result", "Ergebnis")) {
                    ForEach(PDFComparisonReport.summary(result), id: \.self) { Text($0).font(.caption).fixedSize(horizontal: false, vertical: true) }
                    Toggle(tr("Only pages that differ", "Nur Seiten mit Unterschieden"), isOn: $onlyDifferent)
                    Picker("", selection: $show) {
                        ForEach(Show.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                if let pair {
                    SidebarSection(title: PDFComparisonReport.title(of: pair)) {
                        let changes = result.changes(on: pair)
                        if changes.isEmpty {
                            Text(pair.regions.isEmpty ? tr("No text differs.", "Der Text ist gleich.") : tr("The text is the same; the pictures differ.", "Der Text ist gleich, die Bilder unterscheiden sich.")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(changes.prefix(60).enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 1) {
                                if !change.oldText.isEmpty { Text("− \(change.oldText)").foregroundStyle(Color(nsColor: PDFComparisonReport.removed.nsColor())) }
                                if !change.newText.isEmpty { Text("+ \(change.newText)").foregroundStyle(Color(nsColor: PDFComparisonReport.added.nsColor())) }
                            }
                            .font(.caption)
                            .textSelection(.enabled)
                        }
                        if changes.count > 60 { Text(tr("… and \(changes.count - 60) more, in the report.", "… und \(changes.count - 60) weitere im Bericht.")).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .onAppear(perform: restart)
        .onChange(of: onlyDifferent) { _, _ in index = 0 }
        .task(id: "\(index) \(result?.pairs.count ?? -1) \(onlyDifferent)") { await loadPictures() }
    }

    @ViewBuilder private var content: some View {
        if newFile == nil {
            VStack(spacing: 10) {
                Text(tr("Choose the second PDF to compare with, or drag it here.", "Wähle die zweite PDF zum Vergleichen oder zieh sie hierher.")).foregroundStyle(.secondary)
                Button(tr("Choose PDF …", "PDF wählen …")) { newFile = choose(); restart() }
            }
        } else if let failure {
            LoadingOrError(error: failure)
        } else if result == nil {
            VStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 240)
                Text(step ?? tr("Comparing …", "Wird verglichen …")).font(.caption).foregroundStyle(.secondary)
            }
        } else if let result, shown.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Theme.accentForeground)
                Text(result.pairs.isEmpty ? tr("These files have no pages.", "Diese Dateien haben keine Seiten.") : tr("No differences found.", "Keine Unterschiede gefunden.")).foregroundStyle(.secondary)
            }
        } else if let pictures, let pair, let result {
            let changes = result.changes(on: pair)
            GeometryReader { proxy in
                if show == .overlay, let overlay = pictures.overlay {
                    ComparePanel(caption: tr("Red: only in the old file. Green: only in the new file.", "Rot: nur in der alten Datei. Grün: nur in der neuen Datei."), image: overlay, boxes: [], color: .red, frames: pair.regions)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    HStack(spacing: 10) {
                        if let old = pictures.old {
                            ComparePanel(caption: tr("Old", "Alt"), image: old, boxes: changes.flatMap(\.oldPlaces).filter { $0.page == pair.old }.map(\.box), color: PDFComparisonReport.removed, frames: [])
                        }
                        if let new = pictures.new {
                            ComparePanel(caption: tr("New", "Neu"), image: new, boxes: changes.flatMap(\.newPlaces).filter { $0.page == pair.new }.map(\.box), color: PDFComparisonReport.added, frames: [])
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .padding(12)
        } else {
            ProgressView()
        }
    }

    private func fileRow(_ title: String, file: URL?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(file?.lastPathComponent ?? tr("None", "Keine")).font(.caption).lineLimit(1).truncationMode(.middle)
                if let changed = file.flatMap(Self.changed) {
                    Text(tr("changed \(changed.formatted(date: .numeric, time: .shortened))", "geändert \(changed.formatted(date: .numeric, time: .shortened))")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(tr("Choose …", "Wählen …"), action: choose).controlSize(.mini)
        }
    }

    /// Read fresh each time: a URL keeps what it once read.
    nonisolated static func changed(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Two files dropped together come in no particular order: the one changed earlier is the old one. Same time: the one made earlier, then by name.
    nonisolated static func oldAndNew(_ files: [URL]) -> (old: URL?, new: URL?) {
        guard files.count > 1 else { return (files.first, nil) }
        let pair = Array(files.prefix(2))
        func made(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date }
        let sorted = pair.sorted { a, b in
            if let x = changed(a), let y = changed(b), x != y { return x < y }
            if let x = made(a), let y = made(b), x != y { return x < y }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        return (sorted[0], sorted[1])
    }

    private func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func restart() {
        work?.cancel()
        result = nil
        failure = nil
        pictures = nil
        index = 0
        guard let old = oldFile, let new = newFile else { return }
        progress = 0
        let job = Task.detached(priority: .userInitiated) { () -> Result<PDFComparison, Error> in
            do {
                return .success(try await PDFComparison.compare(old, new) { value, text in
                    Task { @MainActor in
                        progress = value
                        if let text { step = text }
                    }
                })
            } catch {
                return .failure(error)
            }
        }
        work = Task {
            let outcome = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let value): result = value
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }

    private func loadPictures() async {
        guard let result, let pair else {
            pictures = nil
            return
        }
        let loaded = await Task.detached { try? result.pictures(of: pair, dpi: 150) }.value
        guard !Task.isCancelled else { return }
        pictures = loaded
    }

    private func save() {
        guard let result else { return }
        session.start(Self.jobs(session, result: result))
    }

    /// `result`: as already worked out in the window; otherwise it is worked out in the job.
    static func jobs(_ session: ToolSession, result: PDFComparison? = nil, old: URL? = nil, new: URL? = nil) -> [ToolJob] {
        let first = result?.oldURL ?? old ?? session.primary, second = result?.newURL ?? new ?? session.files[1]
        let a = ConversionMatrix.strippedBaseName(first.lastPathComponent), b = ConversionMatrix.strippedBaseName(second.lastPathComponent)
        let name = tr("\(a) vs \(b)", "Vergleich \(a) mit \(b)")
        let destination = session.outputURL(suffix: tr("comparison", ""), ext: "pdf", baseName: name)
        var job = ToolJob(title: session.tool.progressTitle, detail: name, symbol: session.tool.symbol, steps: { report in
            let done: PDFComparison
            if let result {
                done = result
            } else {
                done = try await PDFComparison.compare(first, second) { value, text in report(value * 0.7, text) }
            }
            return [try await StagingArea.writing(destination) { destination in
                try PDFComparisonReport.write(done, to: destination) { report(0.7 + $0 * 0.3, tr("Writing the report", "Bericht wird geschrieben")) }
            }]
        })
        job.outputFolder = session.outputDirectory
        return [job]
    }
}

/// A page with its marks.
private struct ComparePanel: View {
    let caption: String
    let image: CGImage
    let boxes: [CGRect]
    let color: MarkColor
    let frames: [CGRect]

    init(caption: String, image: CGImage, boxes: [CGRect], color: MarkColor, frames: [CGRect]) {
        self.caption = caption
        self.image = image
        self.boxes = boxes
        self.color = color
        self.frames = frames
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            GeometryReader { proxy in
                let fit = FitGeometry(container: proxy.size, image: CGSize(width: image.width, height: image.height))
                let shown = fit.displayRect
                ZStack(alignment: .topLeading) {
                    Color.clear
                    Image(nsImage: ImageOps.nsImage(image)).resizable().interpolation(.high)
                        .frame(width: shown.width, height: shown.height)
                        .offset(x: shown.minX, y: shown.minY)
                    Canvas { context, _ in
                        func place(_ box: CGRect) -> CGRect {
                            CGRect(x: shown.minX + box.minX * shown.width, y: shown.minY + box.minY * shown.height, width: box.width * shown.width, height: box.height * shown.height)
                        }
                        for box in boxes { context.fill(Path(place(box).insetBy(dx: -1, dy: -1)), with: .color(Color(nsColor: color.nsColor(alpha: 0.35)))) }
                        for frame in frames { context.stroke(Path(place(frame).insetBy(dx: -2, dy: -2)), with: .color(.orange), lineWidth: 1.5) }
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
