import AppKit
import SwiftUI

struct ToolSession: Identifiable {
    let id = UUID()
    let tool: ToolID
    let files: [URL]
    /// How the window starts, when not with its defaults (the test access draws windows in a given state), e.g. "preset".
    var start: [String: String] = [:]

    var formats: [FileFormat] { files.compactMap(FileFormat.detect) }
    var primary: URL { files[0] }
    var primaryFormat: FileFormat { FileFormat.detect(primary) ?? .png }
    var baseName: String { ConversionMatrix.strippedBaseName(primary.lastPathComponent) }
    var outputDirectory: URL { AppSettings.shared.outputLocation.directory(for: primary) }

    func outputURL(suffix: String, ext: String, baseName: String? = nil) -> URL {
        ConversionMatrix.uniqueURL(directory: outputDirectory, baseName: baseName ?? self.baseName, suffix: suffix, ext: ext)
    }
}

@MainActor
final class ToolWindowManager: NSObject, NSWindowDelegate {
    static let shared = ToolWindowManager()

    private var windows: [UUID: NSWindow] = [:]

    var openWindows: [NSWindow] { Array(windows.values) }

    func closeAll() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    func open(_ tool: ToolID, files: [URL]) {
        guard !files.isEmpty else { return }
        let session = ToolSession(tool: tool, files: files)
        let root = ToolRootView(session: session)
            .environmentObject(AppSettings.shared)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        Self.setTitles(window, tool: tool, files: files)
        followLanguage(window) { [weak window] in if let window { ToolWindowManager.setTitles(window, tool: tool, files: files) } }
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.setContentSize(Self.preferredSize(for: tool))
        window.minSize = Self.minimumSize(for: tool)
        window.center()
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(session.id.uuidString)
        windows[session.id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The tool's name and what it works on, in the app's language now (again when the language changes).
    static func setTitles(_ window: NSWindow, tool: ToolID, files: [URL]) {
        window.title = tool.title
        window.subtitle = files.count == 1 ? files[0].lastPathComponent : tr("\(files.count) files", "\(files.count) Dateien")
    }

    func close(_ session: ToolSession) {
        windows[session.id]?.close()
        windows.removeValue(forKey: session.id)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue, let uuid = UUID(uuidString: id) else { return }
        windows.removeValue(forKey: uuid)
        Self.closeColorPanel(leaving: window, others: Array(windows.values))
    }

    /// The colour panel is shared by every colour field of the app and stayed open after its tool was closed. It goes with the window
    /// whose colour field opened it (`ColorPanelLink`); a colour field of another tool window keeps it.
    static func closeColorPanel(leaving window: NSWindow, others: [NSWindow]) {
        ColorPanelLink.shared.close(leaving: window)
    }

    enum WindowClass {
        case compact, standard, editor

        var sidebarWidth: CGFloat {
            switch self {
            case .compact: return 260
            case .standard: return 290
            case .editor: return 320
            }
        }
    }

    static func windowClass(for tool: ToolID) -> WindowClass {
        switch tool {
        case .compress, .resizeImage, .createPDF, .mergePDF, .splitPDF, .audioChannels, .rotateImage, .transcribe, .extractImages, .recognizeText, .readQR, .pdfPassword,
             .watermarkPDF, .pageNumbersPDF, .socialMedia, .removeAudio:
            return .compact
        case .editMetadata, .normalizeAudio, .organizePDF, .createCollage, .joinVideos, .audioToVideo, .trimAudio, .redactAudio:
            return .standard
        default:
            return .editor
        }
    }

    static func preferredSize(for tool: ToolID) -> NSSize {
        switch tool {
        case .compress:
            return NSSize(width: 640, height: 560)
        case .transcribe, .extractImages, .recognizeText, .readQR, .pdfPassword, .pdfArchive, .removeAudio:
            return NSSize(width: 640, height: 440)
        case .watermarkPDF, .pageNumbersPDF:
            return NSSize(width: 680, height: 560)
        case .socialMedia, .removeBackground:
            return NSSize(width: 760, height: 600)
        case .videoPresets:
            return NSSize(width: 760, height: 640)
        case .burnSubtitles:
            return NSSize(width: 860, height: 640)
        case .redactPDF:
            return NSSize(width: 1000, height: 760)
        case .resizeImage:
            return NSSize(width: 620, height: 400)
        case .createPDF, .mergePDF:
            return NSSize(width: 680, height: 440)
        case .splitPDF, .audioChannels:
            return NSSize(width: 720, height: 460)
        case .rotateImage:
            return NSSize(width: 760, height: 500)
        case .editMetadata, .normalizeAudio, .trimAudio, .redactAudio, .audioToVideo:
            return NSSize(width: 820, height: 560)
        case .organizePDF, .createCollage, .joinVideos:
            return NSSize(width: 940, height: 620)
        default:
            return NSSize(width: 1040, height: 700)
        }
    }

    static func minimumSize(for tool: ToolID) -> NSSize {
        switch windowClass(for: tool) {
        case .compact: return NSSize(width: 560, height: 360)
        case .standard: return NSSize(width: 640, height: 440)
        case .editor: return NSSize(width: 760, height: 520)
        }
    }
}

struct ToolRootView: View {
    let session: ToolSession

    var body: some View {
        Group {
            switch session.tool {
            case .compress: CompressToolView(session: session)
            case .editMetadata: MetadataToolView(session: session)
            case .recognizeText: RecognizeTextToolView(session: session)
            case .readQR: ReadQRToolView(session: session)
            case .editImage: EditImageToolView(session: session)
            case .frameImage: FrameImageToolView(session: session)
            case .cropImage: CropImageToolView(session: session)
            case .redactImage: RedactImageToolView(session: session)
            case .resizeImage: ResizeImageToolView(session: session)
            case .rotateImage: RotateImageToolView(session: session)
            case .createPDF: CreatePDFToolView(session: session)
            case .createCollage: CollageToolView(session: session)
            case .trimVideo: TrimVideoToolView(session: session)
            case .cropVideo: CropVideoToolView(session: session)
            case .changeVideoSpeed: VideoSpeedToolView(session: session)
            case .joinVideos: JoinVideosToolView(session: session)
            case .videoSnapshots: VideoSnapshotsToolView(session: session)
            case .splitVideo: SplitVideoToolView(session: session)
            case .redactVideo: RedactVideoToolView(session: session)
            case .normalizeAudio: NormalizeAudioToolView(session: session)
            case .audioToVideo: AudioToVideoToolView(session: session)
            case .trimAudio: TrimAudioToolView(session: session)
            case .audioChannels: AudioChannelsToolView(session: session)
            case .redactAudio: RedactAudioToolView(session: session)
            case .transcribe: TranscribeToolView(session: session)
            case .mergePDF: MergePDFToolView(session: session)
            case .organizePDF: OrganizePDFToolView(session: session)
            case .splitPDF: SplitPDFToolView(session: session)
            case .extractImages: ExtractImagesToolView(session: session)
            case .pdfPassword: PDFPasswordToolView(session: session)
            case .watermarkPDF: WatermarkPDFToolView(session: session)
            case .pageNumbersPDF: PageNumbersPDFToolView(session: session)
            case .socialMedia: SocialMediaToolView(session: session)
            case .removeBackground: RemoveBackgroundToolView(session: session)
            case .videoPresets: VideoPresetsToolView(session: session)
            case .pdfArchive: PDFArchiveToolView(session: session)
            case .redactPDF: RedactPDFToolView(session: session)
            case .annotate: AnnotateToolView(session: session)
            case .signPDF: SignPDFToolView(session: session)
            case .comparePDF: ComparePDFToolView(session: session)
            case .burnSubtitles: BurnSubtitlesToolView(session: session)
            case .removeAudio: RemoveAudioToolView(session: session)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

struct WindowChrome<Content: View>: View {
    let session: ToolSession
    var saveTitle: String
    var saveEnabled: Bool
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content

    private var fileLabel: String {
        session.files.count == 1 ? session.primary.lastPathComponent : tr("\(session.files.count) files", "\(session.files.count) Dateien")
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 12) {
                Label {
                    Text(fileLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: session.tool.symbol)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button(tr("Cancel", "Abbrechen")) { ToolWindowManager.shared.close(session) }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!saveEnabled)
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
        }
        // No .tint: system controls take the Mac's accent colour, and twistel's emerald only with "Multicolour" (HIG, `AccentColor`).
    }
}

struct ToolShell<Content: View, Sidebar: View>: View {
    let session: ToolSession
    var saveTitle = tr("Save copy", "Kopie sichern")
    var saveEnabled = true
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var sidebar: () -> Sidebar

    private var windowClass: ToolWindowManager.WindowClass { ToolWindowManager.windowClass(for: session.tool) }

    var body: some View {
        let compact = windowClass == .compact
        WindowChrome(session: session, saveTitle: saveTitle, saveEnabled: saveEnabled, onSave: onSave) {
            HStack(spacing: compact ? 12 : 16) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                    .card()
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 10 : 12) {
                        sidebar()
                    }
                }
                .scrollIndicators(.automatic)
                .frame(width: windowClass.sidebarWidth)
            }
            .padding(compact ? 14 : 20)
        }
    }
}

struct FormShell<Content: View>: View {
    let session: ToolSession
    var saveTitle = tr("Save copy", "Kopie sichern")
    var saveEnabled = true
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        WindowChrome(session: session, saveTitle: saveTitle, saveEnabled: saveEnabled, onSave: onSave) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.body)
            content()
            Spacer(minLength: 0)
        }
    }
}


struct FormHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Int
    var suffix = ""
    /// What the tool can do; a number typed beyond it becomes its nearest end.
    var range: ClosedRange<Int>? = nil

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("", value: Binding(get: { value }, set: { typed in value = range.map { min(max(typed, $0.lowerBound), $0.upperBound) } ?? typed }), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary).font(.callout) }
        }
    }
}

struct TimecodeField: View {
    let title: String
    @Binding var seconds: Double
    var maximum: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            TextField("0:00.00", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 96)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = TimeFormatter.clock(seconds) }
        .onChange(of: seconds) { _, newValue in if !focused { text = TimeFormatter.clock(newValue) } }
    }

    private func commit() {
        if let parsed = TimeFormatter.parseClock(text) {
            seconds = min(max(0, parsed), maximum)
        }
        text = TimeFormatter.clock(seconds)
    }
}
