import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The actions ring's "Float": the files wait in a small window that floats above everything, on every desktop, until it is closed.
/// Dragging them out copies, never moves: the original stays where it is, unchanged. A click on the stack lays the files out one by one,
/// to drag or remove each on its own. Files dropped on the window join it. Nothing is kept after the app quits.
@MainActor
enum FloatShelf {
    private(set) static var panels: [FloatPanel] = []

    /// `visible: false` is for the test access: the real window, but see-through and without fading in.
    @discardableResult
    static func show(_ files: [URL], at point: NSPoint, visible: Bool = true) -> FloatPanel {
        let panel = FloatPanel(files: files)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = placement(for: point, size: FloatShelfView.collapsedSize, in: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
        // A second window at the same place steps aside, so both can be seen.
        while panels.contains(where: { $0.frame.origin == origin }) { origin = NSPoint(x: origin.x + 24, y: origin.y - 24) }
        panel.setFrameOrigin(origin)
        panels.append(panel)
        if visible {
            panel.appear()
        } else {
            // See-through for the test access, and never in the way of a click.
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        }
        DiagnosticLog.log("float \(files.count) file(s)")
        return panel
    }

    /// Centred on the point where the files were dropped, but whole on the screen.
    nonisolated static func placement(for point: NSPoint, size: CGSize, in visible: NSRect, margin: CGFloat = 8) -> NSPoint {
        let x = min(max(point.x - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
        let y = min(max(point.y - size.height / 2, visible.minY + margin), visible.maxY - size.height - margin)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// The window at its new size: the top edge stays where it is, unless the window would leave the screen.
    nonisolated static func resized(_ frame: NSRect, to size: CGSize, in visible: NSRect, margin: CGFloat = 8) -> NSRect {
        var new = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        new.origin.x = min(max(new.minX, visible.minX + margin), visible.maxX - size.width - margin)
        new.origin.y = min(max(new.minY, visible.minY + margin), visible.maxY - size.height - margin)
        return new.integral
    }

    fileprivate static func closed(_ panel: FloatPanel) {
        panels.removeAll { $0 === panel }
    }
}

/// What may happen to a file dragged out of the window: only a copy. Finder copies even on the same disk, the Trash in the Dock
/// refuses, and keys held while dropping change nothing.
enum FloatDrag {
    static let allowed: NSDragOperation = .copy
    /// What a drop on the window answers: the files are only looked at, so the app they come from has nothing to delete or move.
    static let accepted: NSDragOperation = .copy
    /// Posted when a drag from the window is about to start, so the ring watcher (`DragMonitor`) knows before the drag begins and
    /// opens a ring for the keys held, as for a drag from Finder.
    static let willBegin = Notification.Name("FloatDragWillBegin")

    /// The files themselves (their URLs), each with its picture.
    @MainActor
    static func items(for files: [URL], thumbnails: [URL: NSImage], in frame: CGRect) -> [NSDraggingItem] {
        // AppKit refuses a drag picture without size.
        let frame = frame.width < 1 || frame.height < 1 ? CGRect(origin: frame.origin, size: CGSize(width: 64, height: 64)) : frame
        return files.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
            let shift = CGFloat(min(index, 3)) * 4
            item.setDraggingFrame(frame.offsetBy(dx: shift, dy: shift), contents: image)
            return item
        }
    }
}

/// The pinned files. Each is remembered with a bookmark too, so a file renamed or moved meanwhile is still found.
@MainActor
final class FloatShelfModel: ObservableObject {
    struct Pinned: Equatable {
        var url: URL
        let bookmark: Data?
    }

    @Published private(set) var pinned: [Pinned] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    /// The files laid out one by one (after a click on the stack).
    @Published private(set) var expanded = false
    @Published var hovering = false
    /// The file under the pointer in the opened stack: its x shows.
    @Published var hoveredFile: URL?
    @Published var dropTargeted = false
    /// The file chosen with the arrow keys in the opened stack (nil: all of them).
    @Published var selection: URL?
    /// The window has the keyboard (after a click into it, never by itself).
    @Published var focused = false
    /// The window follows: a new size, or closing when the last file was removed.
    var onChange: ((_ animated: Bool) -> Void)?
    var onEmpty: (() -> Void)?
    /// Thumbnails are made in the background; drawing for the test access waits for them.
    private(set) var loading = 0

    init(files: [URL]) {
        add(files)
    }

    var files: [URL] { pinned.map(\.url) }

    /// New files at the end; one that is already here is not added twice. Returns how many joined.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls.map(\.standardizedFileURL) where !pinned.contains(where: { $0.url.path == url.path }) {
            pinned.append(Pinned(url: url, bookmark: try? url.bookmarkData()))
            added += 1
        }
        loadThumbnails()
        if added > 0 { onChange?(true) }
        return added
    }

    /// Takes a file out of the window only; the file itself stays untouched. The last one closes the window; with one left there is
    /// nothing to lay out, so the window shows it as one picture again.
    func remove(_ url: URL) {
        withMotion {
            pinned.removeAll { $0.url == url }
            if pinned.count == 1 { expanded = false }
            if selection == url || !expanded { selection = nil }
        }
        if pinned.isEmpty { onEmpty?() } else { onChange?(true) }
    }

    /// One file is just its picture and name: laying it out would show the same name twice.
    var canExpand: Bool { pinned.count > 1 }

    func setExpanded(_ value: Bool) {
        guard value != expanded, !value || canExpand else { return }
        withMotion {
            expanded = value
            if !value { selection = nil }
        }
        onChange?(true)
    }

    /// The arrow keys: the stack opens at the first (or, going back, the last) file, then the selection moves one file at a time and
    /// stops at either end, as in Finder's lists. With one file there is nothing to choose.
    func moveSelection(_ delta: Int) {
        guard canExpand else { return }
        if !expanded { setExpanded(true) }
        let index = selection.flatMap { files.firstIndex(of: $0) }
        let next = index.map { min(max($0 + delta, 0), files.count - 1) } ?? (delta > 0 ? 0 : files.count - 1)
        selection = files[next]
    }

    /// What ⌘C, Quick Look and the like act on: the chosen file, or all of them.
    func chosenFiles() -> [URL] {
        if expanded, let selection { return current(selection).map { [$0] } ?? [] }
        return currentFiles()
    }

    /// Soft movement, or only a cross-fade with "Reduce motion".
    private func withMotion(_ change: () -> Void) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.28), change)
    }

    /// The files where they are now. Files that are gone are left out (and stay out).
    func currentFiles() -> [URL] {
        pinned = pinned.compactMap { item in
            var item = item
            if !FileManager.default.fileExists(atPath: item.url.path), let bookmark = item.bookmark {
                var stale = false
                if let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    if let image = thumbnails[item.url] { thumbnails[found.standardizedFileURL] = image }
                    item.url = found.standardizedFileURL
                }
            }
            return FileManager.default.fileExists(atPath: item.url.path) ? item : nil
        }
        return files
    }

    /// One file where it is now, or nil when it is gone.
    func current(_ url: URL) -> URL? {
        guard let index = pinned.firstIndex(where: { $0.url == url }) else { return nil }
        let bookmark = pinned[index].bookmark
        _ = currentFiles()
        if let found = pinned.first(where: { $0.bookmark == bookmark && bookmark != nil }) { return found.url }
        return pinned.first { $0.url == url }?.url
    }

    var title: String {
        files.count == 1 ? files[0].lastPathComponent : tr("\(files.count) files", "\(files.count) Dateien")
    }

    var accessibilityLabel: String {
        files.count == 1 ? tr("\(files[0].lastPathComponent), floating", "\(files[0].lastPathComponent), angeheftet")
            : tr("\(files.count) files floating: \(files.map(\.lastPathComponent).joined(separator: ", "))",
                 "\(files.count) Dateien angeheftet: \(files.map(\.lastPathComponent).joined(separator: ", "))")
    }

    /// The pictures of the stack: at most three, the first file on top.
    var stack: [URL] { Array(files.prefix(3)) }

    func waitForThumbnails() async {
        while loading > 0 { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func loadThumbnails() {
        for url in files.prefix(60) where thumbnails[url] == nil {
            thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
            loading += 1
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 112, height: 112), scale: 2, representationTypes: .thumbnail)
            let isPicture = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                // A page with almost nothing on it (a CSV's tiny table, an empty page) says less than the file's icon, which stays.
                // Pictures keep theirs, even a white one.
                let blank = !isPicture && (representation?.cgImage).map(ThumbnailCheck.isNearlyBlank) == true
                let image = blank ? nil : representation?.nsImage
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let image { self.thumbnails[url] = image }
                    self.loading -= 1
                }
            }
        }
    }
}

