import AVFoundation
import AppKit
import CoreImage
import SwiftUI

@MainActor
struct BurnSubtitlesToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var subtitles: URL?
    @State private var cues: [SubtitleCue] = []
    @State private var problem: String?
    @State private var options = SubtitleBurner.Options()
    @State private var frame: CGImage?
    @State private var videoSize = CGSize.zero
    @State private var duration = 0.0
    @State private var time = 0.0
    /// whisper's words for highlighting, heard once when first needed.
    @State private var spoken: [SubtitleCue]?
    @State private var listening: Double?
    @State private var listenTask: Task<Void, Never>?
    @State private var listenProblem: String?
    private var canListen: Bool { Transcriber.problems(whisper: Transcriber.whisperPath, modelsFolder: Transcriber.modelsFolder).isEmpty }

    init(session: ToolSession) {
        self.session = session
        var options = SubtitleBurner.Options()
        if let style = session.start["style"].flatMap(SubtitleBurner.Style.init(rawValue:)) { options.style = style }
        if let size = session.start["size"].flatMap(SubtitleBurner.Size.init(rawValue:)) { options.size = size }
        if let position = session.start["position"].flatMap(SubtitleBurner.Position.init(rawValue:)) { options.position = position }
        if let words = session.start["words"].flatMap(SubtitleBurner.Words.init(rawValue:)) { options.words = words }
        if let colour = session.start["color"].flatMap(Self.colour) { options.color = colour }
        if let colour = session.start["highlight"].flatMap(Self.colour) { options.highlight = colour }
        _options = State(initialValue: options)
        _subtitles = State(initialValue: session.start["subtitles"].map { URL(fileURLWithPath: $0) } ?? SubtitleBurner.matchingFile(for: session.primary))
    }

    private var shown: CGImage? {
        guard let frame, videoSize.width > 0 else { return nil }
        let overlay = SubtitleBurner.Overlay(cues: cues, words: SubtitleBurner.timedWords(cues, spoken: spoken ?? []), pictureSize: videoSize, options: options)
        // The same picture the video gets, in the size of the video, made smaller only by showing it.
        let input = CIImage(cgImage: frame).transformed(by: CGAffineTransform(scaleX: videoSize.width / CGFloat(frame.width), y: videoSize.height / CGFloat(frame.height)))
        return ImageOps.render(overlay.apply(to: input, at: time))
    }

    var body: some View {
        FormShell(session: session, saveTitle: tr("Burn in", "Einbrennen"), saveEnabled: !cues.isEmpty, onSave: run) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        Color.black
                        if let shown { Image(nsImage: ImageOps.nsImage(shown)).resizable().scaledToFit() } else { ProgressView() }
                    }
                    .frame(height: 400)
                    .fileDrop([], extensions: ["srt", "vtt"]) { use($0[0]) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if duration > 0 {
                        Slider(value: $time, in: 0...duration).controlSize(.small)
                        HStack {
                            Text(TimeFormatter.clock(time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button(tr("Previous", "Vorheriger")) { jump(by: -1) }.controlSize(.small).disabled(cues.isEmpty)
                            Button(tr("Next subtitle", "Nächster Untertitel")) { jump(by: 1) }.controlSize(.small).disabled(cues.isEmpty)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Subtitles", "Untertitel")).font(.headline)
                        Text(subtitles?.lastPathComponent ?? tr("No .srt file next to the video", "Keine SRT-Datei neben dem Video")).font(.callout).lineLimit(2).truncationMode(.middle)
                        if !cues.isEmpty { Text(tr("\(cues.count) subtitles", "\(cues.count) Untertitel")).font(.caption).foregroundStyle(.secondary) }
                        if let problem { Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        Button(tr("Choose .srt …", "SRT-Datei wählen …"), action: choose).controlSize(.small)
                    }
                    .fileDrop([], extensions: ["srt", "vtt"]) { use($0[0]) }
                    choice(tr("Words", "Wörter"), selection: $options.words, SubtitleBurner.Words.allCases) { $0.title }
                    if options.words != .whole { listenState }
                    choice(tr("Background", "Hintergrund"), selection: $options.style, SubtitleBurner.Style.allCases) { $0.title }
                    choice(tr("Size", "Größe"), selection: $options.size, SubtitleBurner.Size.allCases) { $0.title }
                    choice(tr("Position", "Position"), selection: $options.position, SubtitleBurner.Position.allCases) { $0.title }
                    VStack(alignment: .leading, spacing: 2) {
                        ColorSwatchPicker(title: tr("Writing", "Schrift"), color: colourBinding(\.color))
                        if options.words == .highlight { ColorSwatchPicker(title: tr("Word spoken", "Gesprochenes Wort"), color: colourBinding(\.highlight)) }
                    }
                    if options.position == .bottom {
                        Text(tr("In tall videos higher up, because Reels and Stories lay their buttons over the lowest part.", "Bei Hochformat-Videos weiter oben, weil Reels und Stories ihre Tasten über den untersten Teil legen.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 250)
            }
            Text(tr("Saved as MP4 (H.264) in normal colors, without location or other metadata. The subtitles cannot be turned off afterwards. The original stays untouched; the copy is saved to \(settings.outputLocation.title.lowercased()).", "Gesichert als MP4 (H.264) in normalen Farben, ohne Ort und andere Metadaten. Die Untertitel lassen sich danach nicht mehr ausschalten. Das Original bleibt unverändert. Ablageort der Kopie: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task {
            let url = session.primary
            let info = await MediaInfo.load(url)
            duration = info.duration
            loadCues()
            time = cues.first.map { min(($0.start + $0.end) / 2, duration) } ?? duration / 2
            await loadFrame()
        }
        .onChange(of: time) { _, _ in Task { await loadFrame() } }
        .onChange(of: options.words) { _, _ in listen() }
        .onAppear(perform: listen)
        .onDisappear { listenTask?.cancel() }
    }

    private func choice<Value: Hashable>(_ title: String, selection: Binding<Value>, _ values: [Value], label: @escaping (Value) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Picker("", selection: selection) {
                ForEach(values, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    @ViewBuilder private var listenState: some View {
        if let listening {
            HStack(spacing: 6) {
                ProgressView(value: listening).frame(width: 80)
                Text(tr("Listening for each word …", "Jedes Wort wird abgehört …")).font(.caption).foregroundStyle(.secondary)
            }
        } else if let listenProblem {
            Text(listenProblem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if !canListen {
            Text(tr("whisper is not installed: the times of the words are guessed from their length.", "whisper ist nicht installiert: Die Zeiten der Wörter werden nach ihrer Länge geschätzt.")).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        } else if spoken != nil {
            Text(tr("Times of the words from the speech (whisper).", "Zeiten der Wörter aus der Sprache (whisper).")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func colourBinding(_ path: WritableKeyPath<SubtitleBurner.Options, MarkColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: options[keyPath: path].nsColor()) }, set: { options[keyPath: path] = MarkColor($0.nsColor) })
    }

    /// For the test access: "yellow" or "1,0.5,0".
    nonisolated static func colour(_ text: String) -> MarkColor? {
        if text == "yellow" { return SubtitleBurner.Options().highlight }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        return parts.count == 3 ? MarkColor(red: parts[0], green: parts[1], blue: parts[2]) : nil
    }

    /// whisper hears the words once, in the background, when they are first needed; saving uses them.
    private func listen() {
        guard options.words != .whole, spoken == nil, listening == nil, canListen, !cues.isEmpty || subtitles != nil else { return }
        let url = session.primary, language = settings.transcriptionLanguage
        listening = 0
        listenProblem = nil
        listenTask = Task {
            do {
                let words = try await Transcriber.words(of: url, language: language) { value in Task { @MainActor in if listening != nil { listening = value } } }
                spoken = words
            } catch is CancellationError {
            } catch {
                listenProblem = error.localizedDescription
            }
            listening = nil
        }
    }

    private func loadCues() {
        problem = nil
        guard let subtitles else {
            cues = []
            return
        }
        do {
            cues = try SubtitleBurner.cues(in: subtitles)
        } catch {
            cues = []
            problem = error.localizedDescription
        }
    }

    private func loadFrame() async {
        let url = session.primary, seconds = time
        guard let image = await Task.detached(operation: { try? await VideoOps.snapshot(url, at: seconds) }).value else { return }
        videoSize = CGSize(width: image.width, height: image.height)
        frame = ImageIOBridge.resized(image, longEdge: 1920)
    }

    private func jump(by step: Int) {
        guard !cues.isEmpty else { return }
        let current = cues.firstIndex { time < $0.end } ?? cues.count - 1
        let inside = time >= cues[current].start
        let target = step > 0 ? (inside ? current + 1 : current) : current - 1
        guard cues.indices.contains(target) else { return }
        time = (cues[target].start + cues[target].end) / 2
    }

    static let subtitleTypes = [FileFormat.srt, FileFormat.vtt].compactMap(\.utType)

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.subtitleTypes
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url)
    }

    private func use(_ url: URL) {
        subtitles = url
        loadCues()
        if let first = cues.first { time = (first.start + first.end) / 2 }
    }

    private func run() {
        guard let subtitles else { return }
        session.start(Self.jobs(session, subtitles: subtitles, options: options, spoken: spoken, language: settings.transcriptionLanguage))
    }

    static func jobs(_ session: ToolSession, subtitles: URL, options: SubtitleBurner.Options, spoken: [SubtitleCue]? = nil, language: Transcriber.Language = .german) -> [ToolJob] {
        let url = session.primary
        let destination = session.outputURL(suffix: tr("subtitled", "untertitelt"), ext: "mp4")
        return [session.job(detail: url.lastPathComponent) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await SubtitleBurner.save(url, subtitles: subtitles, options: options, spoken: spoken, language: language, to: destination, progress: progress)
            }]
        }]
    }
}
