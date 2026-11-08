import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OrderedFileList: View {
    @Binding var files: [URL]
    var thumbnails: [URL: NSImage] = [:]
    var allowedTypes: [UTType] = [.image]
    var addTitle = tr("Add images…", "Bilder hinzufügen …")

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(files.enumerated()), id: \.element) { index, url in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        if let thumb = thumbnails[url] {
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 36, height: 36)
                        }
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(FileSizeFormatter.string(FileSizeFormatter.size(of: url))).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index == files.count - 1)
                        Button { files.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }.disabled(files.count <= 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
                .onMove { from, to in files.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                Button(addTitle) { add() }
                Button(tr("Sort by name", "Nach Name sortieren")) { files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } }
                Spacer()
                Text(tr("Drag rows to reorder, or files in to add", "Zieh Zeilen, um die Reihenfolge zu ändern, oder Dateien hinein, um sie hinzuzufügen")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .fileDrop(allowedTypes, multiple: true, action: add)
    }

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }
}

@MainActor
final class ThumbnailCache: ObservableObject {
    @Published var images: [URL: NSImage] = [:]

    func load(_ urls: [URL], maxPixels: Int = 320) {
        for url in urls where images[url] == nil {
            Task.detached { [url] in
                guard let cg = try? ImageIOBridge.load(url, maxPixelSize: maxPixels) else { return }
                let ns = ImageOps.nsImage(cg)
                await MainActor.run { self.images[url] = ns }
            }
        }
    }
}

@MainActor
struct CreatePDFToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @StateObject private var thumbs = ThumbnailCache()
    /// Starts with the layout from Settings; a change here applies to this PDF only.
    @State private var layout: PDFRenderer.ImagePageLayout

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
        _layout = State(initialValue: ToolMemory.value(.createPDF, "layout", default: AppSettings.shared.imagesToPDFLayout))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Create PDF", "PDF erstellen"), saveEnabled: !files.isEmpty, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs.images)
        } sidebar: {
            SidebarSection(title: tr("Pages", "Seiten")) {
                Picker("", selection: $layout) {
                    ForEach(PDFRenderer.ImagePageLayout.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Text(tr("One page per image, in list order. A4 and US Letter turn to landscape for wide images and fit each image with a small margin. \u{201C}Same as image\u{201D} gives each page the image's shape, with no white border.", "Eine Seite pro Bild, in der Reihenfolge der Liste. A4 und US Letter werden bei breiten Bildern zum Querformat und zeigen jedes Bild mit einem kleinen Rand. \u{201E}Wie das Bild (ohne Rand)\u{201C} gibt jeder Seite die Form des Bilds, ohne weißen Rand."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Summary", "Übersicht")) {
                Text(tr("\(files.count) page\(files.count == 1 ? "" : "s")", "\(files.count) \(files.count == 1 ? "Seite" : "Seiten")")).font(.callout)
            }
        }
        .onAppear { thumbs.load(files) }
        .onChange(of: files) { _, new in thumbs.load(new) }
    }

    private func save() {
        ToolMemory.remember(.createPDF, ["layout": layout.rawValue])
        session.start(Self.jobs(session, files: files, layout: layout))
    }

    static func jobs(_ session: ToolSession, files: [URL], layout: PDFRenderer.ImagePageLayout) -> [ToolJob] {
        let destination = session.outputURL(suffix: files.count > 1 ? tr("combined", "verbunden") : "", ext: "pdf")
        return [session.job(tr("Creating PDF", "PDF wird erstellt"), detail: tr("\(files.count) image\(files.count == 1 ? "" : "s")", "\(files.count) \(files.count == 1 ? "Bild" : "Bilder")")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try PDFRenderer.writeImagesPDF(files, layout: layout, to: destination, progress: progress)
            }]
        }]
    }
}

