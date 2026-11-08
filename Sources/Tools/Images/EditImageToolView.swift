import CoreImage
import SwiftUI

@MainActor
struct EditImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var adjustments = PhotoAdjustments()
    @State private var rendered: NSImage?
    @State private var showOriginal = false
    @State private var renderTask: Task<Void, Never>?

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1800))
    }

    var body: some View {
        ToolShell(session: session, saveEnabled: document.original != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let image = (showOriginal ? document.preview : rendered) ?? document.preview {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(12)
                } else {
                    LoadingOrError(error: document.error)
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(showOriginal ? tr("Showing original", "Original wird gezeigt") : tr("Hold to compare", "Zum Vergleichen gedrückt halten")) {}
                            .buttonStyle(.bordered)
                            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in showOriginal = true }.onEnded { _ in showOriginal = false })
                            .padding(12)
                    }
                }
            }
        } sidebar: {
            SidebarSection(title: tr("Light", "Licht")) {
                LabeledSlider(title: tr("Exposure", "Belichtung"), value: $adjustments.exposure, range: -2...2)
                LabeledSlider(title: tr("Brightness", "Helligkeit"), value: $adjustments.brightness, range: -0.5...0.5)
                LabeledSlider(title: tr("Contrast", "Kontrast"), value: $adjustments.contrast, range: 0.5...1.5)
                LabeledSlider(title: tr("Highlights", "Lichter"), value: $adjustments.highlights, range: 0.3...1)
                LabeledSlider(title: tr("Shadows", "Tiefen"), value: $adjustments.shadows, range: -1...1)
            }
            SidebarSection(title: tr("Color", "Farbe")) {
                LabeledSlider(title: tr("Saturation", "Sättigung"), value: $adjustments.saturation, range: 0...2)
                LabeledSlider(title: tr("Vibrance", "Lebendigkeit"), value: $adjustments.vibrance, range: -1...1)
                LabeledSlider(title: tr("Temperature", "Farbtemperatur"), value: $adjustments.temperature, range: 3000...10000) { String(format: "%.0fK", $0) }
                LabeledSlider(title: tr("Tint", "Farbton"), value: $adjustments.tint, range: -100...100) { String(format: "%.0f", $0) }
                Toggle(tr("Monochrome", "Schwarzweiß"), isOn: $adjustments.monochrome)
                LabeledSlider(title: tr("Sepia", "Sepia"), value: $adjustments.sepia, range: 0...1)
            }
            SidebarSection(title: tr("Detail", "Details")) {
                LabeledSlider(title: tr("Sharpness", "Schärfe"), value: $adjustments.sharpness, range: 0...2)
                LabeledSlider(title: tr("Clarity", "Klarheit"), value: $adjustments.clarity, range: 0...1)
                LabeledSlider(title: tr("Dehaze", "Dunst entfernen"), value: $adjustments.dehaze, range: 0...1)
                LabeledSlider(title: tr("Noise reduction", "Rauschreduzierung"), value: $adjustments.noiseReduction, range: 0...1)
            }
            SidebarSection(title: tr("Effects", "Effekte")) {
                LabeledSlider(title: tr("Grain", "Körnung"), value: $adjustments.grain, range: 0...1)
                LabeledSlider(title: tr("Vignette", "Vignette"), value: $adjustments.vignette, range: 0...2)
            }
            Button(tr("Reset all", "Alle zurücksetzen")) { adjustments = PhotoAdjustments() }
                .buttonStyle(.link)
        }
        .onChange(of: adjustments) { _, _ in scheduleRender() }
        .onChange(of: document.preview) { _, _ in scheduleRender() }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let preview = document.preview, let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let adjustments = adjustments
        renderTask = Task.detached(priority: .userInitiated) {
            let output = ImageOps.adjusted(CIImage(cgImage: cg), adjustments)
            guard !Task.isCancelled, let image = ImageToolSupport.cgImage(output) else { return }
            let ns = ImageOps.nsImage(image)
            await MainActor.run { rendered = ns }
        }
    }

    private func save() {
        guard let original = document.original else { return }
        session.start(Self.jobs(session, original: original, adjustments: adjustments))
    }

    static func jobs(_ session: ToolSession, original: CGImage, adjustments: PhotoAdjustments) -> [ToolJob] {
        [ImageToolSupport.job(session, suffix: tr("edited", "bearbeitet")) {
            let output = ImageOps.adjusted(CIImage(cgImage: original), adjustments)
            guard let image = ImageToolSupport.cgImage(output, like: original) else { throw AppError.encodeFailed(tr("Rendering failed", "Bild konnte nicht erstellt werden")) }
            return image
        }]
    }
}
