import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MergePDFToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @State private var thumbs: [URL: NSImage] = [:]
    @State private var pageCounts: [URL: Int] = [:]

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Merge", "Verbinden"), saveEnabled: files.count >= 1, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs, allowedTypes: [.pdf], addTitle: tr("Add PDFs…", "PDFs hinzufügen …"))
        } sidebar: {
            SidebarSection(title: tr("Summary", "Übersicht")) {
                Text(tr("\(files.count) document\(files.count == 1 ? "" : "s") · \(files.reduce(0) { $0 + (pageCounts[$1] ?? 0) }) pages", "\(files.count) \(files.count == 1 ? "Dokument" : "Dokumente") · \(files.reduce(0) { $0 + (pageCounts[$1] ?? 0) }) Seiten")).font(.callout.monospacedDigit())
                Text(tr("Documents are merged in list order, starting with the Finder selection order. Password-protected PDFs are skipped with an error.", "Die Dokumente werden in der Reihenfolge der Liste verbunden, anfangs wie im Finder ausgewählt. PDFs mit Passwort werden mit einer Fehlermeldung übersprungen.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: files) {
            for url in files where thumbs[url] == nil {
                guard let doc = PDFDocument(url: url) else { continue }
                pageCounts[url] = doc.pageCount
                if let page = doc.page(at: 0) {
                    thumbs[url] = page.thumbnail(of: NSSize(width: 88, height: 88), for: .mediaBox)
                }
            }
        }
    }

    private func save() {
        session.start(Self.jobs(session, files: files))
    }

    static func jobs(_ session: ToolSession, files: [URL]) -> [ToolJob] {
        let destination = session.outputURL(suffix: tr("merged", "verbunden"), ext: "pdf")
        return [session.job(tr("Merging", "Wird verbunden"), detail: "\(files.count) PDFs") { _ in
            return [try await StagingArea.writing(destination) { destination in
                try PDFOps.merge(files, to: destination)
            }]
        }]
    }
}

@MainActor
struct SplitPDFToolView: View {
    let session: ToolSession
    @State private var mode = ToolMemory.value(.splitPDF, "mode", default: PDFOps.SplitMode.everyPage)
    @State private var every = ToolMemory.value(.splitPDF, "every", default: 2)
    @State private var ranges = ""
    @State private var pageCount = 0
    @State private var thumbnails: [NSImage] = []

    private var outputCount: Int {
        switch mode {
        case .everyPage: return pageCount
        case .everyN: return every > 0 ? Int(ceil(Double(pageCount) / Double(every))) : 0
        case .ranges: return PDFOps.parseRanges(ranges, pageCount: pageCount).count
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Split into \(outputCount) files", "In \(outputCount) Dateien aufteilen"), saveEnabled: outputCount > 0, onSave: save) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                    ForEach(Array(thumbnails.enumerated()), id: \.offset) { index, image in
                        VStack(spacing: 4) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                .frame(height: 130)
                                .background(Color.white)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(groupColor(for: index + 1), lineWidth: 2))
                            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
        } sidebar: {
            SidebarSection(title: tr("Split", "Aufteilen")) {
                Picker("", selection: $mode) {
                    ForEach(PDFOps.SplitMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                switch mode {
                case .everyPage:
                    EmptyView()
                case .everyN:
                    Stepper(tr("Pages per file: \(every)", "Seiten pro Datei: \(every)"), value: $every, in: 1...max(1, pageCount))
                case .ranges:
                    TextField(tr("e.g. 1-3, 4, 5-8", "z. B. 1-3, 4, 5-8"), text: $ranges).textFieldStyle(.roundedBorder)
                    Text(tr("Comma-separated pages or ranges. Each entry becomes one file.", "Seiten oder Bereiche, durch Kommas getrennt. Jeder Eintrag wird eine eigene Datei.")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: tr("Summary", "Übersicht")) {
                Text(tr("\(pageCount) pages → \(outputCount) file\(outputCount == 1 ? "" : "s")", "\(pageCount) Seiten → \(outputCount) \(outputCount == 1 ? "Datei" : "Dateien")")).font(.callout.monospacedDigit())
                Text(tr("Output files are placed in one folder next to the original.", "Die neuen Dateien kommen in einen Ordner neben dem Original.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            guard let doc = PDFDocument(url: session.primary) else { return }
            pageCount = doc.pageCount
            ranges = "1-\(doc.pageCount)"
            thumbnails = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.thumbnail(of: NSSize(width: 220, height: 220), for: .mediaBox) }
        }
    }

    private func groupColor(for page: Int) -> Color {
        let palette: [Color] = [.orange, .blue, .green, .purple, .pink, .teal]
        let group: Int
        switch mode {
        case .everyPage: group = page - 1
        case .everyN: group = (page - 1) / max(1, every)
        case .ranges:
            guard let index = PDFOps.parseRanges(ranges, pageCount: pageCount).firstIndex(where: { $0.contains(page) }) else { return .clear }
            group = index
        }
        return palette[group % palette.count]
    }

    private func save() {
        ToolMemory.remember(.splitPDF, ["mode": mode.rawValue, "every": "\(every)"])
        session.start(Self.jobs(session, mode: mode, every: every, ranges: ranges))
    }

    static func jobs(_ session: ToolSession, mode: PDFOps.SplitMode, every: Int, ranges: String) -> [ToolJob] {
        let url = session.primary
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) \(tr("pages", "Seiten"))")
        return [session.job(tr("Splitting", "Wird aufgeteilt")) { _ in
            try await StagingArea.writingFolder(folder) { folder in
                try PDFOps.split(url, mode: mode, every: every, ranges: ranges, into: folder)
            }
        }]
    }
}

@MainActor
struct OrganizePDFToolView: View {
    let session: ToolSession
    @State private var pages: [PDFPageRef] = []
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var selected: Set<UUID> = []
    @State private var error: String?

    private var sources: [URL] { session.files }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Save copy", "Kopie sichern"), saveEnabled: !pages.isEmpty, onSave: save) {
            if let error {
                LoadingOrError(error: error)
            } else if pages.isEmpty {
                ProgressView()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(index: index, page: page, image: thumbnails[key(page)], selected: selected.contains(page.id), sourceLabel: sources.count > 1 ? page.sourceURL.lastPathComponent : nil)
                                .onTapGesture { toggle(page.id) }
                                .contextMenu {
                                    Button(tr("Rotate left", "Nach links drehen")) { rotate([page.id], by: -90) }
                                    Button(tr("Rotate right", "Nach rechts drehen")) { rotate([page.id], by: 90) }
                                    Button(tr("Duplicate", "Duplizieren")) { duplicate([page.id]) }
                                    Divider()
                                    Button(tr("Move to start", "An den Anfang")) { move(page.id, to: 0) }
                                    Button(tr("Move to end", "Ans Ende")) { move(page.id, to: pages.count) }
                                    Divider()
                                    Button(tr("Remove", "Entfernen"), role: .destructive) { remove([page.id]) }
                                }
                                .onDrag { NSItemProvider(object: page.id.uuidString as NSString) }
                                .onDrop(of: [.plainText], delegate: PageDropDelegate(target: page.id, pages: $pages))
                        }
                    }
                    .padding(16)
                }
            }
        } sidebar: {
            SidebarSection(title: tr("Selection", "Auswahl")) {
                Text(selected.isEmpty ? tr("Click pages to select. Drag to reorder.", "Klick auf Seiten, um sie auszuwählen. Zieh sie, um die Reihenfolge zu ändern.") : tr("\(selected.count) selected", "\(selected.count) ausgewählt")).font(.callout)
                HStack {
                    Button(tr("All", "Alle")) { selected = Set(pages.map(\.id)) }
                    Button(tr("None", "Keine")) { selected.removeAll() }
                }
                .controlSize(.small)
            }
            SidebarSection(title: tr("Pages", "Seiten")) {
                let targets = selected.isEmpty ? pages.map(\.id) : Array(selected)
                HStack {
                    Button { rotate(targets, by: -90) } label: { Label(tr("Left", "Links"), systemImage: "rotate.left") }
                    Button { rotate(targets, by: 90) } label: { Label(tr("Right", "Rechts"), systemImage: "rotate.right") }
                }
                Button(tr("Duplicate", "Duplizieren")) { duplicate(targets) }.disabled(selected.isEmpty)
                Button(tr("Remove", "Entfernen"), role: .destructive) { remove(targets) }.disabled(selected.isEmpty || selected.count == pages.count)
                Button(tr("Reverse order", "Reihenfolge umkehren")) { pages.reverse() }
                Button(tr("Save selection as new PDF", "Auswahl als neue PDF sichern")) { saveSelection() }.disabled(selected.isEmpty)
            }
            SidebarSection(title: tr("Summary", "Übersicht")) {
                Text(tr("\(pages.count) page\(pages.count == 1 ? "" : "s")", "\(pages.count) \(pages.count == 1 ? "Seite" : "Seiten")")).font(.callout.monospacedDigit())
                if sources.count > 1 {
                    Text(tr("Pages from \(sources.count) documents are combined into one.", "Seiten aus \(sources.count) Dokumenten werden zu einem zusammengefügt.")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .task { load() }
        .onDeleteCommand { if !selected.isEmpty { remove(Array(selected)) } }
    }

    private func key(_ page: PDFPageRef) -> String { "\(page.sourceURL.path)#\(page.sourceIndex)" }

    private func load() {
        var refs: [PDFPageRef] = []
        for url in sources {
            guard let doc = PDFDocument(url: url) else { error = tr("Could not open \(url.lastPathComponent).", "\(url.lastPathComponent) lässt sich nicht öffnen."); return }
            if doc.isLocked { error = tr("\(url.lastPathComponent) is password protected.", "\(url.lastPathComponent) ist mit einem Passwort geschützt."); return }
            for index in 0..<doc.pageCount {
                let ref = PDFPageRef(sourceIndex: index, rotation: doc.page(at: index)?.rotation ?? 0, sourceURL: url)
                refs.append(ref)
                if let page = doc.page(at: index) {
                    thumbnails[key(ref)] = page.thumbnail(of: NSSize(width: 260, height: 260), for: .mediaBox)
                }
            }
        }
        pages = refs
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = selected == [id] ? [] : [id]
        }
    }

    private func rotate(_ ids: [UUID], by degrees: Int) {
        for index in pages.indices where ids.contains(pages[index].id) {
            pages[index].rotation = ((pages[index].rotation + degrees) % 360 + 360) % 360
        }
    }

    private func duplicate(_ ids: [UUID]) {
        var result: [PDFPageRef] = []
        for page in pages {
            result.append(page)
            if ids.contains(page.id) {
                result.append(PDFPageRef(sourceIndex: page.sourceIndex, rotation: page.rotation, sourceURL: page.sourceURL))
            }
        }
        pages = result
    }

    private func remove(_ ids: [UUID]) {
        guard pages.count > ids.count else { return }
        pages.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
    }

    private func move(_ id: UUID, to index: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: min(index > from ? index - 1 : index, pages.count))
    }

    /// Saves the selected pages as their own PDF and keeps the window open, so several selections can be saved in turn.
    private func saveSelection() {
        let chosen = PDFOps.selection(of: pages, selected: selected)
        guard !chosen.isEmpty else { return }
        Self.selectionJob(session, chosen: chosen).start()
    }

    static func selectionJob(_ session: ToolSession, chosen: [PDFPageRef]) -> ToolJob {
        let destination = session.outputURL(suffix: tr("selection", "Auswahl"), ext: "pdf")
        return session.job(tr("Saving selection", "Auswahl wird gesichert"), detail: tr("\(chosen.count) page\(chosen.count == 1 ? "" : "s")", "\(chosen.count) \(chosen.count == 1 ? "Seite" : "Seiten")")) { _ in
            return [try await StagingArea.writing(destination) { destination in
                try PDFOps.assemble(pages: chosen, to: destination)
            }]
        }
    }

    private func save() {
        session.start(Self.jobs(session, pages: pages))
    }

    static func jobs(_ session: ToolSession, pages: [PDFPageRef]) -> [ToolJob] {
        let destination = session.outputURL(suffix: tr("organized", "geordnet"), ext: "pdf")
        return [session.job(tr("Organizing", "Seiten werden geordnet")) { _ in
            return [try await StagingArea.writing(destination) { destination in
                try PDFOps.assemble(pages: pages, to: destination)
            }]
        }]
    }
}

private struct PageCell: View {
    let index: Int
    let page: PDFPageRef
    let image: NSImage?
    let selected: Bool
    let sourceLabel: String?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(page.rotation)))
                        .padding(6)
                }
            }
            .frame(height: 160)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accentForeground : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let sourceLabel {
                Text(sourceLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: UUID
    @Binding var pages: [PDFPageRef]

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let id = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                guard let from = pages.firstIndex(where: { $0.id == id }), let to = pages.firstIndex(where: { $0.id == target }), from != to else { return }
                let page = pages.remove(at: from)
                pages.insert(page, at: to)
            }
        }
        return true
    }
}
