import AppKit
import CoreImage
import SwiftUI

enum ImageToolSupport {
    static func outputFormat(for source: URL) -> FileFormat {
        let format = FileFormat.detect(source) ?? .png
        switch format {
        case .svg, .bmp: return .png
        case .avif, .webp: return ImageIOBridge.canEncodeNatively(format) ? format : .png
        default: return format
        }
    }

    // The tools call these from the main thread. All heavy work (loading, rendering, encoding, writing the whole image)
    // happens in `renderAndWrite` / `renderEach`, which are not tied to the main thread, and the render closures are
    // @Sendable, so they don't run there either. A 100 MP PNG used to block the window for up to 1.8 s.

    static func job(_ session: ToolSession, suffix: String, format: FileFormat? = nil, title: String? = nil,
                    render: @escaping @Sendable () async throws -> CGImage) -> ToolJob {
        let output = format ?? outputFormat(for: session.primary)
        let destination = session.outputURL(suffix: suffix, ext: output.fileExtension)
        let quality = AppSettings.shared.jpegQuality
        let metadata = ImageIOBridge.properties(session.primary)
        return session.job(title) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await renderAndWrite(render: render, to: destination, format: output, quality: quality, metadata: metadata, progress: progress)
            }]
        }
    }

    static func renderAndWrite(render: @Sendable () async throws -> CGImage, to destination: URL, format output: FileFormat, quality: Double,
                               metadata: [CFString: Any], progress: (Double) -> Void) async throws {
        let image = try await render()
        try Task.checkCancellation()
        progress(0.7)
        if ImageIOBridge.canEncodeNatively(output) {
            var keep: [CFString: Any] = [:]
            if let exif = metadata[kCGImagePropertyExifDictionary] { keep[kCGImagePropertyExifDictionary] = exif }
            if let tiff = metadata[kCGImagePropertyTIFFDictionary] { keep[kCGImagePropertyTIFFDictionary] = tiff }
            try ImageIOBridge.write(image, to: destination, format: output, quality: quality, metadata: keep.isEmpty ? nil : keep)
        } else {
            try await ImageIOBridge.writeAnyFormat(image, to: destination, format: output, quality: quality)
        }
    }

    static func jobEach(_ session: ToolSession, suffix: String, title: String,
                        render: @escaping @Sendable (URL, CGImage) throws -> CGImage) -> ToolJob {
        let files = session.files
        let quality = AppSettings.shared.jpegQuality
        let destinations = files.map { url -> (URL, FileFormat) in
            let output = outputFormat(for: url)
            return (ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: suffix, ext: output.fileExtension), output)
        }
        return session.job(title, detail: tr("\(files.count) image\(files.count == 1 ? "" : "s")", "\(files.count) \(files.count == 1 ? "Bild" : "Bilder")")) { progress in
            try await renderEach(files: files, destinations: destinations, quality: quality, render: render, progress: progress)
        }
    }

    static func renderEach(files: [URL], destinations: [(URL, FileFormat)], quality: Double,
                           render: @Sendable (URL, CGImage) throws -> CGImage, progress: (Double) -> Void) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            let (destination, output) = destinations[index]
            let source = try ImageIOBridge.load(url)
            let result = try render(url, source)
            outputs.append(try await StagingArea.writing(destination) { destination in
                try await ImageIOBridge.writeAnyFormat(result, to: destination, format: output, quality: quality)
            })
            progress(Double(index + 1) / Double(files.count))
        }
        return outputs
    }

    /// `like`: the picture this one was made from, whose colour space (e.g. Display P3) it keeps.
    static func cgImage(_ ci: CIImage, like original: CGImage? = nil, context: CIContext = sharedContext) -> CGImage? {
        guard let original else { return context.createCGImage(ci, from: ci.extent) }
        return context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: ImageIOBridge.outputSpace(of: original))
    }

    static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
}

struct AspectPreset: Identifiable, Hashable {
    let title: String
    let ratio: CGFloat?
    var id: String { title }

    /// The title as the window shows it; `title` itself stays the key.
    var shownTitle: String {
        switch title {
        case "Free": return tr("Free", "Frei")
        case "Original": return tr("Original", "Original")
        case "Square": return tr("Square", "Quadratisch")
        default: return title
        }
    }

