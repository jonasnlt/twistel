import AppKit
import SwiftUI

/// The introduction at the first start (and from the menu bar): a practice picture to drag with each ring's keys, Shift, then Command,
/// then Control. Each ring that opens for the practice picture is ticked off. It can be skipped and does not come back by itself.
@MainActor
final class IntroductionModel: ObservableObject {
    /// The rings opened for the practice picture so far.
    @Published private(set) var seen: Set<RingKind> = []
    let practiceFile: URL?

    init(practiceFile: URL?) {
        self.practiceFile = practiceFile
    }

    /// The ring to try next: in the concept's order, the first not yet opened.
    var next: RingKind? { RingKind.allCases.first { !seen.contains($0) } }
    var finished: Bool { next == nil }

    /// Called whenever a ring opens; only rings for the practice picture count.
    func ringOpened(_ ring: RingKind, files: [URL]) {
        guard let practiceFile, files.map(\.standardizedFileURL).contains(practiceFile.standardizedFileURL) else { return }
        seen.insert(ring)
    }

    /// A picture to practise with, in the app's own temporary folder (never in the person's folders). Its results land next to it.
    static func makePracticeFile(in folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppIdentity.name)-Practice", isDirectory: true)) -> URL? {
        let name = tr("Practice picture", "Übungsbild") + ".png"
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try ImageIOBridge.write(practiceImage(), to: file, format: .png)
            }
            return file
        } catch {
            DiagnosticLog.log("introduction: no practice file: \(error)")
            return nil
        }
    }

    /// A calm picture with a few shapes and one word, so conversions and tools have something to show.
    static func practiceImage() -> CGImage {
        let width = 1200, height = 800
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.55, green: 0.72, blue: 0.95, alpha: 1), CGColor(srgbRed: 0.98, green: 0.86, blue: 0.68, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: 120, y: 160, width: 380, height: 380))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.35, blue: 0.6, alpha: 0.8))
        context.fill(CGRect(x: 620, y: 220, width: 420, height: 260))
        let text = NSAttributedString(string: tr("Practice", "Übung"), attributes: [.font: NSFont.systemFont(ofSize: 96, weight: .bold),
                                                                                    .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: 650, y: 310)
        CTLineDraw(line, context)
        return context.makeImage()!
    }
}

