import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FrameImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var backgroundKind: Kind = .color
    @State private var color = Color.white
    @State private var gradientA = Color(red: 1.0, green: 0.6, blue: 0.2)
    @State private var gradientB = Color(red: 0.95, green: 0.25, blue: 0.45)
    @State private var gradientAngle: Double = 45
    @State private var backgroundImageURL: URL?
    @State private var backgroundImage: CGImage?
    @State private var backgroundBlur: Double = 30
    @State private var aspect = AspectPreset.all[1]
    @State private var padding: Double = 0.08
    @State private var corner: Double = 24
    @State private var shadow: Double = 24
    @State private var rendered: NSImage?
    @State private var renderTask: Task<Void, Never>?

    enum Kind: String, CaseIterable, Identifiable {
        case color, gradient, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .color: return tr("Color", "Farbe")
            case .gradient: return tr("Gradient", "Verlauf")
            case .image: return tr("Image", "Bild")
            }
        }
    }

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1400))
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: document.original != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let rendered {
                    Image(nsImage: rendered).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: tr("Background", "Hintergrund")) {
                Picker("", selection: $backgroundKind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch backgroundKind {
                case .color:
                    ColorSwatchPicker(title: tr("Color", "Farbe"), color: $color)
                case .gradient:
                    ColorSwatchPicker(title: tr("Start", "Anfang"), color: $gradientA)
                    ColorSwatchPicker(title: tr("End", "Ende"), color: $gradientB)
                    LabeledSlider(title: tr("Angle", "Winkel"), value: $gradientAngle, range: 0...360) { String(format: "%.0f°", $0) }
                case .image:
                    HStack {
                        Text(backgroundImageURL?.lastPathComponent ?? tr("Same photo, blurred", "Dasselbe Foto, unscharf")).font(.callout).lineLimit(1)
                        Spacer()
                        Button(tr("Choose…", "Wählen …")) { chooseBackground() }
                    }
                    .fileDrop([.image]) { useBackground($0[0]) }
                    LabeledSlider(title: tr("Blur", "Unschärfe"), value: $backgroundBlur, range: 0...100) { String(format: "%.0f", $0) }
                }
            }
            SidebarSection(title: tr("Canvas", "Fläche")) {
                Picker(tr("Aspect ratio", "Seitenverhältnis"), selection: $aspect) {
                    ForEach(AspectPreset.all.filter { $0.ratio != nil }) { Text($0.shownTitle).tag($0) }
                }
                LabeledSlider(title: tr("Spacing", "Abstand"), value: $padding, range: 0...0.3) { String(format: "%.0f%%", $0 * 100) }
                LabeledSlider(title: tr("Corner radius", "Eckenradius"), value: $corner, range: 0...200) { String(format: "%.0f px", $0) }
                LabeledSlider(title: tr("Shadow", "Schatten"), value: $shadow, range: 0...120) { String(format: "%.0f", $0) }
            }
        }
        .onChange(of: document.preview) { _, _ in scheduleRender() }
        .onChange(of: backgroundKind) { _, _ in scheduleRender() }
        .onChange(of: color) { _, _ in scheduleRender() }
        .onChange(of: gradientA) { _, _ in scheduleRender() }
        .onChange(of: gradientB) { _, _ in scheduleRender() }
        .onChange(of: gradientAngle) { _, _ in scheduleRender() }
        .onChange(of: backgroundBlur) { _, _ in scheduleRender() }
        .onChange(of: aspect) { _, _ in scheduleRender() }
        .onChange(of: padding) { _, _ in scheduleRender() }
        .onChange(of: corner) { _, _ in scheduleRender() }
        .onChange(of: shadow) { _, _ in scheduleRender() }
        .onChange(of: backgroundImageURL) { _, _ in scheduleRender() }
    }

    private func options(scale: CGFloat, source: CGImage) -> ImageOps.FrameOptions {
        var options = ImageOps.FrameOptions()
        if let ratio = aspect.ratio {
            options.aspect = ratio < 0 ? CGSize(width: source.width, height: source.height) : CGSize(width: ratio, height: 1)
        }
        options.padding = padding
        options.cornerRadius = corner * scale
        options.shadow = shadow * scale
        switch backgroundKind {
        case .color: options.background = .color(color.nsColor)
        case .gradient: options.background = .gradient(gradientA.nsColor, gradientB.nsColor, angle: gradientAngle)
        case .image: options.background = .image(backgroundImage ?? source, blur: backgroundBlur * scale)
        }
        return options
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil), let original = document.original else { return }
        let scale = CGFloat(cg.width) / CGFloat(original.width)
        let opts = options(scale: scale, source: cg)
        renderTask = Task.detached(priority: .userInitiated) {
            guard let framed = ImageOps.framed(cg, options: opts), !Task.isCancelled else { return }
            let ns = ImageOps.nsImage(framed)
            await MainActor.run { rendered = ns }
        }
    }

    private func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useBackground(url)
    }

    private func useBackground(_ url: URL) {
        guard let image = try? ImageIOBridge.load(url, maxPixelSize: 3000) else { return }
        backgroundImageURL = url
        backgroundImage = image
    }

    private func save() {
        guard let original = document.original else { return }
        let opts = options(scale: 1, source: original)
        let format: FileFormat = backgroundKind == .color && color.nsColor.alphaComponent >= 1 ? ImageToolSupport.outputFormat(for: session.primary) : .png
        session.start(Self.jobs(session, original: original, frame: opts, format: format))
    }

    static func jobs(_ session: ToolSession, original: CGImage, frame: ImageOps.FrameOptions, format: FileFormat) -> [ToolJob] {
        [ImageToolSupport.job(session, suffix: tr("framed", "gerahmt"), format: format) {
            guard let framed = ImageOps.framed(original, options: frame) else { throw AppError.encodeFailed(tr("Rendering failed", "Bild konnte nicht erstellt werden")) }
            return framed
        }]
    }
}
