import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct CropVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var frame: NSImage?
    @State private var rects: [RectangleOverlay] = []
    @State private var selected: UUID?
    @State private var aspect = AspectPreset.all[0]
    @State private var outWidth = 0
    @State private var outHeight = 0
    @State private var keepSize = true

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var cropRect: CGRect? { rects.first?.rect }
    private var videoSize: CGSize { media.info.naturalSize }
    private var aspectRatio: CGFloat? {
        guard let ratio = aspect.ratio else { return nil }
        if ratio < 0, videoSize.height > 0 { return videoSize.width / videoSize.height }
        return ratio
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Crop", "Zuschneiden"), saveEnabled: cropRect.map { $0.width > 8 && $0.height > 8 } ?? false, onSave: save) {
            VStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let frame {
                        RectangleEditorCanvas(image: frame, imageSize: videoSize, rectangles: $rects, selected: $selected, allowMultiple: false, aspect: aspectRatio)
                    } else {
                        ProgressView()
                    }
                }
                TransportBar(controller: media)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: tr("Aspect ratio", "Seitenverhältnis")) {
                Picker("", selection: $aspect) {
                    ForEach(AspectPreset.all) { Text($0.shownTitle).tag($0) }
                }
                .labelsHidden()
            }
            SidebarSection(title: tr("Crop area", "Ausschnitt")) {
                if let rect = cropRect {
                    Text(tr("\(Int(rect.width)) × \(Int(rect.height)) at \(Int(rect.minX)), \(Int(rect.minY))", "\(Int(rect.width)) × \(Int(rect.height)) bei \(Int(rect.minX)), \(Int(rect.minY))")).font(.callout.monospacedDigit())
                }
                Text(tr("Video: \(Int(videoSize.width)) × \(Int(videoSize.height))", "Video: \(Int(videoSize.width)) × \(Int(videoSize.height))")).font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Output dimensions", "Maße des Ergebnisses")) {
                Toggle(tr("Same as crop area", "Wie Ausschnitt"), isOn: $keepSize)
                NumberField(title: tr("Width", "Breite"), value: $outWidth, suffix: "px").disabled(keepSize)
                NumberField(title: tr("Height", "Höhe"), value: $outHeight, suffix: "px").disabled(keepSize)
                Text(tr("Audio is kept as is. Output is MP4 (H.264).", "Der Ton bleibt, wie er ist. Ergebnis ist ein MP4 (H.264).")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.currentTime) { _, _ in loadFrame() }
        .onChange(of: media.loaded) { _, loaded in
            guard loaded else { return }
            loadFrame()
            let inset = CGRect(origin: .zero, size: videoSize).insetBy(dx: videoSize.width * 0.1, dy: videoSize.height * 0.1)
            let id = UUID()
            rects = [RectangleOverlay(id: id, rect: inset.integral, color: .orange, label: "")]
            selected = id
        }
        .onChange(of: rects) { _, new in
            if keepSize, let rect = new.first?.rect { outWidth = Int(rect.width); outHeight = Int(rect.height) }
        }
        .onChange(of: aspect) { _, _ in
            guard let ratio = aspectRatio, let rect = cropRect else { return }
            var new = rect
            new.size.height = rect.width / ratio
            if new.maxY > videoSize.height { new.size.height = videoSize.height - rect.minY; new.size.width = new.height * ratio }
            rects = [RectangleOverlay(id: rects[0].id, rect: new.integral, color: .orange, label: "")]
        }
    }

    private func loadFrame() {
        let url = session.primary
        let time = media.currentTime
        Task.detached {
            guard let cg = try? await VideoOps.snapshot(url, at: time) else { return }
            let ns = ImageOps.nsImage(cg)
            await MainActor.run { frame = ns }
        }
    }

    private func save() {
        guard let rect = cropRect else { return }
        session.start(Self.jobs(session, rect: rect, outputSize: keepSize ? nil : CGSize(width: outWidth, height: outHeight)))
    }

    /// `outputSize` nil keeps the cropped size.
    static func jobs(_ session: ToolSession, rect: CGRect, outputSize: CGSize?) -> [ToolJob] {
        let url = session.primary
        let even = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: (rect.width / 2).rounded(.down) * 2, height: (rect.height / 2).rounded(.down) * 2)
        let output: CGSize? = outputSize.map { CGSize(width: ($0.width / 2).rounded(.down) * 2, height: ($0.height / 2).rounded(.down) * 2) }
        let destination = session.outputURL(suffix: tr("cropped", "zugeschnitten"), ext: "mp4")
        return [session.job(tr("Cropping", "Wird zugeschnitten")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await VideoOps.crop(url, rect: even, outputSize: output, to: destination, progress: progress)
            }]
        }]
    }
}

