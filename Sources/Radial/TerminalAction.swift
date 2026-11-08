import AppKit
import UniformTypeIdentifiers

/// A program the "Terminal" action can open folders in (Settings › General).
struct TerminalProgram: Identifiable, Hashable {
    /// A bundle identifier, or the path of an app chosen with "Other …".
    let id: String
    let name: String
}

/// The actions ring's "Terminal": a terminal window in the folder of each file (in a dragged folder itself). Opened through
/// NSWorkspace like a double-click would, so it needs neither AppleScript nor a permission of its own.
@MainActor
enum TerminalAction {
    nonisolated static let appleTerminal = "com.apple.Terminal"

    /// Terminals besides Apple's that Settings offers when they are installed.
    nonisolated static let known: [TerminalProgram] = [
        TerminalProgram(id: "com.googlecode.iterm2", name: "iTerm"),
        TerminalProgram(id: "com.mitchellh.ghostty", name: "Ghostty"),
        TerminalProgram(id: "dev.warp.Warp-Stable", name: "Warp"),
        TerminalProgram(id: "net.kovidgoyal.kitty", name: "kitty"),
        TerminalProgram(id: "org.alacritty", name: "Alacritty"),
        TerminalProgram(id: "com.github.wez.wezterm", name: "WezTerm"),
        TerminalProgram(id: "co.zeit.hyper", name: "Hyper"),
    ]

    /// More folders than three, and the action asks first.
    nonisolated static func asksFirst(folders count: Int) -> Bool { count > 3 }

    /// The folder of each file, and a dragged folder itself; each folder once, in the order of the files. An app or another package
    /// counts as a file.
    nonisolated static func folders(for files: [URL]) -> [URL] {
        var seen = Set<String>()
        var folders: [URL] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            let folder = (isFolder ? file : file.deletingLastPathComponent()).standardizedFileURL
            if seen.insert(folder.path).inserted { folders.append(folder) }
        }
        return folders
    }

    /// Where the chosen program is: a path as it is, a bundle identifier through Launch Services.
    nonisolated static func appURL(_ id: String, lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> URL? {
        if id.hasPrefix("/") { return isApp(URL(fileURLWithPath: id)) ? URL(fileURLWithPath: id) : nil }
        return lookup(id).flatMap { isApp($0) ? $0 : nil }
    }

    /// A real app: a bundle ending in ".app" with an identifier and a program inside. A path in the settings could otherwise name
    /// any file (another app can write it there).
    nonisolated static func isApp(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), bundle.bundleIdentifier != nil,
              let executable = bundle.executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executable.path)
    }

    nonisolated static func name(of id: String, lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> String {
        if id == appleTerminal { return "Terminal" }
        if let program = known.first(where: { $0.id == id }) { return program.name }
        // Only for the name: what Launch Services or the path says, checked or not.
        let app = id.hasPrefix("/") ? URL(fileURLWithPath: id) : lookup(id)
        return app.map { $0.deletingPathExtension().lastPathComponent } ?? id
    }

    /// Apple's Terminal, the known ones that are installed, and the chosen one when it is none of these (picked with "Other …").
    nonisolated static func choices(current: String, lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> [TerminalProgram] {
        var list = [TerminalProgram(id: appleTerminal, name: "Terminal")]
        list += known.filter { lookup($0.id) != nil }
        if !list.contains(where: { $0.id == current }) { list.append(TerminalProgram(id: current, name: name(of: current, lookup: lookup))) }
        return list
    }

    /// Every app that says it opens folders. Launch Services answers for "folder" and "directory" separately (Apple's Terminal
    /// names only "directory"), so both are asked.
    nonisolated static func folderApps() -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: UTType.folder) + NSWorkspace.shared.urlsForApplications(toOpen: UTType.directory)
    }

    /// Whether the program says it opens folders (its own list of documents). Apple's Terminal does; one that doesn't gets no
    /// folder from us, and the action says so instead of opening it somewhere else.
    nonisolated static func acceptsFolders(_ app: URL, folderApps: [URL] = folderApps()) -> Bool {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        return folderApps.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }
    }

    /// Why the program can't be used, or nil when it can.
    nonisolated static func problem(with id: String, app: URL?, acceptsFolders: Bool) -> String? {
        let name = name(of: id)
        guard app != nil else {
            return tr("\(name) isn\u{2019}t installed anymore. Choose a terminal program in Settings › General.",
                      "\(name) ist nicht mehr installiert. Wähle unter Einstellungen › Allgemein ein Terminal-Programm.")
        }
        guard acceptsFolders else {
            return tr("\(name) doesn\u{2019}t accept a starting folder, so it can\u{2019}t open in the file\u{2019}s folder. Choose another terminal program in Settings › General.",
                      "\(name) nimmt keinen Startordner an und kann deshalb nicht im Ordner der Datei öffnen. Wähle unter Einstellungen › Allgemein ein anderes Terminal-Programm.")
        }
        return nil
    }

    static func perform(_ files: [URL]) {
        let folders = folders(for: files)
        let id = AppSettings.shared.terminalApp
        let app = appURL(id)
        if let message = problem(with: id, app: app, acceptsFolders: app.map { acceptsFolders($0) } ?? false) {
            FileActions.reportFailure(title: FileAction.terminal.title, detail: name(of: id), symbol: FileAction.terminal.symbol, message: message)
            return
        }
        guard let app, !folders.isEmpty else { return }
        if asksFirst(folders: folders.count), !confirm(folders.count) { return }
        DiagnosticLog.log("terminal \(name(of: id)) for \(folders.count) folder(s)")
        for folder in folders { open(folder, with: app) }
    }

    /// One window per folder: each folder is its own request, as if it was dropped on the program's icon.
    private static func open(_ folder: URL, with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                FileActions.reportFailure(title: FileAction.terminal.title, detail: folder.lastPathComponent, symbol: FileAction.terminal.symbol,
                                          message: error.localizedDescription)
            }
        }
    }

    private static func confirm(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = tr("Open \(count) terminal windows?", "\(count) Terminal-Fenster öffnen?")
        alert.informativeText = tr("The files are in \(count) different folders. A window opens for each folder.",
                                   "Die Dateien liegen in \(count) verschiedenen Ordnern. Für jeden Ordner öffnet sich ein Fenster.")
        alert.addButton(withTitle: tr("Open \(count) Windows", "\(count) Fenster öffnen"))
        alert.addButton(withTitle: tr("Cancel", "Abbrechen"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Settings › General › "Other …": any app, starting in Applications.
    static func chooseOther() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = tr("Choose", "Auswählen")
        panel.message = tr("Choose a terminal program", "Terminal-Programm auswählen")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier ?? url.path
    }
}
