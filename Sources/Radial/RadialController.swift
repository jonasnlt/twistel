import AppKit

final class RadialPanel: NSPanel {
    let radialView = RadialView(frame: .zero)

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        // The panel covers the whole screen. It takes the mouse only while a ring is open from a drag or for the keyboard
        // (`RadialController.present`); in every other state clicks and scrolling go through to the apps below.
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        radialView.frame = contentView?.bounds ?? .zero
        radialView.autoresizingMask = [.width, .height]
        contentView = radialView
    }

    override var canBecomeKey: Bool { true }
}

/// Opens and closes the rings, fills them, and hands what was chosen on.
final class RadialController: DragMonitorDelegate {
    private var panel: RadialPanel?
    private var urls: [URL] = []
    private var formats: [FileFormat] = []
    private(set) var ring: RingKind = .convert
    /// The ring the held keys ask for. Scrolling can show another one; only a change of the keys takes the ring back to theirs.
    private var keysRing: RingKind?
    private var layout: RingLayout = .empty
    private var visible = false
    /// A hide that is still fading out; a ring opened meanwhile cancels it.
    private var hiding = 0
    private var pickerMode = false
    private var outsideClickMonitor: Any?
    /// Emergency brake: checks while a ring is open whether the mouse button was let go without anything happening.
    private var staleTimer: Timer?
    private var releasedAt: Date?

    /// The test program switches this off: it never puts a real ring on the screen (the panel is made and filled, not shown).
    static var showsOnScreen = true
    /// Measuring in the test access: the ring is shown but never takes the mouse.
    var passive = false
    /// A ring from a drag that is still open this long after the mouse button was let go closes itself.
    static let staleSeconds: TimeInterval = 3
    /// Where the ring was opened: results show their progress on this screen.
    private(set) var lastPoint: NSPoint = .zero

    weak var dragMonitor: DragMonitor?
    /// Settings, and the keys of the rings, come from here (tests and the test access use their own).
    var settings: () -> AppSettings = { AppSettings.shared }
    /// A ring opened (or got its files): the introduction ticks off the rings tried with its practice picture.
    var onPresent: ((RingKind, [URL]) -> Void)?
    /// What happens with the chosen item; set by the app delegate (`RingDispatch`).
    var onChoose: ((RingEntry, [URL], RingKind, Bool, NSPoint) -> Void)?