/// Whether a preview shows anything worth seeing.
enum ThumbnailCheck {
    /// Less than this part of the picture differs clearly from its background: nearly blank. Measured with Quick Look's previews
    /// of the test files: the CSV 0.2 %, the sparsest real page (Markdown) 2.9 %, PDF 8 %, Word 23 %, the note on an audio file 9 %.
    static let least = 0.01

    static func isNearlyBlank(_ image: CGImage) -> Bool {
        inkShare(image) < least
    }

    /// The part of the opaque pixels whose brightness is more than 0.1 away from the most common brightness (the background).
    static func inkShare(_ image: CGImage) -> Double {
        let width = min(image.width, 256), height = min(image.height, 256)
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 1 }
        var levels = [UInt8](), counts = [Int](repeating: 0, count: 64)
        levels.reserveCapacity(width * height)
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 200 {
            let light = (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])).rounded()
            let level = UInt8(min(255, light))
            levels.append(level)
            counts[Int(level) / 4] += 1
        }
        guard !levels.isEmpty, let most = counts.indices.max(by: { counts[$0] < counts[$1] }) else { return 0 }
        let background = (Double(most) + 0.5) * 4
        let ink = levels.filter { abs(Double($0) - background) > 25.5 }.count
        return Double(ink) / Double(levels.count)
    }
}

