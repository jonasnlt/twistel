import AppKit
import SwiftUI

/// The list behind "More …": everything a ring can do for the files, with a search field that has the keyboard at once.
/// ↑/↓ choose, Return runs (with Option: the last values, no window), Esc closes.
@MainActor
final class MoreListModel: ObservableObject {
    let entries: [RingEntry]
    let title: String
    let files: String
    @Published var text: String { didSet { selection = 0 } }
    @Published var selection = 0

    init(entries: [RingEntry], title: String, files: String, text: String) {
        self.entries = entries
        self.title = title
        self.files = files
        self.text = text
    }

    var shown: [RingEntry] { RingBuilder.filter(entries, by: text) }

    func move(_ step: Int) {
        let count = shown.count
        guard count > 0 else { return }
        selection = min(max(0, selection + step), count - 1)
    }

    var chosen: RingEntry? {
        let list = shown
        return list.indices.contains(selection) ? list[selection] : nil
    }
}

struct MoreListView: View {
    @ObservedObject var model: MoreListModel
    var choose: (RingEntry, Bool) -> Void
    @FocusState private var searchFocused: Bool

    static let size = CGSize(width: 340, height: 420)

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline)
                Text(model.files).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            TextField(tr("Search", "Suchen"), text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .accessibilityLabel(tr("Search", "Suchen"))
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.shown.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == model.selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { choose(entry, NSEvent.modifierFlags.contains(.option)) }
                                .onHover { inside in if inside { model.selection = index } }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: model.selection) { _, new in proxy.scrollTo(new) }
            }
            if model.shown.isEmpty {
                Text(tr("Nothing found", "Nichts gefunden"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { searchFocused = true }
    }

    private func row(_ entry: RingEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isAvailable ? entry.symbol : "arrow.down.circle")
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let missing = entry.missing {
                    Text(tr("Needs \(missing.name)", "Braucht \(missing.name)"))
                        .font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : (entry.isAvailable ? Color.primary : Color.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.accent : Color.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

final class MoreListPanel: NSPanel {
    private static var current: MoreListPanel?
    private var keyMonitor: Any?
    private var model: MoreListModel?
    private var onChoose: ((RingEntry, Bool) -> Void)?

    override var canBecomeKey: Bool { true }

    @MainActor
    static func show(entries: [RingEntry], title: String, files: [URL], at point: NSPoint, text: String, choose: @escaping (RingEntry, Bool) -> Void) {
        current?.finish()
        let label = files.count == 1 ? files[0].lastPathComponent : tr("\(files.count) files", "\(files.count) Dateien")
        let model = MoreListModel(entries: entries, title: title, files: label, text: text)
        let panel = MoreListPanel(contentRect: NSRect(origin: .zero, size: MoreListView.size), styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                                  backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.model = model
        panel.onChoose = choose
        panel.contentViewController = NSHostingController(rootView: MoreListView(model: model) { [weak panel] entry, option in
            panel?.finish()
            choose(entry, option)
        })
        panel.setContentSize(MoreListView.size)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: min(max(point.x - MoreListView.size.width / 2, visible.minX + 8), visible.maxX - MoreListView.size.width - 8),
                                 y: min(max(point.y - MoreListView.size.height / 2, visible.minY + 8), visible.maxY - MoreListView.size.height - 8))
            panel.setFrameOrigin(origin)
        }
        panel.installKeys()
        current = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// The search field keeps the typing; the arrows, Return and Esc are taken before it sees them.
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self, let model = self.model else { return event }
            switch event.keyCode {
            case 125: model.move(1); return nil
            case 126: model.move(-1); return nil
            case 53: self.finish(); return nil
            case 36, 76:
                if let entry = model.chosen {
                    self.finish()
                    self.onChoose?(entry, event.modifierFlags.contains(.option))
                }
                return nil
            default: return event
            }
        }
    }

    override func resignKey() {
        super.resignKey()
        // Clicking elsewhere closes the list like a menu.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            self.finish()
        }
    }

    func finish() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        orderOut(nil)
        if MoreListPanel.current === self { MoreListPanel.current = nil }
    }
}
