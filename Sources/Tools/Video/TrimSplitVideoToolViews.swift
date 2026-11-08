import AVFoundation
import SwiftUI

@MainActor
struct TrimVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var start: Double = 0
    @State private var end: Double = 0

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Trim", "Kürzen"), saveEnabled: end > start, onSave: save) {
            VideoStage(player: media.player) {
                RangeTrack(duration: media.duration, start: $start, end: $end, playhead: media.currentTime, onScrub: { media.seek($0) })
            }
        } sidebar: {
            SidebarSection(title: tr("Range", "Bereich")) {
                TimecodeField(title: tr("Start", "Anfang"), seconds: $start, maximum: media.duration)
                TimecodeField(title: tr("End", "Ende"), seconds: $end, maximum: media.duration)
                HStack {
                    Button(tr("Set start to playhead", "Anfang bei Abspielposition")) { start = min(media.currentTime, end - 0.05) }
                    Button(tr("Set end", "Ende setzen")) { end = max(media.currentTime, start + 0.05) }
                }
                .controlSize(.small)
                Text(tr("Length: \(TimeFormatter.clock(max(0, end - start)))", "Länge: \(TimeFormatter.clock(max(0, end - start)))")).font(.callout.monospacedDigit())
            }
            SidebarSection(title: tr("Preview", "Vorschau")) {
                Button(tr("Play selection", "Auswahl abspielen")) { media.playRange(start, end) }
                Text(tr("Use the frame buttons or ← → to step frame by frame while the video is paused.", "Mit den Bild-Tasten oder ← → gehst du bei angehaltenem Video Bild für Bild weiter.")).font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Output", "Ergebnis")) {
                Text(tr("The selection is copied without re-encoding when the format allows it, so the trim is fast and lossless.", "Wenn das Format es erlaubt, wird die Auswahl ohne Neuberechnung kopiert. Das Kürzen geht dann schnell und ohne Qualitätsverlust.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.duration) { _, duration in if end == 0 { end = duration } }
        .onChange(of: start) { _, new in if abs(media.currentTime - new) > 0.01 { media.seek(new) } }
        .onChange(of: end) { _, new in media.seek(new) }
        .background(KeyCaptureView { key in
            switch key {
            case .left: media.stepFrame(-1)
            case .right: media.stepFrame(1)
            case .space: media.togglePlay()
            }
        })
    }

    private func save() {
        session.start(Self.jobs(session, start: start, end: end))
    }

    static func jobs(_ session: ToolSession, start: Double, end: Double) -> [ToolJob] {
        let url = session.primary
        let destination = session.outputURL(suffix: tr("trimmed", "gekürzt"), ext: url.pathExtension)
        return [session.job(tr("Trimming", "Wird gekürzt")) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await VideoOps.trim(url, start: start, end: end, to: destination, progress: progress)
            }]
        }]
    }
}

@MainActor
struct SplitVideoToolView: View {
    let session: ToolSession
    @StateObject private var media: MediaController
    @State private var mode: Mode = .points
    @State private var points: [Double] = []
    @State private var parts = 2
    @State private var unusedStart: Double = 0
    @State private var unusedEnd: Double = 0

    enum Mode: String, CaseIterable, Identifiable {
        case points, equal
        var id: String { rawValue }
        var title: String { self == .points ? tr("Custom points", "Eigene Stellen") : tr("Equal parts", "Gleiche Teile") }
    }

    init(session: ToolSession) {
        self.session = session
        _media = StateObject(wrappedValue: MediaController(url: session.primary))
    }

    private var effectivePoints: [Double] {
        switch mode {
        case .points: return points.sorted()
        case .equal:
            guard parts > 1, media.duration > 0 else { return [] }
            return (1..<parts).map { media.duration * Double($0) / Double(parts) }
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Split into \(effectivePoints.count + 1) clips", "In \(effectivePoints.count + 1) Teile aufteilen"), saveEnabled: !effectivePoints.isEmpty, onSave: save) {
            VideoStage(player: media.player) {
                RangeTrack(duration: media.duration, start: $unusedStart, end: $unusedEnd, playhead: media.currentTime, markers: effectivePoints, onScrub: { media.seek($0) })
            }
        } sidebar: {
            SidebarSection(title: tr("Split", "Aufteilen")) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch mode {
                case .points:
                    Button(tr("Add split at playhead", "Schnitt bei Abspielposition hinzufügen")) {
                        let t = media.currentTime
                        if t > 0.1, t < media.duration - 0.1, !points.contains(where: { abs($0 - t) < 0.05 }) { points.append(t) }
                    }
                    ForEach(points.sorted(), id: \.self) { point in
                        HStack {
                            Text(TimeFormatter.clock(point)).font(.callout.monospacedDigit())
                            Spacer()
                            Button { media.seek(point) } label: { Image(systemName: "forward.frame") }
                            Button { points.removeAll { $0 == point } } label: { Image(systemName: "trash") }
                        }
                        .buttonStyle(.borderless)
                    }
                case .equal:
                    Stepper(tr("Parts: \(parts)", "Teile: \(parts)"), value: $parts, in: 2...50)
                    Text(tr("Each clip lasts about \(TimeFormatter.clock(media.duration / Double(parts))).", "Jeder Teil dauert etwa \(TimeFormatter.clock(media.duration / Double(parts))).")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: tr("Output", "Ergebnis")) {
                Text(tr("All clips are placed in one folder next to the original, numbered in order. Clips are copied without re-encoding when possible.", "Alle Teile landen nummeriert in einem Ordner neben dem Original. Wenn möglich, werden sie ohne Neuberechnung kopiert.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: media.duration) { _, new in unusedEnd = new }
    }

    private func save() {
        session.start(Self.jobs(session, points: effectivePoints, duration: media.duration))
    }

    static func jobs(_ session: ToolSession, points: [Double], duration: Double) -> [ToolJob] {
        let url = session.primary
        let folder = ConversionMatrix.uniqueDirectory(directory: session.outputDirectory, name: "\(session.baseName) \(tr("clips", "Teile"))")
        return [session.job(tr("Splitting", "Wird aufgeteilt")) { progress in
            try await StagingArea.writingFolder(folder) { folder in
                try await VideoOps.split(url, at: points, duration: duration, into: folder, progress: progress)
            }
        }]
    }
}

struct KeyCaptureView: NSViewRepresentable {
    enum Key { case left, right, space }
    let handler: (Key) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) { nsView.handler = handler }

    final class KeyView: NSView {
        var handler: ((Key) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true, !(self.window?.firstResponder is NSTextView) else { return event }
                switch event.keyCode {
                case 123: self.handler?(.left); return nil
                case 124: self.handler?(.right); return nil
                case 49: self.handler?(.space); return nil
                default: return event
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