/// The window's content: the stack, or the files one by one. Dragging and clicking files goes through `FileDragSource` (AppKit, so a
/// drag can only ever copy); the empty surface moves the window.
struct FloatShelfView: View {
    @ObservedObject var model: FloatShelfModel
    let close: () -> Void
    /// Glass, or a solid surface ("Reduce transparency", "Increase contrast"); the test access draws the solid one, because glass can't
    /// be drawn into a picture. Nil: as the Mac is set.
    var style: RingStyle?

    static let collapsedSize = CGSize(width: 168, height: 184)
    static let expandedWidth: CGFloat = 280
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 52
    /// More files than this scroll.
    static let visibleRows = 6
    static let cornerRadius: CGFloat = 18
    static let buttonSide: CGFloat = 22

    static func size(expanded: Bool, count: Int) -> CGSize {
        guard expanded else { return collapsedSize }
        return CGSize(width: expandedWidth, height: headerHeight + CGFloat(min(max(count, 1), visibleRows)) * rowHeight + 10)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WindowDragArea(hover: { model.hovering = $0 }, click: { if model.expanded { model.setExpanded(false) } })
            if model.expanded {
                expandedList.transition(.opacity)
            } else {
                collapsedStack.transition(.opacity)
            }
            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(HUDSurface(style: style ?? RingStyle.current))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Theme.accentForeground, lineWidth: 3)
                .opacity(model.dropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], delegate: FloatDropDelegate(model: model))
    }

    /// Closes the whole window: round, top left, like a window's close button. (Taking out one file is a smaller minus at the end of
    /// its row: a different place, size and shape, not only another colour.)
    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: Self.buttonSide, height: Self.buttonSide)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(9)
        .opacity(model.hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: model.hovering)
        .help(tr("Close", "Schließen"))
        .accessibilityLabel(tr("Close", "Schließen"))
    }

    // MARK: Stack

    private var collapsedStack: some View {
        VStack(spacing: 6) {
            stack
                .frame(width: 120, height: 112)
                .background {
                    // The window has the keyboard: a fine ring around the picture, so it shows where Space and ⌘C go.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.accentForeground, lineWidth: 2)
                        .padding(-6)
                        .opacity(model.focused ? 1 : 0)
                }
                .overlay {
                    FileDragSource(files: { model.currentFiles() }, thumbnails: { model.thumbnails }, click: model.canExpand ? { model.setExpanded(true) } : nil)
                }
                .padding(.top, 22)
            Text(model.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .allowsHitTesting(false)
        }
        .frame(width: Self.collapsedSize.width, height: Self.collapsedSize.height, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityHint(tr("Drag out to copy. The original stays where it is.", "Zum Kopieren herausziehen. Das Original bleibt, wo es ist."))
        .accessibilityAddTraits(.isImage)
        .accessibilityActions {
            if model.canExpand {
                Button(tr("Show Files One by One", "Einzeln zeigen")) { model.setExpanded(true) }
            }
        }
        .accessibilityAction(named: tr("Copy Files", "Dateien kopieren")) { FileActions.copyFiles(model.currentFiles(), to: .general) }
        .accessibilityAction(named: tr("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting(model.currentFiles()) }
        .accessibilityAction(named: tr("Close", "Schließen")) { close() }
    }

    /// One picture, or up to three fanned a little with the number of files.
    private var stack: some View {
        let shown = model.stack
        return ZStack {
            ForEach(Array(shown.enumerated().reversed()), id: \.element) { index, url in
                thumbnail(url, side: 100)
                    .rotationEffect(.degrees(shown.count == 1 ? 0 : [0, -6, 6][index]))
                    .offset(x: shown.count == 1 ? 0 : [0, -6, 6][index], y: CGFloat(index) * -3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.files.count > 1 {
                Text("\(model.files.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(Capsule().fill(Theme.accent))
                    .offset(x: 2, y: -2)
            }
        }
        .allowsHitTesting(false)
    }

    private func thumbnail(_ url: URL, side: CGFloat) -> some View {
        Group {
            if let image = model.thumbnails[url] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.18), radius: side > 50 ? 3 : 1.5, y: 1)
    }

    // MARK: One by one

    private var expandedList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.isHeader)
                Button { model.setExpanded(false) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: Self.buttonSide, height: Self.buttonSide)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(tr("Stack Files", "Zuklappen"))
                .accessibilityLabel(tr("Stack Files", "Zuklappen"))
            }
            .padding(.leading, 40)
            .padding(.trailing, 9)
            .frame(height: Self.headerHeight)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.files, id: \.self) { url in
                        FloatRow(model: model, url: url, thumbnail: thumbnail(url, side: 40))
                            .transition(.opacity)
                    }
                }
            }
            .scrollDisabled(model.files.count <= Self.visibleRows)
        }
        .frame(width: Self.expandedWidth)
    }
}

