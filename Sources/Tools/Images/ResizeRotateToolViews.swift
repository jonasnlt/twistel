import AppKit
import SwiftUI

@MainActor
struct ResizeImageToolView: View {
    let session: ToolSession
    @State private var mode = ToolMemory.value(.resizeImage, "mode", default: Mode.longEdge)
    @State private var longEdge = ToolMemory.value(.resizeImage, "longEdge", default: 1920)
    @State private var percent = ToolMemory.value(.resizeImage, "percent", default: 50)
    @State private var width = ToolMemory.value(.resizeImage, "width", default: 0)
    @State private var height = ToolMemory.value(.resizeImage, "height", default: 0)
    @State private var lockAspect = ToolMemory.value(.resizeImage, "lockAspect", default: true)
    @State private var sizes: [URL: CGSize] = [:]

    enum Mode: String, CaseIterable, Identifiable {
        case longEdge, percent, exact
        var id: String { rawValue }
        var title: String {
            switch self {
            case .longEdge: return tr("Long edge", "Lange Seite")
            case .percent: return tr("Percent", "Prozent")
            case .exact: return tr("Exact", "Genau")
            }
        }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? tr("Resize", "Größe ändern") : tr("Resize \(session.files.count) images", "Größe von \(session.files.count) Bildern ändern"), onSave: save) {
            List(session.files, id: \.self) { url in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).lineLimit(1)
                        if let size = sizes[url] {
                            let target = targetSize(for: size)
                            Text("\(Int(size.width)) × \(Int(size.height))  →  \(Int(target.width)) × \(Int(target.height))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
        } sidebar: {
            SidebarSection(title: tr("Resize by", "Größe ändern nach")) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                switch mode {
                case .longEdge:
                    NumberField(title: tr("Long edge", "Lange Seite"), value: $longEdge, suffix: "px", range: 1...20_000)
                    HStack {
                        ForEach([640, 1080, 1920, 2560, 4096], id: \.self) { value in
                            Button("\(value)") { longEdge = value }.controlSize(.mini)
                        }
                    }
                case .percent:
                    NumberField(title: tr("Scale", "Skalierung"), value: $percent, suffix: "%", range: 1...400)
                case .exact:
                    NumberField(title: tr("Width", "Breite"), value: $width, suffix: "px", range: 0...20_000)
                    NumberField(title: tr("Height", "Höhe"), value: $height, suffix: "px", range: 0...20_000)
                    Toggle(tr("Keep aspect ratio (fit inside)", "Seitenverhältnis beibehalten (einpassen)"), isOn: $lockAspect)
                }
            }
            SidebarSection(title: tr("Notes", "Hinweise")) {
                Text(tr("Images are never enlarged beyond the requested size with the long-edge mode. Output keeps the original format where it can be written natively.", "Mit „Lange Seite“ werden Bilder nie über die gewünschte Größe hinaus vergrößert. Das Ergebnis behält das Format des Originals, wenn der Mac es selbst schreiben kann."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            for url in session.files { sizes[url] = ImageIOBridge.pixelSize(url) }
            if let first = sizes[session.primary] { width = Int(first.width); height = Int(first.height) }
        }
    }

    private func targetSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        switch mode {
        case .longEdge:
            let scale = min(1, CGFloat(max(1, longEdge)) / max(size.width, size.height))
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        case .percent:
            let scale = CGFloat(max(1, percent)) / 100
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        case .exact:
            let w = CGFloat(max(1, width)), h = CGFloat(max(1, height))
            if lockAspect {
                let scale = min(w / size.width, h / size.height)
                return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            }
            return CGSize(width: w, height: h)
        }
    }

    private func save() {
        ToolMemory.remember(.resizeImage, ["mode": mode.rawValue, "longEdge": "\(longEdge)", "percent": "\(percent)", "width": "\(width)",
                                           "height": "\(height)", "lockAspect": "\(lockAspect)"])
        session.start(Self.jobs(session, Options(mode: mode, longEdge: longEdge, percent: percent, width: width, height: height, lockAspect: lockAspect)))
    }

    struct Options {
        var mode: Mode
        var longEdge: Int
        var percent: Int
        var width: Int
        var height: Int
        var lockAspect: Bool
    }

    static func jobs(_ session: ToolSession, _ options: Options) -> [ToolJob] {
        let mode = options.mode, longEdge = options.longEdge, percent = options.percent
        let width = options.width, height = options.height, lockAspect = options.lockAspect
        return [ImageToolSupport.jobEach(session, suffix: tr("resized", "skaliert"), title: tr("Resizing", "Größe wird geändert")) { _, image in
            let size = CGSize(width: image.width, height: image.height)
            let target: CGSize
            switch mode {
            case .longEdge:
                let scale = min(1, CGFloat(max(1, longEdge)) / max(size.width, size.height))
                target = CGSize(width: size.width * scale, height: size.height * scale)
            case .percent:
                let scale = CGFloat(max(1, percent)) / 100
                target = CGSize(width: size.width * scale, height: size.height * scale)
            case .exact:
                let w = CGFloat(max(1, width)), h = CGFloat(max(1, height))
                if lockAspect {
                    let scale = min(w / size.width, h / size.height)
                    target = CGSize(width: size.width * scale, height: size.height * scale)
                } else {
                    target = CGSize(width: w, height: h)
                }
            }
            return ImageIOBridge.scaled(image, to: CGSize(width: max(1, target.width.rounded()), height: max(1, target.height.rounded())))
        }]
    }
}

@MainActor
struct RotateImageToolView: View {
    let session: ToolSession
    @StateObject private var document: ImageDocument
    @State private var quarterTurns = 0
    @State private var flipH = false
    @State private var flipV = false

    init(session: ToolSession) {
        self.session = session
        _document = StateObject(wrappedValue: ImageDocument(url: session.primary, previewMaxPixels: 1600))
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? tr("Save copy", "Kopie sichern") : tr("Apply to \(session.files.count) images", "Auf \(session.files.count) Bilder anwenden"), saveEnabled: document.preview != nil, onSave: save) {
            ZStack {
                CheckerboardBackground()
                if let preview = document.preview {
                    Image(nsImage: preview)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(quarterTurns) * 90))
                        .scaleEffect(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
                        .padding(40)
                        .animation(.easeInOut(duration: 0.18), value: quarterTurns)
                } else {
                    LoadingOrError(error: document.error)
                }
            }
        } sidebar: {
            SidebarSection(title: tr("Rotate", "Drehen")) {
                HStack {
                    Button { quarterTurns = (quarterTurns + 3) % 4 } label: { Label(tr("Left", "Links"), systemImage: "rotate.left") }
                    Button { quarterTurns = (quarterTurns + 1) % 4 } label: { Label(tr("Right", "Rechts"), systemImage: "rotate.right") }
                }
                Text("\(quarterTurns * 90)°").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Flip", "Spiegeln")) {
                Toggle(tr("Flip horizontally", "Horizontal spiegeln"), isOn: $flipH)
                Toggle(tr("Flip vertically", "Vertikal spiegeln"), isOn: $flipV)
            }
            if session.files.count > 1 {
                SidebarSection(title: tr("Batch", "Mehrere Bilder")) {
                    Text(tr("The same rotation and flips are applied to all \(session.files.count) images.", "Alle \(session.files.count) Bilder werden gleich gedreht und gespiegelt.")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func save() {
        ToolMemory.remember(.rotateImage, ["turns": "\(quarterTurns)", "flipH": "\(flipH)", "flipV": "\(flipV)"])
        session.start(Self.jobs(session, quarterTurns: quarterTurns, flipH: flipH, flipV: flipV))
    }

    static func jobs(_ session: ToolSession, quarterTurns: Int, flipH: Bool, flipV: Bool) -> [ToolJob] {
        [ImageToolSupport.jobEach(session, suffix: tr("rotated", "gedreht"), title: tr("Rotating", "Wird gedreht")) { _, image in
            ImageOps.rotated(image, quarterTurns: quarterTurns, flipHorizontal: flipH, flipVertical: flipV)
        }]
    }
}