struct IntroductionView: View {
    @ObservedObject var model: IntroductionModel
    @EnvironmentObject private var settings: AppSettings
    var close: () -> Void
    /// Without a mouse: the next ring opens for the practice picture and takes the keyboard.
    var openRing: (RingKind) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Three rings for your files", "Drei Ringe für deine Dateien"))
                    .font(.title2.weight(.semibold))
                Text(tr("Drag a file and hold a key: a ring appears around the pointer. Let go on what you want. Try it with the practice picture.",
                        "Ziehe eine Datei und halte dabei eine Taste: Um den Zeiger erscheint ein Ring. Lass auf dem Gewünschten los. Probier es mit dem Übungsbild."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 20) {
                practicePicture
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(RingKind.allCases) { ring in step(ring) }
                }
            }
            Text(tr("Hold Option as well when you let go on a tool: it runs with its last settings, without a window. Without dragging: \u{201C}Choose Files …\u{201D} in the menu bar, or right-click the file, at the very bottom of the menu (with many services installed, in the Services or Quick Actions submenu).",
                    "Hältst du beim Loslassen auf einem Werkzeug zusätzlich Wahl (⌥), läuft es mit den letzten Einstellungen, ohne Fenster. Ohne Ziehen: \u{201E}Dateien wählen …\u{201C} in der Menüleiste, oder Rechtsklick auf die Datei, ganz unten im Menü (wenn viele Dienste installiert sind, im Untermenü \u{201E}Dienste\u{201C} bzw. \u{201E}Schnellaktionen\u{201C})."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let next = model.next {
                    Button(tr("Open \(next.title) Ring with the Keyboard", "Ring \(next.title) mit der Tastatur öffnen")) { openRing(next) }
                        .help(tr("Without dragging: arrows choose, Return runs, Tab switches the ring, Esc closes.",
                                 "Ohne Ziehen: Pfeile wählen, Return startet, Tab wechselt den Ring, Esc schließt."))
                }
                Spacer()
                if model.finished {
                    Button(tr("Done", "Fertig"), action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(tr("Skip", "Überspringen"), action: close)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    @ViewBuilder private var practicePicture: some View {
        if let file = model.practiceFile {
            VStack(spacing: 6) {
                Image(nsImage: NSImage(contentsOf: file) ?? NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 150, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                Text(file.lastPathComponent).font(.caption).lineLimit(1)
                Text(tr("Drag me", "Zieh mich")).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(contentsOf: file) ?? NSItemProvider() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tr("Practice picture, drag it with a ring's key held", "Übungsbild, mit gehaltener Taste eines Rings ziehen"))
        }
    }

    private func step(_ ring: RingKind) -> some View {
        let done = model.seen.contains(ring)
        let current = model.next == ring
        let keys = settings.ringKeys.combo(for: ring)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : (current ? "circle.dotted" : "circle"))
                .font(.system(size: 18))
                .foregroundStyle(done ? Theme.accentForeground : (current ? Color.primary : Color.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(keys.symbols)  \(ring.title)").font(.headline)
                Text(Self.explanation(ring, keys: keys)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? tr("done", "erledigt") : "")
    }

    static func explanation(_ ring: RingKind, keys: ModifierCombo) -> String {
        keepingNamesWhole(sentence(ring, keys: keys))
    }

    /// Product names are never hyphenated ("Air-Drop" at a line end): a word joiner between their letters forbids a break.
    static func keepingNamesWhole(_ text: String) -> String {
        ["AirDrop", "Finder"].reduce(text) { text, name in
            text.replacingOccurrences(of: name, with: name.map(String.init).joined(separator: "\u{2060}"))
        }
    }

    private static func sentence(_ ring: RingKind, keys: ModifierCombo) -> String {
        switch ring {
        case .convert: return tr("Drag with \(keys.names) held: into another format, e.g. JPG or PDF.",
                                 "Mit gehaltener \(keys.names)-Taste ziehen: in ein anderes Format, z. B. JPG oder PDF.")
        case .tools: return tr("Drag with \(keys.names) held: compress, crop, sign, recognize text …",
                               "Mit gehaltener \(keys.names)-Taste ziehen: verkleinern, zuschneiden, unterschreiben, Text erkennen …")
        case .actions: return tr("Drag with \(keys.names) held: show in Finder, copy the path, AirDrop, checksum …",
                                 "Mit gehaltener \(keys.names)-Taste ziehen: im Finder zeigen, Pfad kopieren, AirDrop, Prüfsumme …")
        }
    }
}

/// The window of the introduction. One at a time; closing it (Skip or Done) marks it as seen.
@MainActor
final class IntroductionWindow: NSObject, NSWindowDelegate {
    static let shared = IntroductionWindow()
    private(set) var window: NSWindow?
    private(set) var model: IntroductionModel?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = IntroductionModel(practiceFile: IntroductionModel.makePracticeFile())
        self.model = model
        let window = Self.makeWindow(model: model, close: { [weak self] in self?.window?.close() }, openRing: { [weak self] ring in
            if let file = model.practiceFile { self?.openRing?([file], ring) }
        })
        window.delegate = self
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static var title: String { tr("Welcome to \(AppIdentity.name)", "Willkommen bei \(AppIdentity.name)") }

    static func makeWindow(model: IntroductionModel, close: @escaping () -> Void, openRing: @escaping (RingKind) -> Void) -> NSWindow {
        let view = IntroductionView(model: model, close: close, openRing: openRing).environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: view)
        // Measured once: letting the window follow the view's size made AppKit and SwiftUI resize each other until the app was stopped
        // ("more Update Constraints in Window passes than there are views", seen from the menu bar).
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: CGSize(width: 600, height: 2_000))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(size)
        window.title = Self.title
        followLanguage(window) { [weak window] in window?.title = IntroductionWindow.title }
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// The first start shows it once; after that only the menu bar does.
    static func showAtFirstLaunch(settings: AppSettings = .shared, show: (() -> Void)? = nil) {
        guard !settings.introductionShown else { return }
        settings.introductionShown = true
        if let show { show() } else { shared.show() }
    }

    func ringOpened(_ ring: RingKind, files: [URL]) {
        model?.ringOpened(ring, files: files)
    }

    /// Opens a ring for files without a drag (set by the app delegate); the introduction offers it for the keyboard.
    var openRing: (([URL], RingKind) -> Void)?

    func windowWillClose(_ notification: Notification) {
        window = nil
        model = nil
    }
}