/// One file of the opened stack: picture and name to drag out (a copy), an x on hover that takes it out of the window only.
private struct FloatRow<Picture: View>: View {
    @ObservedObject var model: FloatShelfModel
    let url: URL
    let thumbnail: Picture
    private var hovering: Bool { model.hoveredFile == url }
    private var selected: Bool { model.selection == url }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(selected && model.focused ? Color.white : Color.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 26)
        }
        .padding(.horizontal, 12)
        .frame(height: FloatShelfView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowFill).padding(.horizontal, 5))
        .overlay {
            FileDragSource(files: { model.current(url).map { [$0] } ?? [] }, thumbnails: { model.thumbnails }, click: nil, hover: { inside in
                if inside { model.hoveredFile = url } else if model.hoveredFile == url { model.hoveredFile = nil }
            })
        }
        .overlay(alignment: .trailing) {
            Button { model.remove(url) } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: FloatShelfView.buttonSide, height: FloatShelfView.buttonSide)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .foregroundStyle(selected && model.focused ? Color.white : Color.primary)
            .opacity(hovering ? 1 : 0)
            .help(tr("Remove from This Window", "Aus dem Fenster entfernen"))
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint(tr("Drag out to copy. The original stays where it is.", "Zum Kopieren herausziehen. Das Original bleibt, wo es ist."))
        .accessibilityAction(named: tr("Copy", "Kopieren")) { FileActions.copyFiles(model.current(url).map { [$0] } ?? [], to: .general) }
        .accessibilityAction(named: tr("Remove from This Window", "Aus dem Fenster entfernen")) { model.remove(url) }
        .accessibilityAction(named: tr("Show in Finder", "Im Finder zeigen")) { NSWorkspace.shared.activateFileViewerSelecting(model.current(url).map { [$0] } ?? []) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Chosen with the keys: emerald while the window has the keyboard, grey when it hasn't (as in Finder); otherwise a light shade
    /// under the pointer.
    private var rowFill: Color {
        if selected { return model.focused ? Theme.accent : Color.primary.opacity(0.12) }
        return Color.primary.opacity(hovering ? 0.06 : 0)
    }
}

/// Files dropped on the window join it. The answer is "copy", so the app they come from never deletes or moves anything.
private struct FloatDropDelegate: DropDelegate {
    let model: FloatShelfModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { model.dropTargeted = true }
    func dropExited(info: DropInfo) { model.dropTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        model.dropTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { model.add([url]) }
            }
        }
        return !providers.isEmpty
    }
}