@MainActor
struct CollageToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @StateObject private var thumbs = ThumbnailCache()
    @State private var layout = ToolMemory.value(.createCollage, "layout", default: ImageOps.CollageLayout.grid)
    @State private var width = ToolMemory.value(.createCollage, "width", default: 2400)
    @State private var height = ToolMemory.value(.createCollage, "height", default: 2400)
    @State private var spacing = ToolMemory.value(.createCollage, "spacing", default: 24.0)
    @State private var corner = ToolMemory.value(.createCollage, "corner", default: 16.0)
    @State private var background = Color.white
    @State private var preview: NSImage?
    @State private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    private var options: ImageOps.CollageOptions {
        var o = ImageOps.CollageOptions()
        o.layout = layout
        o.width = CGFloat(max(64, width))
        o.height = CGFloat(max(64, height))
        o.spacing = spacing
        o.cornerRadius = corner
        o.background = background.nsColor
        return o
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Save collage", "Collage sichern"), saveEnabled: files.count >= 2, onSave: save) {
            HSplitView {
                OrderedFileList(files: $files, thumbnails: thumbs.images)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                ZStack {
                    CheckerboardBackground()
                    if let preview {
                        Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(16)
                    } else {
                        ProgressView()
                    }
                }
                .frame(minWidth: 320)
            }
        } sidebar: {
            SidebarSection(title: tr("Layout", "Anordnung")) {
                Picker("", selection: $layout) {
                    ForEach(ImageOps.CollageLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            SidebarSection(title: tr("Final size", "Endgröße")) {
                NumberField(title: tr("Width", "Breite"), value: $width, suffix: "px", range: 64...10_000)
                NumberField(title: tr("Height", "Höhe"), value: $height, suffix: "px", range: 64...10_000)
                HStack {
                    Button(tr("Square", "Quadratisch")) { width = 2400; height = 2400 }
                    Button(tr("Landscape", "Querformat")) { width = 3000; height = 2000 }
                    Button(tr("Portrait", "Hochformat")) { width = 2000; height = 3000 }
                }
                .controlSize(.mini)
            }
            SidebarSection(title: tr("Style", "Stil")) {
                LabeledSlider(title: tr("Spacing", "Abstand"), value: $spacing, range: 0...200) { String(format: "%.0f px", $0) }
                LabeledSlider(title: tr("Corner radius", "Eckenradius"), value: $corner, range: 0...200) { String(format: "%.0f px", $0) }
                ColorSwatchPicker(title: tr("Background", "Hintergrund"), color: $background)
            }
        }
        .onAppear { thumbs.load(files, maxPixels: 600); render() }
        .onChange(of: files) { _, new in thumbs.load(new, maxPixels: 600); render() }
        .onChange(of: thumbs.images.count) { _, _ in render() }
        .onChange(of: layout) { _, _ in render() }
        .onChange(of: width) { _, _ in render() }
        .onChange(of: height) { _, _ in render() }
        .onChange(of: spacing) { _, _ in render() }
        .onChange(of: corner) { _, _ in render() }
        .onChange(of: background) { _, _ in render() }
    }

    private func render() {
        renderTask?.cancel()
        let images = files.compactMap { thumbs.images[$0]?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        guard !images.isEmpty else { return }
        var scaled = options
        let scale = min(1, 1200 / max(scaled.width, scaled.height))
        scaled.width *= scale
        scaled.height *= scale
        scaled.spacing *= scale
        scaled.cornerRadius *= scale
        let o = scaled
        renderTask = Task.detached(priority: .userInitiated) {
            guard let cg = ImageOps.collage(images, options: o), !Task.isCancelled else { return }
            let ns = ImageOps.nsImage(cg)
            await MainActor.run { preview = ns }
        }
    }

    private func save() {
        ToolMemory.remember(.createCollage, ["layout": layout.rawValue, "width": "\(width)", "height": "\(height)", "spacing": "\(spacing)", "corner": "\(corner)"])
        session.start(Self.jobs(session, files: files, options: options))
    }

    static func jobs(_ session: ToolSession, files: [URL], options: ImageOps.CollageOptions) -> [ToolJob] {
        [ImageToolSupport.job(session, suffix: tr("collage", "Collage"), format: .jpg, title: tr("Creating collage", "Collage wird erstellt")) {
            let images = try files.map { try ImageIOBridge.load($0, maxPixelSize: 4000) }
            guard let cg = ImageOps.collage(images, options: options) else { throw AppError.encodeFailed(tr("Collage rendering failed", "Collage konnte nicht erstellt werden")) }
            return cg
        }]
    }
}
