import AppKit

protocol DragMonitorDelegate: AnyObject {
    /// Keys of a ring are held during a file drag (`held`: all keys held now).
    func dragMonitor(_ monitor: DragMonitor, didBeginModifiedDrag urls: [URL], at point: NSPoint, held: ModifierCombo)
    func dragMonitor(_ monitor: DragMonitor, didChangeModifiers held: ModifierCombo, at point: NSPoint)
    func dragMonitor(_ monitor: DragMonitor, didUpdateDraggedURLs urls: [URL])
    func dragMonitorDidEndDrag(_ monitor: DragMonitor)
}

/// Debug builds only: `TWISTEL_DEBUG_DRAG=<absolute path>` writes every step of a drag to that file. The release build has no such switch
/// (it wrote to a shared place, /tmp, that other users of the Mac can read).
enum DragDebug {
    #if DEBUG
    static let enabled = path != nil
    private static let path = ProcessInfo.processInfo.environment["TWISTEL_DEBUG_DRAG"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    private static let handle: FileHandle? = {
        guard let path else { return nil }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()
    #else
    static let enabled = false
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard enabled, let handle else { return }
        let text = DiagnosticLog.withoutFolders(message())
        try? handle.write(contentsOf: Data((String(format: "%.3f ", Date().timeIntervalSince1970) + text + "\n").utf8))
        #endif
    }
}

final class DragMonitor {
    weak var delegate: DragMonitorDelegate?

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?
    private var pressChangeCount = 0
    private var lastReadChange = 0
    private var activeURLs: [URL] = []
    private var dragInFlight = false
    private var presenting = false
    private var handled = false
    private var mouseDown = false
    private var pressOrigin = NSPoint.zero
    private var pressTime = Date.distantPast
    private var pressInFinder = false
    private var pollTick = 0

    /// Where the state comes from; tests put in their own (a pasteboard of their own, a pressed button, keys).
    var dragPasteboard = NSPasteboard(name: .drag)
    var buttonState: () -> Bool = { NSEvent.pressedMouseButtons & 1 == 1 }
    var keyState: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    private var floatObserver: NSObjectProtocol?

    /// A drag out of the app's own floating window ("Float") isn't seen by the global monitors, which only hear other apps; the
    /// window says so before the drag begins, and the rings open for it like for a drag from Finder.
    init() {
        floatObserver = NotificationCenter.default.addObserver(forName: FloatDrag.willBegin, object: nil, queue: nil) { [weak self] _ in
            DragDebug.log("drag from the floating window")
            self?.beginPressIfNeeded()
        }
    }

    deinit {
        if let floatObserver { NotificationCenter.default.removeObserver(floatObserver) }
    }

    private static let idleInterval = 1.0 / 30.0
    private static let dragInterval = 1.0 / 60.0
    private static let fallbackDragDistance: CGFloat = 24
    private static let fallbackDelay: TimeInterval = 0.3