/// The empty surface of the window: dragging moves the window, a click (without moving) is passed on. Also tells when the pointer
/// is over the window.
private struct WindowDragArea: NSViewRepresentable {
    let hover: (Bool) -> Void
    let click: () -> Void

    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.hover = hover
        view.click = click
    }

    final class SurfaceView: NSView {
        var hover: (Bool) -> Void = { _ in }
        var click: () -> Void = {}

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }

        private var start: (mouse: NSPoint, origin: NSPoint)?
        private var moved = false

        /// Moves the window by hand: a click that didn't move it is a click.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            start = (NSEvent.mouseLocation, window.frame.origin)
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
            guard moved || hypot(dx, dy) > 2 else { return }
            moved = true
            window.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            if start != nil, !moved { click() }
            start = nil
        }
    }
}

/// Where files are dragged out of the window. AppKit's own drag, because only that can promise "copy only": the Finder copies
/// even on the same disk, the Trash refuses, and keys held while dropping change nothing. A click without dragging is passed on.
struct FileDragSource: NSViewRepresentable {
    let files: () -> [URL]
    let thumbnails: () -> [URL: NSImage]
    let click: (() -> Void)?
    var hover: ((Bool) -> Void)?

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.files = files
        view.thumbnails = thumbnails
        view.click = click
        view.hover = hover
    }

    final class SourceView: NSView, NSDraggingSource {
        var files: () -> [URL] = { [] }
        var thumbnails: () -> [URL: NSImage] = { [:] }
        var click: (() -> Void)?
        var hover: ((Bool) -> Void)?
        private var downPoint: NSPoint?
        private var dragging = false

        /// The first click already works, also while another app is in front.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            if hover != nil {
                addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            }
        }

        override func mouseEntered(with event: NSEvent) { hover?(true) }
        override func mouseExited(with event: NSEvent) { hover?(false) }

        override func mouseDown(with event: NSEvent) {
            downPoint = convert(event.locationInWindow, from: nil)
            dragging = false
            NotificationCenter.default.post(name: FloatDrag.willBegin, object: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = downPoint, !dragging else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            dragging = true
            let urls = files()
            guard !urls.isEmpty else { NSSound.beep(); return }
            let session = beginDraggingSession(with: FloatDrag.items(for: urls, thumbnails: thumbnails(), in: bounds.insetBy(dx: 4, dy: 4)), event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .stack
        }

        override func mouseUp(with event: NSEvent) {
            if downPoint != nil, !dragging { click?() }
            downPoint = nil
            dragging = false
        }

        // Dragging out: only ever a copy.

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            FloatDrag.allowed
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

        /// Whatever the other side did, nothing happens to the files here: they stay pinned and untouched.
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            downPoint = nil
            dragging = false
        }
    }
}

/// The buttons work with the first click, also while another app is in front (the window never becomes the key window).
private final class FloatHostingView: NSHostingView<FloatShelfView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The floating window. It never takes the focus by itself: it appears without bringing the app forward, and works with the first
/// click while another app is in front. A click into it gives it the keyboard (still without bringing the app forward); then Esc and
/// ⌘W close it, the arrow keys choose a file, the space bar shows Quick Look and ⌘C copies.
final class FloatPanel: NSPanel {
    let model: FloatShelfModel

