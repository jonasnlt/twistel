import SwiftUI

@MainActor
struct SocialMediaToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var preset: SocialPreset
    @State private var preview: CGImage?
    @State private var important: CGRect?
    @State private var found: SmartCrop.Found?
    /// Cuts placed by hand for the picture shown, per format, as fractions of the picture (origin top left).
    @State private var chosen: [SocialPreset: CGRect]

    init(session: ToolSession) {
        self.session = session
        let preset = session.start["preset"].flatMap(SocialPreset.init(rawValue:)) ?? ToolMemory.value(.socialMedia, "preset", default: SocialPreset.instagramPortrait)
        _preset = State(initialValue: preset)
        _chosen = State(initialValue: session.start["window"].flatMap(Self.fraction).map { [preset: $0] } ?? [:])
    }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? tr("Save", "Sichern") : tr("Save \(session.files.count) pictures", "\(session.files.count) Bilder sichern"), onSave: run) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    previewPanel
                    if preset.isCrop, preview != nil {
                        HStack {
                            Text(tr("Drag the frame to move it, drag a corner to resize it.", "Zieh den Rahmen, um ihn zu verschieben, oder eine Ecke, um die Größe zu ändern."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button(tr("Reset", "Zurücksetzen")) { chosen[preset] = nil }
                                .controlSize(.small)
                                .disabled(chosen[preset] == nil)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 14) {
                    presetGroup(tr("Crop to", "Zuschneiden auf"), SocialPreset.crops)
                    presetGroup(tr("Make smaller to send", "Zum Verschicken verkleinern"), SocialPreset.sends)
                }
                .frame(width: 250)
            }
            FormHint(hint)
            Text(tr("Saved as JPEG without location or other metadata. Originals stay untouched; the copies are saved to \(settings.outputLocation.title.lowercased()).", "Gesichert als JPEG ohne Ort und andere Metadaten. Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task {
            let url = session.primary
            guard let image = await Task.detached(operation: { try? ImageIOBridge.load(url, maxPixelSize: 1200) }).value else { return }
            preview = image
            let result = await SmartCrop.importantRegion(in: image)
            important = result.rect
            found = result.found
        }
    }

    private var hint: String {
        guard preset.isCrop else {
            return tr("Nothing is cut off; the picture is made smaller until it fits the size. Smaller pictures stay as they are.", "Es wird nichts abgeschnitten; das Bild wird verkleinert, bis es in die Größe passt. Kleinere Bilder bleiben, wie sie sind.")
        }
        let many = session.files.count > 1 ? tr(" The frame you move is used for the picture shown; the others are cut on their own.", " Dein Rahmen gilt für das gezeigte Bild; die anderen werden selbsttätig zugeschnitten.") : ""
        if chosen[preset] != nil { return tr("Your frame is used.", "Dein Rahmen wird verwendet.") + many }
        switch found {
        case .faces: return tr("Faces found: the cut keeps them in the picture.", "Gesichter gefunden: Der Zuschnitt behält sie im Bild.") + many
        case .people: return tr("People found: the cut keeps them in the picture.", "Personen gefunden: Der Zuschnitt behält sie im Bild.") + many
        case .subject: return tr("Main subject found: the cut keeps it in the picture.", "Hauptmotiv gefunden: Der Zuschnitt behält es im Bild.") + many
        case .nothing, .chosen: return tr("No face or clear subject found: cut in the middle.", "Kein Gesicht und kein klares Motiv gefunden: Zuschnitt in der Mitte.") + many
        case nil: return tr("Looking for faces and the main subject …", "Gesichter und Hauptmotiv werden gesucht …")
        }
    }

    private func presetGroup(_ title: String, _ presets: [SocialPreset]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).padding(.bottom, 2)
            ForEach(presets) { item in
                Button { preset = item } label: {
                    HStack(spacing: 8) {
                        Image(systemName: preset == item ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(preset == item ? Theme.accentForeground : .secondary)
                        Text(item.title)
                        Spacer(minLength: 4)
                        Text(item.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder private var previewPanel: some View {
        if let preview {
            let size = CGSize(width: preview.width, height: preview.height)
            if case let .crop(width, height) = preset.kind {
                let aspect = CGSize(width: width, height: height)
                let automatic = SmartCrop.window(imageSize: size, aspect: aspect, important: important)
                let window = chosen[preset].map { SmartCrop.window(fraction: $0, imageSize: size, aspect: aspect) } ?? automatic
                CropFrameCanvas(image: preview, aspect: aspect, window: window) { moved in
                    chosen[preset] = CGRect(x: moved.minX / size.width, y: moved.minY / size.height,
                                            width: moved.width / size.width, height: moved.height / size.height)
                }
                .id(preset)
                .frame(height: 360)
            } else {
                CropFrameCanvas(image: preview, aspect: nil, window: CGRect(origin: .zero, size: size)) { _ in }
                    .frame(height: 360)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).frame(height: 360)
        }
    }

    private func run() {
        ToolMemory.remember(.socialMedia, ["preset": preset.rawValue])
        session.start(Self.jobs(session, preset: preset, chosen: chosen[preset]))
    }

    /// `chosen` (a cut placed by hand, fractions) applies to the first picture, the one shown.
    static func jobs(_ session: ToolSession, preset: SocialPreset, chosen: CGRect? = nil) -> [ToolJob] {
        session.files.enumerated().map { index, url in
            let destination = SocialMedia.outputURL(for: url, preset: preset)
            let cut = index == 0 && preset.isCrop ? chosen : nil
            return session.job(detail: url.lastPathComponent) { progress in
                progress(0.1)
                return [try await StagingArea.writing(destination) { destination in
                    try await SocialMedia.save(url, preset: preset, chosen: cut, to: destination)
                }]
            }
        }
    }

    /// "x,y,width,height" as fractions (test access).
    static func fraction(_ text: String) -> CGRect? {
        let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return numbers.count == 4 ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : nil
    }
}

/// The picture with the cut on it: outside the frame dimmed. The frame moves when dragged and changes size at its
/// corners, keeping its shape. Without `aspect` only the picture is shown.
struct CropFrameCanvas: View {
    let image: CGImage
    let aspect: CGSize?
    /// The cut in pixels of `image`, origin top left.
    let window: CGRect
    let onChange: (CGRect) -> Void

    private enum Drag {
        case move(CGRect)
        case corner(Int)
        case none
    }

    @State private var drag: Drag?

    var body: some View {
        GeometryReader { proxy in
            let size = CGSize(width: image.width, height: image.height)
            let fit = FitGeometry(container: proxy.size, image: size)
            let picture = fit.displayRect
            let shown = fit.toDisplay(window)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: picture.width, height: picture.height)
                    .offset(x: picture.minX, y: picture.minY)
                if aspect != nil {
                    Path { path in
                        path.addRect(picture)
                        path.addRect(shown)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Path { $0.addRect(shown) }
                        .stroke(Color.white, lineWidth: 2)
                    ForEach(0..<4, id: \.self) { index in
                        let point = SmartCrop.corner(index, of: shown)
                        Rectangle()
                            .fill(Color.white)
                            .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                            .frame(width: 10, height: 10)
                            .position(point)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .local)
                    .onChanged { value in changed(value, fit: fit) }
                    .onEnded { _ in drag = nil }
            )
        }
    }

    private func changed(_ value: DragGesture.Value, fit: FitGeometry) {
        guard let aspect else { return }
        let size = CGSize(width: image.width, height: image.height)
        if drag == nil {
            let shown = fit.toDisplay(window)
            if let index = (0..<4).first(where: { hypot(SmartCrop.corner($0, of: shown).x - value.startLocation.x,
                                                        SmartCrop.corner($0, of: shown).y - value.startLocation.y) < 14 }) {
                drag = .corner(index)
            } else if shown.contains(value.startLocation) {
                drag = .move(window)
            } else {
                drag = Drag.none
            }
        }
        switch drag ?? Drag.none {
        case .move(let start):
            let delta = CGSize(width: value.translation.width / fit.scale, height: value.translation.height / fit.scale)
            onChange(SmartCrop.moved(start, by: delta, imageSize: size))
        case .corner(let index):
            // At least a tenth of the largest possible frame, so it can still be grabbed.
            let largest = SmartCrop.window(imageSize: size, aspect: aspect, important: nil)
            onChange(SmartCrop.resized(window, corner: index, to: fit.toImage(value.location), aspect: aspect, imageSize: size,
                                       minimumWidth: largest.width / 10))
        case .none:
            break
        }
    }
}