    var currentLayout: RingLayout { layout }
    /// The ring's view while it exists (the tests act on it as the mouse would).
    var currentPanelView: RadialView? { panel?.radialView }

    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, held: ModifierCombo) {
        dragMonitor = monitor
        pickerMode = false
        guard let ring = settings().ringKeys.ring(for: held) else { return }
        keysRing = ring
        present(urls: urls, at: point, ring: ring)
    }

    func dragMonitor(_ monitor: DragMonitor, didChangeModifiers held: ModifierCombo, at point: NSPoint) {
        guard !pickerMode else { return }
        guard let wanted = settings().ringKeys.ring(for: held) else {
            if visible { hide() }
            return
        }
        if !visible {
            keysRing = wanted
            present(urls: urls, at: point, ring: wanted)
        } else if wanted != keysRing {
            keysRing = wanted
            guard wanted != ring else { return }
            ring = wanted
            reloadItems()
        }
    }

    func dragMonitor(_ monitor: DragMonitor, didUpdateDraggedURLs urls: [URL]) {
        adopt(urls)
    }

    func dragMonitorDidEndDrag(_ monitor: DragMonitor) {
        guard !pickerMode else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.pickerMode else { return }
            self.hide()
        }
    }

    /// The ring without a drag (menu bar, Finder's Services menu, files opened with the app): it takes clicks and the keyboard.
    /// `takesKeyboard` false (Services, opening files with the app): any other app can ask for these, also while the person is typing
    /// somewhere else. Then the ring takes clicks at once, but keys only once the person turns to it: a click on it, or the mouse moved
    /// by `engageDistance` (`engage`). Until then every key is ignored, even if the ring got the keyboard some other way
    /// (the arrows worked at once): an Enter meant for another app never chooses anything here.
    func presentPicker(for urls: [URL], ring: RingKind = .convert, at point: NSPoint? = nil, takesKeyboard: Bool = true) {
        pickerMode = true
        let start = point ?? NSEvent.mouseLocation
        present(urls: urls, at: start, ring: ring)
        panel?.radialView.interactive = true
        panel?.makeFirstResponder(panel?.radialView)
        hasKeyboard = false
        panel?.radialView.keysArmed = takesKeyboard
        panel?.radialView.onPointer = takesKeyboard ? nil : { [weak self] location, clicked in
            guard let self else { return }
            if clicked { self.engage(because: "click") }
            else if Self.isDeliberate(from: start, to: location) { self.engage(because: "mouse moved") }
        }
        if Self.showsOnScreen { installOutsideClickMonitor() }
        if takesKeyboard {
            engage(because: "opened from twistel's menu")
        } else {
            DiagnosticLog.log("ring without keys until the mouse moves; key window \(panel?.isKeyWindow == true), app active \(NSApp.isActive)")
        }
    }

    /// How far (in points) the mouse must move from where the ring opened before it takes keys: a hand resting on a trackpad
    /// moves it by a point or two, someone turning to the ring by much more.
    static let engageDistance: CGFloat = 24

    static func isDeliberate(from start: NSPoint, to location: NSPoint) -> Bool {
        hypot(location.x - start.x, location.y - start.y) >= engageDistance
    }

    /// Whether the open ring takes keys (arrows, Return, Escape, typing).
    private(set) var hasKeyboard = false

    private func engage(because reason: String) {
        guard pickerMode, visible, !hasKeyboard else { return }
        hasKeyboard = true
        panel?.radialView.keysArmed = true
        panel?.radialView.onPointer = nil
        DiagnosticLog.log("ring takes keys: \(reason)")
        guard Self.showsOnScreen else { return }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func present(urls: [URL], at point: NSPoint, ring: RingKind) {
        self.urls = urls
        self.ring = ring
        lastPoint = point
        formats = urls.compactMap(FileFormat.detect)
        HelperPrograms.refreshIfOld()
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = self.panel ?? RadialPanel(screen: screen)
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        self.panel = panel

        let view = panel.radialView
        view.interactive = pickerMode
        let clamped = Self.clampedCenter(point, in: Self.usableFrame(of: screen), radius: view.discRadius + 8)
        view.center = NSPoint(x: clamped.x - screen.frame.minX, y: clamped.y - screen.frame.minY)
        view.onSelect = { [weak self] item, option in self?.select(item, option: option) }
        view.onCancel = { [weak self] in self?.hide() }
        view.onDragEntered = { [weak self] info in self?.adoptDraggedFiles(from: info) }
        view.onDragSessionEnded = { [weak self] in self?.dragSessionEnded() }
        view.onType = { [weak self] text in self?.openMore(typed: text) }
        view.onSwitchRing = { [weak self] step in self?.switchRing(by: step) }
        view.clearHighlight()
        reloadItems()
        hiding += 1
        // Stops a fade-out that is still running (it would otherwise end at "invisible" while the ring is open), then shows it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
        if !visible { view.presentation += 1 }
        // Now, and only now, the panel takes the mouse: to receive the drop, or the clicks of the keyboard ring.
        panel.ignoresMouseEvents = passive
        if Self.showsOnScreen { panel.orderFrontRegardless() }
        visible = true
        MainActor.assumeIsolated { SoundPlayer.shared.ringOpened() }
        releasedAt = nil
        startStaleWatch()
        view.announce()
    }

    /// Created before the first drag, so the first ring appears as fast as the others.
    func prepare() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let panel = RadialPanel(screen: screen)
        self.panel = panel
        panel.radialView.slots = RingBuilder.layout(.tools, for: [.pdf], count: settings().ringItemCount, favorites: nil).slots
        panel.radialView.layoutSubtreeIfNeeded()
        panel.radialView.slots = []
    }

    /// The screen without the notch: nothing of the ring or its fans may go under it.
    static func usableFrame(of screen: NSScreen) -> NSRect {
        var frame = screen.frame
        frame.size.height -= screen.safeAreaInsets.top
        return frame
    }

    static func clampedCenter(_ point: NSPoint, in frame: NSRect, radius: CGFloat) -> NSPoint {
        NSPoint(
            x: min(max(point.x, frame.minX + radius), frame.maxX - radius),
            y: min(max(point.y, frame.minY + radius), frame.maxY - radius)
        )
    }

    private func adoptDraggedFiles(from info: NSDraggingInfo) {
        guard !pickerMode else { return }
        let dragged = DragMonitor.fileURLs(on: info.draggingPasteboard)
        DragDebug.log("drag entered wheel; pasteboard urls=\(dragged.map(\.lastPathComponent)) known=\(urls.map(\.lastPathComponent))")
        adopt(dragged)
    }

    private func adopt(_ dragged: [URL]) {
        guard !pickerMode, visible, !dragged.isEmpty, dragged != urls else { return }
        urls = dragged
        formats = dragged.compactMap(FileFormat.detect)
        reloadItems()
    }

    private func dragSessionEnded() {
        guard !pickerMode, visible else { return }
        DragDebug.log("drag session ended while wheel visible; dismissing")
        hide()
        dragMonitor?.markHandled()
    }

    /// Tab in the keyboard ring, or scrolling over any open ring.
    func switchRing(by step: Int) {
        let all = RingKind.allCases
        let index = all.firstIndex(of: ring) ?? 0
        ring = all[(index + step + all.count) % all.count]
        DiagnosticLog.log("ring switched to \(ring.rawValue) (\(pickerMode ? "keyboard ring" : "scrolling"))")
        panel?.radialView.clearHighlight()
        reloadItems()
        panel?.radialView.announce()
    }

    /// What the ring shows for these files, as `RadialView` takes it. Kept apart so tests and the test access fill a ring the same way.
    static func fill(_ view: RadialView, ring: RingKind, urls: [URL], settings: AppSettings, picker: Bool = false) -> RingLayout {
        let formats = urls.compactMap(FileFormat.detect)
        view.title = ring.title
        // Without a drag the keys can't switch rings; Tab does.
        view.hint = picker ? RingKind.allCases.filter { $0 != ring }.map(\.title).joined(separator: " · ") + "  (" + tr("Tab", "Tab") + ")"
            : settings.ringKeys.hint(besides: ring)
        view.files = urls.count == 1 ? urls[0].lastPathComponent : (urls.isEmpty ? tr("Move the files over the ring", "Dateien über den Ring ziehen") : tr("\(urls.count) files", "\(urls.count) Dateien"))
        guard !urls.isEmpty else {
            view.slots = []
            view.emptyMessage = ring.title
            return .empty
        }
        guard formats.count == urls.count else {
            view.slots = []
            view.emptyMessage = tr("This kind of file isn\u{2019}t supported", "Diese Dateiart wird nicht unterstützt")
            return .empty
        }
        let kind = ring == .actions ? FileKind.any : (FileKind.common(formats) ?? .any)
        let layout = RingBuilder.layout(ring, for: formats, count: settings.ringItemCount, favorites: settings.favoriteList(ring, kind))
        view.slots = layout.slots
        view.emptyMessage = urls.count == 1 ? tr("Nothing to do here for this file", "Hier gibt es nichts für diese Datei")
            : tr("Nothing that fits all these files", "Nichts, was zu allen diesen Dateien passt")
        return layout
    }

    private func reloadItems() {
        guard let view = panel?.radialView else { return }
        layout = Self.fill(view, ring: ring, urls: urls, settings: settings(), picker: pickerMode)
        if !urls.isEmpty { onPresent?(ring, urls) }
    }

    private func select(_ item: RingEntry, option: Bool) {
        let files = urls
        let ring = ring
        let point = lastPoint
        let quickRun = settings().ringKeys.wantsQuickRun(ring: ring, held: option ? .option : [])
        DiagnosticLog.log("radial select \(item.id.key) in \(ring.rawValue) for \(files.map(\.lastPathComponent)) quickRun=\(quickRun)")
        if item.id == .more {
            openMore(typed: "")
            return
        }
        hide()
        dragMonitor?.markHandled()
        if let missing = item.missing {
            MainActor.assumeIsolated { HelperProgramNote.show(missing) }
            return
        }
        onChoose?(item, files, ring, quickRun, point)
    }

    /// The list behind "More …": everything this ring can do for these files, with a search field.
    private func openMore(typed: String) {
        let entries = layout.all
        let files = urls
        let ring = ring
        let point = lastPoint
        hide()
        dragMonitor?.markHandled()
        guard !entries.isEmpty else { return }
        MainActor.assumeIsolated {
            MoreListPanel.show(entries: entries, title: ring.title, files: files, at: point, text: typed) { [weak self] entry, option in
                if let missing = entry.missing {
                    HelperProgramNote.show(missing)
                    return
                }
                let quickRun = self?.settings().ringKeys.wantsQuickRun(ring: ring, held: option ? .option : []) ?? false
                self?.onChoose?(entry, files, ring, quickRun, point)
            }
        }
    }

    func highlight(_ index: Int) {
        panel?.radialView.highlight(index)
    }

    /// Draws the ring now instead of at the next screen refresh (measuring how fast it appears).
    func displayNow() {
        panel?.radialView.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
    }

    /// Whether the panel would take a click now (tests).
    var takesMouse: Bool { panel.map { !$0.ignoresMouseEvents } ?? false }
    var isOpen: Bool { visible }

    func hide() {
        // First of all, at once and before any animation: clicks and scrolling go through again.
        panel?.ignoresMouseEvents = true
        stopStaleWatch()
        visible = false
        MainActor.assumeIsolated { SoundPlayer.shared.ringClosed() }
        pickerMode = false
        hasKeyboard = false
        panel?.radialView.onPointer = nil
        panel?.radialView.clearHighlight()
        panel?.radialView.interactive = false
        // A short fade out (also with "Reduce motion": fading is not movement).
        hiding += 1
        let token = hiding
        if let panel, panel.isVisible, !Self.showsOnScreen {
            panel.orderOut(nil)
        } else if let panel, panel.isVisible {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.hiding == token, !self.visible else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: Emergency brake

    /// True when a ring opened by a drag is still open `staleSeconds` after the mouse button was let go.
    static func isStale(picker: Bool, buttonPressed: Bool, releasedAt: Date?, now: Date) -> Bool {
        guard !picker, !buttonPressed, let releasedAt else { return false }
        return now.timeIntervalSince(releasedAt) >= staleSeconds
    }

    /// Called twice a second while a ring is open; with the button let go and nothing happening, the ring closes after a few seconds.
    /// (The keyboard ring waits: it is meant to stay until a choice or Esc.)
    func checkStale(buttonPressed: Bool, now: Date = Date()) {
        guard visible, !pickerMode else { releasedAt = nil; return }
        if buttonPressed { releasedAt = nil; return }
        if releasedAt == nil { releasedAt = now }
        guard Self.isStale(picker: pickerMode, buttonPressed: buttonPressed, releasedAt: releasedAt, now: now) else { return }
        DiagnosticLog.log("ring closed by itself: the mouse button was let go and nothing happened")
        hide()
        dragMonitor?.markHandled()
    }

    private func startStaleWatch() {
        guard staleTimer == nil, Self.showsOnScreen else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkStale(buttonPressed: NSEvent.pressedMouseButtons & 1 == 1)
        }
        RunLoop.main.add(timer, forMode: .common)
        staleTimer = timer
    }

    private func stopStaleWatch() {
        staleTimer?.invalidate()
        staleTimer = nil
        releasedAt = nil
    }

    private func installOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }
}

/// A helper program is missing: what it is for and how to install it, with the command ready to copy.
enum HelperProgramNote {
    @MainActor
    static func show(_ program: HelperProgram) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = tr("\(program.name) is not installed", "\(program.name) ist nicht installiert")
        alert.informativeText = program.purpose + "\n\n"
            + tr("To install it with Homebrew, run this in Terminal:", "Zum Installieren mit Homebrew im Terminal eingeben:")
            + "\n" + program.installCommand
        alert.addButton(withTitle: tr("Copy Command", "Befehl kopieren"))
        alert.addButton(withTitle: tr("OK", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(program.installCommand, forType: .string)
        }
    }
}