    init(files: [URL]) {
        model = FloatShelfModel(files: files)
        super.init(contentRect: NSRect(origin: .zero, size: FloatShelfView.collapsedSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = tr("Floating files", "Angeheftete Dateien")
        followLanguage(self) { [weak self] in self?.title = tr("Floating files", "Angeheftete Dateien") }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false

        // Liquid Glass like the ring and the card; solid with "Reduce transparency" or "Increase contrast" (`HUDSurface`).
        // In a plain holder that follows the window: the window alone decides its size (`fitContent`), the SwiftUI content fills it.
        let holder = NSView(frame: NSRect(origin: .zero, size: FloatShelfView.collapsedSize))
        let hosting = FloatHostingView(rootView: FloatShelfView(model: model, close: { [weak self] in self?.close() }))
        hosting.sizingOptions = []
        hosting.frame = holder.bounds
        hosting.autoresizingMask = [.width, .height]
        holder.addSubview(hosting)
        contentView = holder
        model.onChange = { [weak self] animated in self?.fitContent(animated: animated) }
        model.onEmpty = { [weak self] in self?.close() }
    }

    /// Fades in; with "Reduce motion" it fades without rising.
    func appear() {
        let final = frame
        alphaValue = 0
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { setFrame(final.offsetBy(dx: 0, dy: -8), display: false) }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
            animator().setFrame(final, display: true)
        }
    }

    /// The size for the stack or the list; it grows downwards and stays on the screen. With "Reduce motion" it changes at once (the
    /// content cross-fades).
    func fitContent(animated: Bool) {
        let size = FloatShelfView.size(expanded: model.expanded, count: model.files.count)
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let target = FloatShelf.resized(frame, to: size, in: visible)
        resizeTimer?.invalidate()
        resizeTimer = nil
        guard target != frame else { return }
        guard animated, isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setFrame(target, display: true)
            return
        }
        // Stepped here, 60 times a second, rather than with the window animator (whose resize did not always arrive).
        let start = frame
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                let progress = FloatPanel.eased(Date().timeIntervalSince(began) / FloatPanel.resizeSeconds)
                self.setFrame(FloatPanel.interpolate(start, target, progress), display: true)
                if progress >= 1 {
                    timer.invalidate()
                    self.resizeTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

    static let resizeSeconds: TimeInterval = 0.25
    private var resizeTimer: Timer?

    /// Ease in and out, from 0 to 1.
    nonisolated static func eased(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }

    /// A frame on the way, on whole points; at 1 exactly the target.
    nonisolated static func interpolate(_ a: NSRect, _ b: NSRect, _ t: Double) -> NSRect {
        guard t < 1 else { return b }
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { (x + (y - x) * t).rounded() }
        return NSRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
    }

    /// Only after a click into it: appearing never takes the keyboard (`orderFrontRegardless`).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        model.focused = true
    }

    override func resignKey() {
        super.resignKey()
        model.focused = false
    }

    /// The keys are taken here, before the content: SwiftUI has nothing in the window that would want them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(FloatKey(event)) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handle(FloatKey(event)) || super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// Runs what a key does; false when the key means nothing here.
    @discardableResult
    func handle(_ key: FloatKey?) -> Bool {
        guard let key else { return false }
        switch key {
        case .close: close()
        case .previous: model.moveSelection(-1)
        case .next: model.moveSelection(1)
        case .quickLook: FloatQuickLook.toggle(model.chosenFiles(), from: model)
        case .copy:
            let files = model.chosenFiles()
            if files.isEmpty { NSSound.beep() } else { FileActions.copyFiles(files, to: .general) }
        }
        return true
    }

    override func close() {
        if FloatQuickLook.owner === model { FloatQuickLook.close() }
        super.close()
        FloatShelf.closed(self)
    }
}

/// What a key does in the floating window.
enum FloatKey: Equatable {
    case close, previous, next, quickLook, copy

    /// Esc and ⌘W close, ← ↑ and → ↓ choose, the space bar is Quick Look, ⌘C copies. Other keys, and these with other modifiers,
    /// mean nothing here.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        switch (keyCode, mods) {
        case (53, []): self = .close
        case (123, []), (126, []): self = .previous
        case (124, []), (125, []): self = .next
        case (49, []): self = .quickLook
        case (_, [.command]) where characters?.lowercased() == "w": self = .close
        case (_, [.command]) where characters?.lowercased() == "c": self = .copy
        default: return nil
        }
    }

    init?(_ event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
    }
}

/// Quick Look for the floating window: the files chosen there, shown by the system's preview panel. The app comes forward for it,
/// because the preview panel only takes the keyboard (space and Esc close it, the arrows go through several files) in the app in
/// front; the space bar asked for it, so this is no surprise.
@MainActor
final class FloatQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = FloatQuickLook()
    private(set) static weak var owner: FloatShelfModel?
    private var files: [URL] = []

    static func toggle(_ files: [URL], from model: FloatShelfModel) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible { return close() }
        guard !files.isEmpty else { return NSSound.beep() }
        shared.files = files
        owner = model
        NSApp.activate()
        panel.dataSource = shared
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { files.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { files.indices.contains(index) ? files[index] as NSURL : nil }
    }
}
