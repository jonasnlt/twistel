import CoreImage
import SwiftUI

@MainActor
struct RedactImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var rects: [RectangleOverlay] = []
    @State private var selected: UUID?
    @State private var styles: [UUID: RedactionStyle] = [:]
    @State private var defaultStyle: RedactionStyle = .solid
    @State private var color = Color.black
    @State private var rendered: NSImage?
    @State private var renderTask: Task<Void, Never>?
    @StateObject private var search = RedactionSearch()

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 2000))
    }

    private var redactions: [Redaction] {
        rects.map { overlay in
            var r = Redaction(rect: overlay.rect)
            r.style = styles[overlay.id] ?? defaultStyle
            r.color = color.nsColor.cgColor
            return r
        } + Self.redactions(of: search.chosen, imageSize: document.size, style: defaultStyle, color: color.nsColor.cgColor)
    }

    /// Found places in pixels, in the style and colour chosen. Text is always covered solid: blurred or pixelated writing can sometimes be worked out.
    nonisolated static func redactions(of finds: [RedactionFinder.Find], imageSize: CGSize, style: RedactionStyle, color: CGColor = CGColor(gray: 0, alpha: 1)) -> [Redaction] {
        finds.flatMap { find in
            PDFRedactor.cover(of: find).map { box in
                var redaction = Redaction(rect: CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height, width: box.width * imageSize.width, height: box.height * imageSize.height))
                redaction.isFace = find.kind == .face
                redaction.style = redaction.isFace ? style : .solid
                redaction.color = color
                return redaction
            }
        }
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: !rects.isEmpty || !search.ticked.isEmpty, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    // Always the result itself: only what is left unticked is marked, and the area being edited.
                    ZStack {
                        RectangleEditorCanvas(image: rendered ?? preview, imageSize: document.size, rectangles: $rects, selected: $selected, allowMultiple: true, plain: true)
                        RedactionFindsOverlay(finds: search.left, ticked: [], imageSize: document.size)
                    }
                    .padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            RedactionFindPanel(search: search, showsPages: false, onFind: find)
            SidebarSection(title: tr("Redaction style", "Art der Schwärzung")) {
                Picker("", selection: styleBinding) {
                    ForEach(RedactionStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if (selected.flatMap { styles[$0] } ?? defaultStyle) == .solid {
                    ColorSwatchPicker(title: tr("Color", "Farbe"), color: $color)
                }
                Text(selected == nil ? tr("Applies to everything found and to all areas. Text found is always covered solid: blurred or pixelated writing can sometimes be worked out.", "Gilt für alle Funde und alle Bereiche. Gefundener Text wird immer deckend abgedeckt: Unscharfe oder verpixelte Schrift lässt sich manchmal noch entziffern.") : tr("Applies to the selected area. Click beside the areas to change everything.", "Gilt für den ausgewählten Bereich. Klick neben die Bereiche, um alles zu ändern.")).font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Areas (\(rects.count))", "Bereiche (\(rects.count))")) {
                if rects.isEmpty {
                    Text(tr("Drag on the photo to cover an area. Drag areas to move them and their corners to resize.", "Zieh auf dem Foto, um einen Bereich abzudecken. Zieh Bereiche, um sie zu verschieben, und ihre Ecken, um die Größe zu ändern.")).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rects) { overlay in
                    HStack {
                        Circle().fill(overlay.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        Text(tr("Area \(overlay.label)", "Bereich \(overlay.label)")).font(.callout)
                        Text((styles[overlay.id] ?? defaultStyle).title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { remove(overlay.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = overlay.id }
                }
                if !rects.isEmpty {
                    Button(tr("Remove all", "Alle entfernen")) { rects.removeAll(); styles.removeAll(); selected = nil }.controlSize(.small)
                }
            }
        }
        .onChange(of: rects) { _, _ in relabel(); scheduleRender() }
        .onChange(of: styles) { _, _ in scheduleRender() }
        .onChange(of: color) { _, _ in scheduleRender() }
        .onChange(of: defaultStyle) { _, _ in scheduleRender() }
        .onChange(of: document.size) { _, _ in scheduleRender() }
        .onChange(of: search.ticked) { _, _ in scheduleRender() }
        .task {
            if let terms = session.start["terms"] { search.termsText = terms.replacingOccurrences(of: "|", with: "\n") }
            if let patterns = session.start["patterns"] { search.patterns = Set(patterns.split(separator: ",").compactMap { RedactionFinder.Pattern(rawValue: String($0)) }) }
            if session.start["faces"] == "true" { search.faces = true }
            if let style = session.start["faceStyle"].flatMap(RedactionStyle.init(rawValue:)) { defaultStyle = style }
            if let style = session.start["style"].flatMap(RedactionStyle.init(rawValue:)) { defaultStyle = style }
            if session.start["color"] == "red" { color = .red }
            // areas=x,y,width,height;… in pixels.
            rects = (session.start["areas"] ?? "").split(separator: ";").enumerated().compactMap { index, part in
                let numbers = part.split(separator: ",").compactMap { Double($0) }
                return numbers.count == 4 ? RectangleOverlay(id: UUID(), rect: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), color: .orange, label: "\(index + 1)") : nil
            }
            if !search.request.isEmpty { find() }
        }
        .onDeleteCommand { if let selected { remove(selected) } }
    }

    private var styleBinding: Binding<RedactionStyle> {
        Binding(
            get: { selected.flatMap { styles[$0] } ?? defaultStyle },
            set: { new in
                if let selected { styles[selected] = new } else { defaultStyle = new }
                scheduleRender()
            }
        )
    }

    private func remove(_ id: UUID) {
        rects.removeAll { $0.id == id }
        styles.removeValue(forKey: id)
        if selected == id { selected = nil }
    }

    private func relabel() {
        for index in rects.indices where rects[index].label != "\(index + 1)" {
            rects[index].label = "\(index + 1)"
        }
    }

    /// A smaller copy of the picture as it will be saved. `redactions` in the places of the full picture.
    nonisolated static func preview(of picture: CGImage, fullSize: CGSize, redactions: [Redaction]) -> CGImage? {
        let scale = CGFloat(picture.width) / fullSize.width
        let scaled = redactions.map { redaction -> Redaction in
            var copy = redaction
            copy.rect = redaction.rect.applying(CGAffineTransform(scaleX: scale, y: scale))
            return copy
        }
        return ImageToolSupport.cgImage(ImageOps.redact(CIImage(cgImage: picture), redactions: scaled, scale: scale))
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil), document.size.width > 0 else { return }
        let redactions = redactions, size = document.size
        renderTask = Task.detached(priority: .userInitiated) {
            guard let image = Self.preview(of: cg, fullSize: size, redactions: redactions), !Task.isCancelled else { return }
            let ns = ImageOps.nsImage(image)
            await MainActor.run { rendered = ns }
        }
    }

    private func find() {
        let url = session.primary
        search.start { request, _ in
            RedactionFinder.Result(finds: try await RedactionFinder.find(in: try ImageIOBridge.load(url), request: request))
        }
    }

    private func save() {
        guard let original = document.original else { return }
        let gone = RedactionFinder.gone(ticked: search.chosen, left: search.left)
        session.start(Self.jobs(session, original: original, redactions: redactions, terms: gone.terms, parts: gone.parts))
    }

    /// `terms`, `parts`: words covered here that must not be readable any more.
    static func jobs(_ session: ToolSession, original: CGImage, redactions: [Redaction], terms: [String] = [], parts: [String] = []) -> [ToolJob] {
        let format = ImageToolSupport.outputFormat(for: session.primary)
        let destination = session.outputURL(suffix: tr("redacted", "geschwärzt"), ext: format.fileExtension)
        let quality = AppSettings.shared.jpegQuality
        return [session.job(detail: session.primary.lastPathComponent) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await ImageRedactor.save(original, redactions: redactions, terms: terms, parts: parts, format: format, quality: quality, to: destination, progress: progress)
            }]
        }]
    }
}