    static let all: [AspectPreset] = [
        AspectPreset(title: "Free", ratio: nil),
        AspectPreset(title: "Original", ratio: -1),
        AspectPreset(title: "Square", ratio: 1),
        AspectPreset(title: "4:3", ratio: 4 / 3),
        AspectPreset(title: "3:2", ratio: 3 / 2),
        AspectPreset(title: "16:9", ratio: 16 / 9),
        AspectPreset(title: "9:16", ratio: 9 / 16),
        AspectPreset(title: "3:4", ratio: 3 / 4),
        AspectPreset(title: "2:3", ratio: 2 / 3),
        AspectPreset(title: "5:4", ratio: 5 / 4),
    ]
}

/// A colour field: a click shows the usual colours to pick from, and "More colours …" for macOS's colour panel, which opens beside the tool's window
/// (it used to open at the lower left of the screen) and goes with that window (`ToolWindowManager.closeColorPanel`).
struct ColorSwatchPicker: View {
    let title: String
    @Binding var color: Color
    @State private var choosing = false

    /// Black, white, grey, red, orange, yellow, green, teal, blue, purple, pink, brown.
    static let common: [NSColor] = [(0, 0, 0), (1, 1, 1), (0.55, 0.55, 0.55), (0.9, 0.15, 0.15), (1, 0.55, 0), (1, 0.84, 0), (0.2, 0.7, 0.25), (0.1, 0.68, 0.72),
                                    (0.1, 0.4, 0.95), (0.55, 0.3, 0.85), (1, 0.4, 0.7), (0.55, 0.35, 0.2)].map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Button { choosing = true } label: {
                RoundedRectangle(cornerRadius: 6).fill(color)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.5)))
                    .frame(width: 44, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("Choose a color", "Farbe wählen"))
            .popover(isPresented: $choosing, arrowEdge: .bottom) { choices }
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 6), spacing: 6) {
                ForEach(Self.common, id: \.self) { swatch in
                    Button {
                        color = Color(nsColor: swatch)
                        choosing = false
                    } label: {
                        Circle().fill(Color(nsColor: swatch))
                            .overlay(Circle().stroke(Self.same(swatch, color.nsColor) ? Theme.accentForeground : Color.secondary.opacity(0.4), lineWidth: Self.same(swatch, color.nsColor) ? 2 : 1))
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(tr("More colors …", "Weitere Farben …")) {
                choosing = false
                let binding = $color
                ColorPanelLink.shared.open(color.nsColor, for: NSApp.keyWindow) { binding.wrappedValue = Color(nsColor: $0) }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
    }

    /// At black the colour panel's wheel is black all over and every click in it gives black again: the colours are behind a slider nobody looks for.
    /// So a dark colour opens on the panel's crayons, where a click gives that colour.
    nonisolated static func isDark(_ color: NSColor) -> Bool {
        (color.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.2
    }
}

/// macOS's colour panel, opened by a colour field: beside the window, its changes to that field, and closed with that window.
@MainActor
final class ColorPanelLink: NSObject {
    static let shared = ColorPanelLink()
    /// The window whose colour field opened the panel.
    private(set) weak var owner: NSWindow?
    private var set: ((NSColor) -> Void)?

    func open(_ color: NSColor, for window: NSWindow?, set: @escaping (NSColor) -> Void) {
        let panel = NSColorPanel.shared
        self.set = nil
        panel.showsAlpha = false
        if ColorSwatchPicker.isDark(color), panel.mode == .wheel { panel.mode = .crayon }
        panel.color = color
        self.set = set
        owner = window
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        if let window, let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(Self.place(panel.frame.size, beside: window.frame, on: screen))
        }
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        set?(panel.color)
    }

    /// Closed with the window that opened it, or when that window is gone.
    func close(leaving window: NSWindow) {
        guard NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible, owner == nil || owner === window else { return }
        NSColorPanel.shared.orderOut(nil)
        set = nil
        owner = nil
    }

    /// Right of the window, top edges level; on the left when there is no room on the right; always on the screen.
    nonisolated static func place(_ size: NSSize, beside window: NSRect, on screen: NSRect) -> NSPoint {
        let gap: CGFloat = 12
        var x = window.maxX + gap
        if x + size.width > screen.maxX { x = window.minX - gap - size.width }
        if x < screen.minX { x = screen.maxX - size.width }
        let y = min(max(window.maxY - size.height, screen.minY), screen.maxY - size.height)
        return NSPoint(x: max(x, screen.minX), y: y)
    }
}
