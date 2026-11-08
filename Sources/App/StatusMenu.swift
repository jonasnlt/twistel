import AppKit

/// The menu bar icon: its menu chooses files (the ring opens below the icon), shows what is running and the last result (so all of it
/// works with the keyboard too), and leads to Settings and the introduction. Dropping files on the icon was removed:
/// dragging to the top edge brings up the Spaces bar over it.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?
    private let radial: RadialController
    var openSettings: () -> Void = {}
    var showIntroduction: () -> Void = {}

    init(radial: RadialController) {
        self.radial = radial
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.image()
            button.toolTip = Self.toolTip
            followLanguage(button) { [weak button] in button?.toolTip = StatusMenu.toolTip }
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        DiagnosticLog.log("menu bar icon added (visible \(item.isVisible), in a window \(item.button?.window != nil))")
    }

    /// The hint on the menu bar icon, in the app's language now.
    static var toolTip: String {
        tr("\(AppIdentity.name): hold \(AppSettings.shared.ringKeys.convert.symbols) while dragging files",
           "\(AppIdentity.name): beim Ziehen von Dateien \(AppSettings.shared.ringKeys.convert.symbols) halten")
    }

    /// Rebuilt each time it opens, in the app's language and with the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: tr("Choose Files …", "Dateien wählen …"), action: #selector(chooseFiles), keyEquivalent: "o").target = self
        menu.addItem(.separator())
        let status = NSMenuItem(title: Self.statusText(JobRunner.shared.jobs), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if JobRunner.shared.jobs.contains(where: { !$0.status.isFinished }) {
            menu.addItem(withTitle: tr("Cancel All", "Alle abbrechen"), action: #selector(cancelAll), keyEquivalent: "").target = self
        }
        let finished = JobRunner.shared.jobs.filter { $0.status == .done && !$0.outputs.isEmpty }
        if !finished.isEmpty, JobRunner.shared.jobs.allSatisfy({ $0.status.isFinished }) {
            let model = ResultCardModel(jobs: JobRunner.shared.jobs)
            if model.outputs.count == 1 {
                menu.addItem(withTitle: tr("Open \u{201C}\(model.outputs[0].lastPathComponent)\u{201D}", "\u{201E}\(model.outputs[0].lastPathComponent)\u{201C} öffnen"), action: #selector(openResult), keyEquivalent: "").target = self
            }
            menu.addItem(withTitle: tr("Show Result in Finder", "Ergebnis im Finder zeigen"), action: #selector(revealResult), keyEquivalent: "").target = self
            if model.canUndo {
                menu.addItem(withTitle: tr("Undo (Move Result to Trash)", "Rückgängig (Ergebnis in den Papierkorb)"), action: #selector(undoResult), keyEquivalent: "").target = self
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Settings …", "Einstellungen …"), action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: tr("Show Introduction", "Einführung zeigen"), action: #selector(introduction), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Show Log", "Protokoll zeigen"), action: #selector(showLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("About \(AppIdentity.name)", "Über \(AppIdentity.name)"), action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Check for Updates …", "Nach Updates suchen …"), action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit \(AppIdentity.name)", "\(AppIdentity.name) beenden"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// "Ready", "Compressing · 1 of 3 done", "Done".
    static func statusText(_ jobs: [Job]) -> String {
        let running = jobs.filter { !$0.status.isFinished }
        guard !running.isEmpty else {
            return jobs.isEmpty ? tr("Ready", "Bereit") : ResultCardModel(jobs: jobs).headline
        }
        let current = running.first { $0.status == .running } ?? running[0]
        if jobs.count == 1 { return current.title + (current.step.map { " · \($0)" } ?? "") }
        let done = jobs.count - running.count
        return current.title + " · " + tr("\(done) of \(jobs.count) done", "\(done) von \(jobs.count) fertig")
    }

    private func belowIcon() -> NSPoint? {
        guard let window = item?.button?.window else { return nil }
        let frame = window.frame
        return NSPoint(x: frame.midX, y: frame.minY - RadialWheelView.side / 2)
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = tr("Choose", "Wählen")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            MainActor.assumeIsolated { self?.radial.presentPicker(for: panel.urls, ring: .convert, at: self?.belowIcon()) }
        }
    }

    @objc private func cancelAll() { JobRunner.shared.cancelAll() }

    @objc private func openResult() {
        if let url = ResultCardModel(jobs: JobRunner.shared.jobs).outputs.first { NSWorkspace.shared.open(url) }
    }

    @objc private func revealResult() {
        NSWorkspace.shared.activateFileViewerSelecting(ResultCardModel(jobs: JobRunner.shared.jobs).outputs)
    }

    @objc private func undoResult() {
        JobRunner.shared.undo(JobRunner.shared.jobs)
        JobRunner.shared.dismissAll()
    }

    @objc private func settings() { openSettings() }
    @objc private func introduction() { showIntroduction() }

    @objc private func showLog() {
        DiagnosticLog.flush()
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.logFile])
    }

    /// Opens a web page in the user's browser. The app itself never goes online; tests replace this to see the address.
    static var openInBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// No update function in the app: the releases page opens in the browser, where the newest version can be downloaded.
    @objc func checkForUpdates() {
        DiagnosticLog.log("check for updates: releases page opened in the browser")
        Self.openInBrowser(AppIdentity.releasesURL)
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppIdentity.name,
            .version: AppIdentity.buildMark ?? "",
            .credits: Self.aboutCredits(),
        ])
    }

    /// The About window's text: what twistel does, its licence and a link to the source code (opens in the browser when clicked).
    static func aboutCredits() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]
        let text = NSMutableAttributedString(string: tr("Converts and edits files on this Mac. Nothing is uploaded.",
                                                        "Wandelt und bearbeitet Dateien auf diesem Mac. Nichts wird hochgeladen.") + "\n\n"
                                             + tr("Free software under the GPL-3.0 license.", "Freie Software unter der Lizenz GPL-3.0.") + "\n",
                                             attributes: plain)
        var link = plain
        link[.link] = AppIdentity.repositoryURL
        text.append(NSAttributedString(string: "github.com/jonasnlt/twistel", attributes: link))
        return text
    }
}

/// Finder's menu for selected files (right-click, at the very bottom; with many services in the Services or Quick Actions submenu): the
/// app offers its three rings there. macOS reads the list from the app's Info.plist (`NSServices`, written by `scripts/build.sh`) once it knows the app.
@MainActor
final class ServiceProvider: NSObject {
    private let radial: RadialController

    init(radial: RadialController) {
        self.radial = radial
    }

    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pasteboard, ring: .convert)
    }

    @objc func toolFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pasteboard, ring: .tools)
    }

    @objc func actionFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pasteboard, ring: .actions)
    }

    private func open(_ pasteboard: NSPasteboard, ring: RingKind) {
        let urls = DragMonitor.fileURLs(on: pasteboard)
        DiagnosticLog.log("service \(ring.rawValue) for \(urls.map(\.lastPathComponent))")
        guard !urls.isEmpty else { return }
        radial.presentPicker(for: urls, ring: ring, takesKeyboard: false)
    }
}