@MainActor
struct VideoSpeedToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var factor = ToolMemory.value(.changeVideoSpeed, "factor", default: 2.0)
    @State private var preservePitch = ToolMemory.value(.changeVideoSpeed, "preservePitch", default: true)

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Save copy", "Kopie sichern"), onSave: save) {
            PlayerSurface(player: media.player)
                .background(Color.black)
        } sidebar: {
            SidebarSection(title: tr("Speed", "Tempo")) {
                LabeledSlider(title: tr("Factor", "Faktor"), value: $factor, range: 0.1...8) { String(format: "%.2f×", $0) }
                HStack {
                    ForEach([0.25, 0.5, 1.5, 2, 4], id: \.self) { value in
                        Button(String(format: "%g×", value)) { factor = value }.controlSize(.mini)
                    }
                }
                Text(tr("New length: \(TimeFormatter.clock(media.duration / factor))", "Neue Länge: \(TimeFormatter.clock(media.duration / factor))")).font(.callout.monospacedDigit())
            }
            SidebarSection(title: tr("Audio", "Ton")) {
                Toggle(tr("Preserve pitch", "Tonhöhe beibehalten"), isOn: $preservePitch).disabled(!media.info.hasAudio)
                Text(media.info.hasAudio ? tr("Pitch is kept natural; disable for a classic tape-speed effect.", "Die Tonhöhe bleibt natürlich. Schalte es aus für den klassischen Kassetten-Effekt.") : tr("This video has no audio track.", "Dieses Video hat keine Tonspur.")).font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Preview", "Vorschau")) {
                Button(media.isPlaying ? tr("Pause", "Pause") : tr("Play at \(String(format: "%g", factor))×", "Mit \(String(format: "%g", factor))× abspielen")) {
                    if media.isPlaying { media.pause() } else {
                        media.player.currentItem?.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
                        media.player.rate = Float(factor)
                        media.isPlaying = true
                    }
                }
            }
        }
    }

    private func save() {
        ToolMemory.remember(.changeVideoSpeed, ["factor": "\(factor)", "preservePitch": "\(preservePitch)"])
        session.start(Self.jobs(session, factor: factor, preservePitch: preservePitch))
    }

    static func jobs(_ session: ToolSession, factor: Double, preservePitch: Bool) -> [ToolJob] {
        let url = session.primary
        let destination = session.outputURL(suffix: String(format: "%gx", factor), ext: "mp4")
        return [session.job(tr("Changing speed", "Tempo wird geändert")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await VideoOps.changeSpeed(url, factor: factor, preservePitch: preservePitch, to: destination, progress: progress)
            }]
        }]
    }
}

@MainActor
struct JoinVideosToolView: View {
    let session: ToolSession
    @State private var files: [URL]
    @State private var thumbs: [URL: NSImage] = [:]
    @State private var infos: [URL: MediaInfo] = [:]

    init(session: ToolSession) {
        self.session = session
        _files = State(initialValue: session.files)
    }

    private var totalDuration: Double { files.reduce(0) { $0 + (infos[$1]?.duration ?? 0) } }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Join \(files.count) clips", "\(files.count) Teile verbinden"), saveEnabled: files.count >= 2, onSave: save) {
            OrderedFileList(files: $files, thumbnails: thumbs, allowedTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie], addTitle: tr("Add clips…", "Videos hinzufügen …"))
        } sidebar: {
            SidebarSection(title: tr("Canvas", "Bildgröße")) {
                if let first = files.first, let info = infos[first] {
                    Text(tr("\(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height)) from the first clip", "\(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height)) vom ersten Video")).font(.callout)
                }
                Text(tr("Other clips are scaled to fit and letterboxed if their aspect ratio differs. Output is a single MP4.", "Die anderen Videos werden eingepasst und bekommen schwarze Balken, wenn ihr Seitenverhältnis abweicht. Ergebnis ist ein einziges MP4.")).font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Summary", "Übersicht")) {
                Text(tr("\(files.count) clips · \(TimeFormatter.clock(totalDuration))", "\(files.count) Videos · \(TimeFormatter.clock(totalDuration))")).font(.callout.monospacedDigit())
            }
        }
        .task(id: files) { await loadInfo() }
    }

    private func loadInfo() async {
        for url in files where infos[url] == nil {
            infos[url] = await MediaInfo.load(url)
            if let cg = try? await VideoOps.snapshot(url, at: 0.5) {
                thumbs[url] = ImageOps.nsImage(ImageIOBridge.resized(cg, longEdge: 200))
            }
        }
    }

    private func save() {
        session.start(Self.jobs(session, files: files))
    }

    static func jobs(_ session: ToolSession, files: [URL]) -> [ToolJob] {
        let destination = session.outputURL(suffix: tr("joined", "verbunden"), ext: "mp4")
        return [session.job(tr("Joining", "Wird verbunden"), detail: tr("\(files.count) videos", "\(files.count) Videos")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await VideoOps.join(files, to: destination, progress: progress)
            }]
        }]
    }
}
