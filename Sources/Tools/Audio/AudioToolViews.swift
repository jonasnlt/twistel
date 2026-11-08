import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct TrimAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var silence: (leading: Double, trailing: Double)?

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Trim", "Kürzen"), saveEnabled: end > start, onSave: save) {
            VStack(spacing: 10) {
                RangeTrack(duration: media.duration, start: $start, end: $end, playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: tr("Range", "Bereich")) {
                TimecodeField(title: tr("Start", "Anfang"), seconds: $start, maximum: media.duration)
                TimecodeField(title: tr("End", "Ende"), seconds: $end, maximum: media.duration)
                HStack {
                    Button(tr("Start at playhead", "Anfang bei Abspielposition")) { start = min(media.currentTime, end - 0.01) }
                    Button(tr("End at playhead", "Ende bei Abspielposition")) { end = max(media.currentTime, start + 0.01) }
                }
                .controlSize(.small)
                Text(tr("Length: \(TimeFormatter.clock(max(0, end - start)))", "Länge: \(TimeFormatter.clock(max(0, end - start)))")).font(.callout.monospacedDigit())
            }
            SidebarSection(title: tr("Silence", "Stille")) {
                Button(tr("Remove silence from beginning and end", "Stille am Anfang und Ende entfernen")) {
                    if let silence { start = silence.leading; end = silence.trailing }
                }
                .disabled(silence == nil)
                if let silence {
                    Text(tr("Detected \(TimeFormatter.clock(silence.leading)) leading and \(TimeFormatter.clock(media.duration - silence.trailing)) trailing silence.", "Gefunden: \(TimeFormatter.clock(silence.leading)) Stille am Anfang und \(TimeFormatter.clock(media.duration - silence.trailing)) am Ende.")).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(tr("Analyzing…", "Wird analysiert …")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: tr("Preview", "Vorschau")) {
                Button(tr("Play selection", "Auswahl abspielen")) { media.playRange(start, end) }
            }
        }
        .onAppear { media.loadWaveform() }
        .onChange(of: media.duration) { _, duration in if end == 0 { end = duration } }
        .task { silence = await AudioOps.detectSilence(session.primary) }
    }

    private func save() {
        session.start(Self.jobs(session, start: start, end: end))
    }

    static func jobs(_ session: ToolSession, start: Double, end: Double) -> [ToolJob] {
        let url = session.primary
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: tr("trimmed", "gekürzt"), ext: format.fileExtension)
        return [session.job(tr("Trimming", "Wird gekürzt")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await AudioOps.trim(url, start: start, end: end, to: destination, format: format, progress: progress)
            }]
        }]
    }
}

