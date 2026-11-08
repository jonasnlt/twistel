import SwiftUI

@MainActor
struct VideoPresetsToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var preset: VideoPreset
    @State private var frame: CGImage?
    @State private var duration = 0.0
    @State private var time = 0.0
    @State private var important: CGRect?
    @State private var found: SmartCrop.Found?
    /// Cuts placed by hand for the video shown, per format, as fractions of the picture (origin top left).
    @State private var chosen: [VideoPreset: CGRect]

    init(session: ToolSession) {
        self.session = session
        let preset = session.start["preset"].flatMap(VideoPreset.init(rawValue:)) ?? ToolMemory.value(.videoPresets, "preset", default: VideoPreset.reels)
        _preset = State(initialValue: preset)
        _chosen = State(initialValue: session.start["window"].flatMap(SocialMediaToolView.fraction).map { [preset: $0] } ?? [:])
    }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? tr("Save", "Sichern") : tr("Save \(session.files.count) videos", "\(session.files.count) Videos sichern"), onSave: run) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    previewPanel
                    if duration > 0 {
                        // To see whether the subject stays in the frame: the frame does not follow it.
                        Slider(value: $time, in: 0...duration)
                            .controlSize(.small)
                    }
                    if preset.isCrop, frame != nil {
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
                    presetGroup(tr("Crop to", "Zuschneiden auf"), VideoPreset.crops)
                    presetGroup(tr("Make smaller to send", "Zum Verschicken verkleinern"), VideoPreset.sends)
                }
                .frame(width: 250)
            }
            FormHint(hint)
            Text(tr("Saved as MP4 (H.264) in normal colors, without location or other metadata. Originals stay untouched; the copies are saved to \(settings.outputLocation.title.lowercased()).", "Gesichert als MP4 (H.264) in normalen Farben, ohne Ort und andere Metadaten. Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task {
            let url = session.primary
            let length = await MediaInfo.load(url).duration
            duration = length
            time = length / 2
            await loadFrame()
            guard let frame else { return }
            let result = await SmartCrop.importantRegion(in: frame)
            important = result.rect
            found = result.found
        }
        .onChange(of: time) { _, _ in Task { await loadFrame() } }
    }

    private func loadFrame() async {
        let url = session.primary, seconds = time
        guard let image = await Task.detached(operation: { try? await VideoOps.snapshot(url, at: seconds) }).value else { return }
        frame = ImageIOBridge.resized(image, longEdge: 1200)
    }

    private var hint: String {
        guard preset.isCrop else {
            return tr("Nothing is cut off; the video is made smaller until it fits the size. A video that does not fit is saved anyway, with a note.", "Es wird nichts abgeschnitten; das Video wird verkleinert, bis es in die Größe passt. Ein Video, das nicht passt, wird trotzdem gesichert, mit einem Hinweis.")
        }
        let many = session.files.count > 1 ? tr(" The frame you move is used for the video shown; the others are cut on their own.", " Dein Rahmen gilt für das gezeigte Video; die anderen werden selbsttätig zugeschnitten.") : ""
        let still = tr(" The frame stays where it is for the whole video: move the slider to check.", " Der Rahmen bleibt das ganze Video über an derselben Stelle: Prüf es mit dem Schieberegler.")
        if chosen[preset] != nil { return tr("Your frame is used.", "Dein Rahmen wird verwendet.") + still + many }
        switch found {
        case .faces: return tr("Face found in the middle of the video: the frame starts there.", "Gesicht in der Mitte des Videos gefunden: Der Rahmen beginnt dort.") + still + many
        case .people: return tr("Person found in the middle of the video: the frame starts there.", "Person in der Mitte des Videos gefunden: Der Rahmen beginnt dort.") + still + many
        case .subject: return tr("Main subject found in the middle of the video: the frame starts there.", "Hauptmotiv in der Mitte des Videos gefunden: Der Rahmen beginnt dort.") + still + many
        case .nothing, .chosen: return tr("No face or clear subject found: cut in the middle.", "Kein Gesicht und kein klares Motiv gefunden: Zuschnitt in der Mitte.") + still + many
        case nil: return tr("Looking for faces and the main subject …", "Gesichter und Hauptmotiv werden gesucht …")
        }
    }

    private func presetGroup(_ title: String, _ presets: [VideoPreset]) -> some View {
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
        if let frame {
            let size = CGSize(width: frame.width, height: frame.height)
            if case let .crop(width, height, _) = preset.kind {
                let aspect = CGSize(width: width, height: height)
                let automatic = SmartCrop.window(imageSize: size, aspect: aspect, important: important)
                let window = chosen[preset].map { SmartCrop.window(fraction: $0, imageSize: size, aspect: aspect) } ?? automatic
                CropFrameCanvas(image: frame, aspect: aspect, window: window) { moved in
                    chosen[preset] = CGRect(x: moved.minX / size.width, y: moved.minY / size.height, width: moved.width / size.width, height: moved.height / size.height)
                }
                .id(preset)
                .frame(height: 340)
            } else {
                CropFrameCanvas(image: frame, aspect: nil, window: CGRect(origin: .zero, size: size)) { _ in }
                    .frame(height: 340)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).frame(height: 340)
        }
    }

    private func run() {
        ToolMemory.remember(.videoPresets, ["preset": preset.rawValue])
        session.start(Self.jobs(session, preset: preset, chosen: chosen[preset]))
    }

    /// `chosen` (a cut placed by hand, fractions) applies to the first video, the one shown.
    static func jobs(_ session: ToolSession, preset: VideoPreset, chosen: CGRect? = nil) -> [ToolJob] {
        session.files.enumerated().map { index, url in
            let destination = VideoPresets.outputURL(for: url, preset: preset)
            let cut = index == 0 && preset.isCrop ? chosen : nil
            return session.job(detail: url.lastPathComponent) { progress in
                return [try await StagingArea.writing(destination) { destination in
                    try await VideoPresets.save(url, preset: preset, chosen: cut, to: destination, progress: progress)
                }]
            }
        }
    }
}