    func start() {
        stop()
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            self?.beginPressIfNeeded()
            self?.poll()
        }
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            DragDebug.log("global leftMouseDown flags=\(event.modifierFlags.rawValue)")
            self?.beginPressIfNeeded()
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DragDebug.log("global leftMouseUp")
            self?.finishPress()
        }
        monitors = [dragged, down, up].compactMap { $0 }
        schedulePoll(interval: Self.idleInterval)
        DragDebug.log("DragMonitor started; monitors=\(monitors.count) dragChangeCount=\(dragPasteboard.changeCount)")
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        endActivity()
    }

    func markHandled() {
        handled = true
        presenting = false
        activeURLs = []
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private var buttonPressed: Bool { buttonState() }

    private var held: ModifierCombo { ModifierCombo(flags: keyState()) }

    /// The keys held now open a ring (Settings › General).
    private var ringKeysHeld: Bool { AppSettings.shared.ringKeys.ring(for: held) != nil }

    private func beginPressIfNeeded() {
        guard !mouseDown else { return }
        mouseDown = true
        handled = false
        dragInFlight = false
        activeURLs = []
        pressOrigin = NSEvent.mouseLocation
        pressTime = Date()
        pressInFinder = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        pressChangeCount = dragPasteboard.changeCount
        lastReadChange = pressChangeCount
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Tracking a file drag")
        schedulePoll(interval: Self.dragInterval)
        DragDebug.log("press began at \(NSEvent.mouseLocation) dragChangeCount=\(pressChangeCount) flags=\(keyState().rawValue)")
    }

    func poll() {
        guard buttonPressed else {
            if mouseDown { finishPress() }
            return
        }
        beginPressIfNeeded()
        refreshDragPasteboard()
        if !dragInFlight, pressInFinder, ringKeysHeld, Date().timeIntervalSince(pressTime) >= Self.fallbackDelay, hypot(NSEvent.mouseLocation.x - pressOrigin.x, NSEvent.mouseLocation.y - pressOrigin.y) >= Self.fallbackDragDistance {
            dragInFlight = true
            DragDebug.log("no drag pasteboard content; assuming Finder drag from movement")
        }
        evaluateModifiers()
        pollTick += 1
        if pollTick % 30 == 0 {
            DragDebug.log("poll: loc=\(NSEvent.mouseLocation) held=\(held.symbols) inFlight=\(dragInFlight) urls=\(activeURLs.count) presenting=\(presenting) handled=\(handled)")
        }
    }

    private func refreshDragPasteboard() {
        let pasteboard = dragPasteboard
        let change = pasteboard.changeCount
        guard change != lastReadChange else { return }
        lastReadChange = change
        guard change > pressChangeCount else { return }
        let items = pasteboard.pasteboardItems ?? []
        dragInFlight = !items.isEmpty
        activeURLs = Self.fileURLs(on: pasteboard)
        DragDebug.log("drag pasteboard change=\(change) types=\(pasteboard.types?.map(\.rawValue) ?? []) items=\(items.count) itemTypes=\(items.map { $0.types.map(\.rawValue) }) urls=\(activeURLs.map(\.path))")
        if presenting, !activeURLs.isEmpty {
            delegate?.dragMonitor(self, didUpdateDraggedURLs: activeURLs)
        }
    }

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty {
            urls = (pasteboard.pasteboardItems ?? []).compactMap { item in
                item.string(forType: .fileURL).flatMap { URL(string: $0) }
            }
        }
        return urls.compactMap { url -> URL? in
            let resolved = (url as NSURL).filePathURL ?? url
            guard resolved.isFileURL else { return nil }
            return isDraggable(resolved) ? resolved.standardizedFileURL : nil
        }
    }

    /// Files, and documents that are folders (RTFD, as TextEdit saves text with pictures); other folders are not converted.
    static func isDraggable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue || FileFormat.detect(url) == .rtfd
    }

    private func evaluateModifiers() {
        guard mouseDown, dragInFlight, !handled else { return }
        let keys = held
        let point = NSEvent.mouseLocation
        if ringKeysHeld, !presenting {
            presenting = true
            DragDebug.log("presenting wheel for \(activeURLs.map(\.lastPathComponent)) at \(point) held=\(keys.symbols)")
            delegate?.dragMonitor(self, didBeginModifiedDrag: activeURLs, at: point, held: keys)
        } else if presenting {
            delegate?.dragMonitor(self, didChangeModifiers: keys, at: point)
        }
    }

    private func finishPress() {
        guard mouseDown else { return }
        mouseDown = false
        dragInFlight = false
        handled = false
        activeURLs = []
        endActivity()
        schedulePoll(interval: Self.idleInterval)
        if presenting {
            presenting = false
            DragDebug.log("press ended; dismissing wheel")
            delegate?.dragMonitorDidEndDrag(self)
        }
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