@MainActor
struct NormalizeAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var target = ToolMemory.value(.normalizeAudio, "target", default: -16.0)
    @State private var range = ToolMemory.value(.normalizeAudio, "range", default: 11.0)
    @State private var truePeak = ToolMemory.value(.normalizeAudio, "truePeak", default: -1.5)
    @State private var stats: LoudnessStats?
    @State private var analyzed = false

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? tr("Normalize", "Angleichen") : tr("Normalize \(session.files.count) files", "\(session.files.count) Dateien angleichen"), onSave: save) {
            VStack(spacing: 14) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(media.duration), playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
                HStack(spacing: 24) {
                    LevelColumn(title: tr("Input", "Eingang"), integrated: stats?.integrated, range: stats?.range, peak: stats?.truePeak, pending: !analyzed)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    LevelColumn(title: tr("Output", "Ergebnis"), integrated: target, range: range, peak: truePeak, pending: false)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: tr("Loudness", "Lautheit")) {
                LabeledSlider(title: tr("Target loudness", "Ziel-Lautheit"), value: $target, range: -30...(-8)) { String(format: "%.1f LUFS", $0) }
                LabeledSlider(title: tr("Loudness range", "Lautheitsspanne"), value: $range, range: 1...20) { String(format: "%.0f LU", $0) }
                LabeledSlider(title: tr("True peak", "Spitzenpegel"), value: $truePeak, range: -9...0) { String(format: "%.1f dBTP", $0) }
            }
            SidebarSection(title: tr("Presets", "Vorgaben")) {
                HStack {
                    Button(tr("Podcast", "Podcast")) { target = -16; range = 11; truePeak = -1.5 }
                    Button(tr("Music", "Musik")) { target = -14; range = 9; truePeak = -1 }
                    Button(tr("Broadcast", "Rundfunk")) { target = -23; range = 7; truePeak = -2 }
                }
                .controlSize(.small)
            }
            if !FFmpeg.isAvailable {
                SidebarSection(title: tr("Note", "Hinweis")) {
                    Text(tr("Without FFmpeg, \(AppIdentity.name) applies peak normalization instead of EBU R128 loudness. Set an FFmpeg path in Settings for full loudness control.", "Ohne FFmpeg gleicht \(AppIdentity.name) nur die Spitzenpegel an statt der Lautheit nach EBU R128. Für die volle Lautheitsregelung gib in den Einstellungen den Pfad zu FFmpeg an.")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { media.loadWaveform() }
        .task {
            stats = await AudioOps.measureLoudness(session.primary)
            analyzed = true
        }
    }

    private func save() {
        ToolMemory.remember(.normalizeAudio, ["target": "\(target)", "range": "\(range)", "truePeak": "\(truePeak)"])
        session.start(Self.jobs(session, target: target, range: range, truePeak: truePeak))
    }

    static func jobs(_ session: ToolSession, target: Double, range: Double, truePeak: Double) -> [ToolJob] {
        let files = session.files
        let outputs = files.map { url -> (URL, FileFormat) in
            let format = AudioOps.outputFormat(for: url)
            return (ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: tr("normalized", "angeglichen"), ext: format.fileExtension), format)
        }
        return [session.job(tr("Normalizing", "Lautstärke wird angeglichen"), detail: tr("\(files.count) file\(files.count == 1 ? "" : "s")", "\(files.count) \(files.count == 1 ? "Datei" : "Dateien")")) { progress in
            var written: [URL] = []
            for (index, url) in files.enumerated() {
                let (destination, format) = outputs[index]
                written.append(try await StagingArea.writing(destination) { destination in
                    try await AudioOps.normalize(url, targetLUFS: target, range: range, truePeak: truePeak, to: destination, format: format) { p in
                        progress((Double(index) + p) / Double(files.count))
                    }
                })
            }
            return written
        }]
    }
}

private struct LevelColumn: View {
    let title: String
    let integrated: Double?
    let range: Double?
    let peak: Double?
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            row(tr("Integrated", "Gesamt"), integrated, "LUFS")
            row(tr("Range", "Spanne"), range, "LU")
            row(tr("True peak", "Spitzenpegel"), peak, "dBTP")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: Double?, _ unit: String) -> some View {
        HStack {
            Text(label).font(.callout)
            Spacer()
            if let value {
                Text(String(format: "%.1f %@", value, unit)).font(.callout.monospacedDigit())
            } else {
                Text(pending ? "…" : tr("n/a", "–")).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
struct AudioChannelsToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var mode = ToolMemory.value(.audioChannels, "mode", default: AudioOps.ChannelMode.stereo)
    @State private var left = ToolMemory.value(.audioChannels, "left", default: 1.0)
    @State private var right = ToolMemory.value(.audioChannels, "right", default: 1.0)
    @State private var previewChannel: PreviewChannel = .both

    enum PreviewChannel: String, CaseIterable, Identifiable {
        case both, left, right
        var id: String { rawValue }
        var title: String {
            switch self {
            case .both: return tr("Both", "Beide")
            case .left: return tr("Left", "Links")
            case .right: return tr("Right", "Rechts")
            }
        }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Save copy", "Kopie sichern"), onSave: save) {
            VStack(spacing: 12) {
                RangeTrack(duration: media.duration, start: .constant(0), end: .constant(media.duration), playhead: media.currentTime, waveform: media.waveform, onScrub: { media.seek($0) })
                    .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
                HStack {
                    Text(tr("Preview", "Vorschau")).font(.callout)
                    Picker("", selection: $previewChannel) {
                        ForEach(PreviewChannel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Spacer()
                    Text(media.info.channelCount > 0 ? tr("\(media.info.channelCount) channel\(media.info.channelCount == 1 ? "" : "s") · \(Int(media.info.sampleRate)) Hz", "\(media.info.channelCount) \(media.info.channelCount == 1 ? "Kanal" : "Kanäle") · \(Int(media.info.sampleRate)) Hz") : "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: tr("Channels", "Kanäle")) {
                Picker("", selection: $mode) {
                    ForEach(AudioOps.ChannelMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
            }
            SidebarSection(title: tr("Volume", "Lautstärke")) {
                LabeledSlider(title: tr("Left", "Links"), value: $left, range: 0...2) { String(format: "%.0f%%", $0 * 100) }
                LabeledSlider(title: tr("Right", "Rechts"), value: $right, range: 0...2) { String(format: "%.0f%%", $0 * 100) }
                Button(tr("Reset", "Zurücksetzen")) { left = 1; right = 1 }.controlSize(.small)
            }
        }
        .onAppear { media.loadWaveform() }
        .onChange(of: previewChannel) { _, channel in applyPreview(channel) }
        .onChange(of: left) { _, _ in applyPreview(previewChannel) }
        .onChange(of: right) { _, _ in applyPreview(previewChannel) }
        .onChange(of: media.loaded) { _, _ in applyPreview(previewChannel) }
    }

    private func applyPreview(_ channel: PreviewChannel) {
        guard let item = media.player.currentItem else { return }
        let left = left, right = right
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            applyMix(to: item, track: track, channel: channel, left: left, right: right)
        }
    }

    private func applyMix(to item: AVPlayerItem, track: AVAssetTrack, channel: PreviewChannel, left: Double, right: Double) {
        let params = AVMutableAudioMixInputParameters(track: track)
        let mix = AVMutableAudioMix()
        switch channel {
        case .both: params.setVolume(Float(max(left, right)), at: .zero)
        case .left: params.setVolume(Float(left), at: .zero)
        case .right: params.setVolume(Float(right), at: .zero)
        }
        mix.inputParameters = [params]
        item.audioMix = mix
        media.player.volume = 1
    }

    private func save() {
        ToolMemory.remember(.audioChannels, ["mode": mode.rawValue, "left": "\(left)", "right": "\(right)"])
        session.start(Self.jobs(session, mode: mode, left: left, right: right))
    }

    static func jobs(_ session: ToolSession, mode: AudioOps.ChannelMode, left: Double, right: Double) -> [ToolJob] {
        let url = session.primary
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: mode == .mono ? "mono" : tr("channels", "Kanäle"), ext: format.fileExtension)
        return [session.job(tr("Converting channels", "Kanäle werden umgewandelt")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await AudioOps.convertChannels(url, mode: mode, leftGain: left, rightGain: right, to: destination, format: format, progress: progress)
            }]
        }]
    }
}

@MainActor
struct RedactAudioToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var ranges: [AudioOps.BleepRange] = []
    @State private var selected: UUID?
    @State private var frequency: Double = 1000

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var selectedIndex: Int? { ranges.firstIndex { $0.id == selected } }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Bleep", "Zensieren"), saveEnabled: !ranges.isEmpty, onSave: save) {
            VStack(spacing: 10) {
                RangeTrack(
                    duration: media.duration,
                    start: Binding(get: { selectedIndex.map { ranges[$0].start } ?? 0 }, set: { new in if let i = selectedIndex { ranges[i].start = min(new, ranges[i].end - 0.01) } }),
                    end: Binding(get: { selectedIndex.map { ranges[$0].end } ?? 0 }, set: { new in if let i = selectedIndex { ranges[i].end = max(new, ranges[i].start + 0.01) } }),
                    playhead: media.currentTime,
                    waveform: media.waveform,
                    markers: ranges.flatMap { [$0.start, $0.end] },
                    onScrub: { media.seek($0) }
                )
                .frame(maxHeight: .infinity)
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: tr("Bleeps (\(ranges.count))", "Pieptöne (\(ranges.count))")) {
                Button(tr("Add bleep at playhead", "Piepton bei Abspielposition hinzufügen")) {
                    let start = media.currentTime
                    let range = AudioOps.BleepRange(start: start, end: min(media.duration, start + 1))
                    ranges.append(range)
                    selected = range.id
                }
                ForEach(ranges) { range in
                    HStack {
                        Circle().fill(range.id == selected ? Color.orange : Color.secondary).frame(width: 8, height: 8)
                        Text("\(TimeFormatter.clock(range.start)) – \(TimeFormatter.clock(range.end))").font(.callout.monospacedDigit())
                        Spacer()
                        Button { media.playRange(range.start, range.end) } label: { Image(systemName: "play.fill") }
                        Button { ranges.removeAll { $0.id == range.id }; if selected == range.id { selected = nil } } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.borderless)
                    .contentShape(Rectangle())
                    .onTapGesture { selected = range.id }
                }
            }
            if let i = selectedIndex {
                SidebarSection(title: tr("Selected bleep", "Ausgewählter Piepton")) {
                    TimecodeField(title: tr("Start", "Anfang"), seconds: Binding(get: { ranges[i].start }, set: { ranges[i].start = min($0, ranges[i].end - 0.01) }), maximum: media.duration)
                    TimecodeField(title: tr("End", "Ende"), seconds: Binding(get: { ranges[i].end }, set: { ranges[i].end = max($0, ranges[i].start + 0.01) }), maximum: media.duration)
                    HStack {
                        Button(tr("Nudge −0.1 s", "−0,1 s verschieben")) { shift(i, -0.1) }
                        Button(tr("Nudge +0.1 s", "+0,1 s verschieben")) { shift(i, 0.1) }
                    }
                    .controlSize(.small)
                }
            }
            SidebarSection(title: tr("Tone", "Ton")) {
                LabeledSlider(title: tr("Frequency", "Tonhöhe"), value: $frequency, range: 300...2000) { String(format: "%.0f Hz", $0) }
            }
            SidebarSection(title: tr("Compare", "Vergleichen")) {
                Text(tr("Play a bleep row to hear the original section. The saved copy replaces those sections with the tone.", "Spiel eine Piepton-Zeile ab, um die Originalstelle zu hören. In der gesicherten Kopie sind diese Stellen durch den Ton ersetzt.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { media.loadWaveform() }
    }

    private func shift(_ index: Int, _ delta: Double) {
        let length = ranges[index].end - ranges[index].start
        let start = max(0, min(media.duration - length, ranges[index].start + delta))
        ranges[index].start = start
        ranges[index].end = start + length
    }

    private func save() {
        session.start(Self.jobs(session, ranges: ranges, frequency: frequency))
    }

    static func jobs(_ session: ToolSession, ranges: [AudioOps.BleepRange], frequency: Double) -> [ToolJob] {
        let url = session.primary
        let format = AudioOps.outputFormat(for: url)
        let destination = session.outputURL(suffix: tr("bleeped", "zensiert"), ext: format.fileExtension)
        return [session.job(tr("Bleeping", "Wird zensiert")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await AudioOps.bleep(url, ranges: ranges, frequency: frequency, to: destination, format: format, progress: progress)
            }]
        }]
    }
}

@MainActor
struct AudioToVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var style = ToolMemory.value(.audioToVideo, "style", default: AudioOps.VisualizerStyle.waveform)
    @State private var orientation = ToolMemory.value(.audioToVideo, "orientation", default: AudioOps.VisualizerOrientation.landscape)
    @State private var accent = Color.orange
    @State private var background = Color.black
    @State private var imageURL: URL?
    @State private var image: NSImage?

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Create MP4", "MP4 erstellen"), saveEnabled: FFmpeg.isAvailable && (style != .stillImage || imageURL != nil), onSave: save) {
            VStack(spacing: 12) {
                ZStack {
                    background
                    if style == .stillImage {
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        } else {
                            Text(tr("Choose an image, or drag one here", "Wähle ein Bild oder zieh eines hierher")).foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        WaveformShape(samples: media.waveform.isEmpty ? Array(repeating: 0.3, count: 120) : media.waveform)
                            .fill(accent)
                            .padding(.horizontal, 24)
                            .frame(maxHeight: style == .bars ? .infinity : nil)
                            .opacity(0.95)
                    }
                }
                .aspectRatio(orientation.size.width / orientation.size.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .fileDrop([.image]) { style = .stillImage; useImage($0[0]) }
                TransportBar(controller: media, showFrameSteps: false)
            }
            .padding(12)
        } sidebar: {
            SidebarSection(title: tr("Style", "Stil")) {
                Picker("", selection: $style) {
                    ForEach(AudioOps.VisualizerStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if style == .stillImage {
                    HStack {
                        Text(imageURL?.lastPathComponent ?? tr("No image", "Kein Bild")).font(.callout).lineLimit(1)
                        Spacer()
                        Button(tr("Choose…", "Wählen …")) { chooseImage() }
                    }
                    .fileDrop([.image]) { useImage($0[0]) }
                }
            }
            SidebarSection(title: tr("Video", "Video")) {
                Picker("", selection: $orientation) {
                    ForEach(AudioOps.VisualizerOrientation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("\(Int(orientation.size.width)) × \(Int(orientation.size.height)) · 30 fps · H.264 + AAC").font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Colors", "Farben")) {
                if style != .stillImage { ColorSwatchPicker(title: tr("Accent", "Akzent"), color: $accent) }
                ColorSwatchPicker(title: tr("Background", "Hintergrund"), color: $background)
            }
            if !FFmpeg.isAvailable {
                SidebarSection(title: tr("Requires FFmpeg", "Braucht FFmpeg")) {
                    Text(tr("Rendering a visualizer needs FFmpeg. Set its path in Settings.", "Für die Visualisierung braucht es FFmpeg. Gib den Pfad in den Einstellungen an.")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { media.loadWaveform(buckets: 240) }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useImage(url)
    }

    private func useImage(_ url: URL) {
        imageURL = url
        image = (try? ImageIOBridge.load(url, maxPixelSize: 1200)).map(ImageOps.nsImage)
    }

    private func save() {
        ToolMemory.remember(.audioToVideo, ["style": style.rawValue, "orientation": orientation.rawValue])
        session.start(Self.jobs(session, style: style, orientation: orientation, accentHex: accent.nsColor.ffmpegHex,
                                backgroundHex: background.nsColor.ffmpegHex, imageURL: imageURL))
    }

    static func jobs(_ session: ToolSession, style: AudioOps.VisualizerStyle, orientation: AudioOps.VisualizerOrientation,
                     accentHex: String, backgroundHex: String, imageURL: URL?) -> [ToolJob] {
        let url = session.primary
        let destination = session.outputURL(suffix: tr("visualizer", "Visualisierung"), ext: "mp4")
        return [session.job(tr("Creating visualizer", "Visualisierung wird erstellt")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await AudioOps.visualize(url, style: style, orientation: orientation, accent: accentHex, background: backgroundHex, image: imageURL, to: destination, progress: progress)
            }]
        }]
    }
}

extension NSColor {
    var ffmpegHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "0x%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
