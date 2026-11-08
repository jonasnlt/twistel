import AppKit
import SwiftUI

/// The panes of Settings.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, rings, formats, privacy, helpers, overview, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return tr("General", "Allgemein")
        case .rings: return tr("Rings", "Ringe")
        case .formats: return tr("Formats", "Formate")
        case .privacy: return tr("Privacy", "Datenschutz")
        case .helpers: return tr("Helper Programs", "Zusatzprogramme")
        case .overview: return tr("Overview", "Übersicht")
        case .about: return tr("About", "Über")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .rings: return "circle.circle"
        case .formats: return "slider.horizontal.3"
        case .privacy: return "hand.raised"
        case .helpers: return "shippingbox"
        case .overview: return "tablecells"
        case .about: return "info.circle"
        }
    }

    /// The pane's height, at most what the screen leaves under the menu bar, the window's title and its tabs; the form scrolls then
    /// (Settings › General is 820 pt, more than a small laptop screen has room for at some display sizes).
    @MainActor
    var height: CGFloat {
        Self.fitted(wantedHeight, screen: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height)
    }

    /// Room for the title bar with the tabs and a little air above and below.
    static let windowChrome: CGFloat = 100

    nonisolated static func fitted(_ wanted: CGFloat, screen: CGFloat?) -> CGFloat {
        guard let screen, screen > 0 else { return wanted }
        return min(wanted, max(300, (screen - windowChrome).rounded(.down)))
    }

    var wantedHeight: CGFloat {
        switch self {
        case .general: return 820
        case .rings: return 580
        case .formats: return 470
        case .privacy: return 300
        case .helpers: return 580
        case .overview: return 560
        case .about: return 330
        }
    }
}

@MainActor
final class SettingsTabModel: ObservableObject {
    @Published var tab: SettingsTab = SettingsTab(rawValue: AppSettings.shared.settingsTab) ?? .general
}

/// One pane, as the window shows it (also drawn by the test access).
struct SettingsView: View {
    @ObservedObject var model: SettingsTabModel

    static let width: CGFloat = 620
    static var height: CGFloat { 600 }

    var body: some View {
        SettingsPane(tab: model.tab)
    }
}

struct SettingsPane: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralPane()
            case .rings: RingsPane()
            case .formats: FormatsPane()
            case .privacy: PrivacyPane()
            case .helpers: HelpersPane()
            case .overview: OverviewPane()
            case .about: AboutPane()
            }
        }
        .frame(width: SettingsView.width, height: tab.height)
    }
}

// MARK: General

struct GeneralPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(tr("Language", "Sprache"), selection: $settings.languageChoice) {
                    ForEach(LanguageChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle(tr("Open \(AppIdentity.name) at login", "\(AppIdentity.name) beim Anmelden öffnen"), isOn: $settings.launchAtLogin)
            } footer: {
                Text(tr("Windows that are open keep their language until they are opened again.", "Offene Fenster wechseln die Sprache, wenn sie neu geöffnet werden."))
            }
            Section {
                Toggle(tr("Sounds", "Sounds"), isOn: $settings.soundsEnabled)
                Toggle(tr("Haptics", "Haptik"), isOn: $settings.hapticsEnabled)
            } header: {
                Text(tr("Sounds and Haptics", "Sounds und Haptik"))
            } footer: {
                Text(tr("Sounds when work is done, fails or is canceled, and a quiet tick when the chosen ring item changes. The volume follows the Mac\u{2019}s volume for sound effects. Haptics: a fine tick on a Force Touch trackpad.",
                        "Töne, wenn etwas fertig ist, fehlschlägt oder abgebrochen wird, und ein leiser Ton beim Wechsel im Ring. Die Lautstärke folgt der Lautstärke für Toneffekte des Macs. Haptik: ein feines Tippen auf einem Force-Touch-Trackpad."))
            }
            RingKeysSection()
            Section(tr("Results", "Ergebnisse")) {
                Picker(tr("Save results", "Ergebnisse speichern"), selection: $settings.outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                Toggle(tr("Show each result in Finder", "Jedes Ergebnis im Finder zeigen"), isOn: $settings.revealInFinder)
            }
            TerminalSection()
        }
        .formStyle(.grouped)
    }
}

/// The program the actions ring's "Terminal" opens: Apple's Terminal, other installed ones, or any app ("Other …").
struct TerminalSection: View {
    @EnvironmentObject private var settings: AppSettings
    private static let other = "other"

    var body: some View {
        let choices = TerminalAction.choices(current: settings.terminalApp)
        let app = TerminalAction.appURL(settings.terminalApp)
        let problem = TerminalAction.problem(with: settings.terminalApp, app: app, acceptsFolders: app.map { TerminalAction.acceptsFolders($0) } ?? false)
        Section {
            Picker(tr("Terminal program", "Terminal-Programm"), selection: selection) {
                ForEach(choices) { Text($0.name).tag($0.id) }
                Divider()
                Text(tr("Other …", "Andere …")).tag(Self.other)
            }
        } header: {
            Text(tr("Actions", "Aktionen"))
        } footer: {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                Text(tr("\u{201C}Terminal\u{201D} in the actions ring opens a window in the folder of the file.",
                        "\u{201E}Terminal\u{201C} im Aktionen-Ring öffnet ein Fenster im Ordner der Datei."))
            }
        }
    }

    private var selection: Binding<String> {
        Binding(get: { settings.terminalApp }, set: { id in
            if id == Self.other {
                if let chosen = TerminalAction.chooseOther() { settings.terminalApp = chosen }
            } else {
                settings.terminalApp = id
            }
        })
    }
}

// MARK: Rings

/// Favourites per ring and kind of file: on/off and the order, by dragging (or with the row's menu, without a mouse).
struct RingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var ring: RingKind = .convert
    @State private var kind: FileKind = .image

    private var effectiveKind: FileKind { ring == .actions ? .any : kind }
    private var list: FavoriteList { settings.favoriteList(ring, effectiveKind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(tr("Ring", "Ring"), selection: $ring) {
                    ForEach(RingKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
                Spacer()
                if ring != .actions {
                    Picker(tr("Files", "Dateien"), selection: $kind) {
                        ForEach(FileKind.kinds(for: ring)) { Text($0.title).tag($0) }
                    }
                    .frame(width: 220)
                }
            }
            List {
                ForEach(Array(list.order.enumerated()), id: \.element) { index, key in
                    if let id = RingEntryID(key: key) {
                        row(id, key: key, index: index)
                    }
                }
                .onMove { from, to in
                    var changed = list
                    changed.order.move(fromOffsets: from, toOffset: to)
                    settings.setFavoriteList(changed, ring, effectiveKind)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            HStack(alignment: .top) {
                Text(tr("The ring shows the switched-on items in this order, up to \(settings.ringItemCount - 1) and \u{201C}More …\u{201D} (places: Settings › General). Drag to change the order.",
                        "Der Ring zeigt die eingeschalteten Einträge in dieser Reihenfolge, bis zu \(settings.ringItemCount - 1) und \u{201E}Mehr …\u{201C} (Plätze: Einstellungen › Allgemein). Ziehen ändert die Reihenfolge."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(tr("Reset", "Zurücksetzen")) { settings.resetFavorites(ring, effectiveKind) }
            }
        }
        .padding(20)
        .onChange(of: ring) { _, new in
            if new != .actions, !FileKind.kinds(for: new).contains(kind) { kind = FileKind.kinds(for: new)[0] }
        }
    }

    private func row(_ id: RingEntryID, key: String, index: Int) -> some View {
        let entry = RingCatalog.entry(id, for: effectiveKind.formats)
        let place = list.favorites.firstIndex(of: id).map { $0 + 1 }
        let isOn = Binding(get: { list.enabled.contains(key) }, set: { on in
            var changed = list
            if on { changed.enabled.insert(key) } else { changed.enabled.remove(key) }
            settings.setFavoriteList(changed, ring, effectiveKind)
        })
        return HStack(spacing: 10) {
            Toggle(isOn: isOn) {
                Label {
                    HStack(spacing: 6) {
                        Text(entry.title)
                        Text(entry.shortLabel).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: entry.symbol)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let place {
                Text(place < settings.ringItemCount ? tr("Place \(place)", "Platz \(place)") : tr("More …", "Mehr …"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button(tr("Move Up", "Nach oben")) { move(index, by: -1) }.disabled(index == 0)
            Button(tr("Move Down", "Nach unten")) { move(index, by: 1) }.disabled(index == list.order.count - 1)
        }
        .accessibilityAction(named: tr("Move up", "Nach oben")) { move(index, by: -1) }
        .accessibilityAction(named: tr("Move down", "Nach unten")) { move(index, by: 1) }
    }

    private func move(_ index: Int, by step: Int) {
        let target = index + step
        guard list.order.indices.contains(index), list.order.indices.contains(target) else { return }
        var changed = list
        changed.order.swapAt(index, target)
        settings.setFavoriteList(changed, ring, effectiveKind)
    }
}

// MARK: Formats

struct FormatsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section(tr("Pictures", "Bilder")) {
                LabeledContent(tr("Quality of JPEG, HEIC, WebP", "Qualität von JPEG, HEIC, WebP")) {
                    HStack {
                        Slider(value: $settings.jpegQuality, in: 0.3...1.0).frame(width: 180)
                            .accessibilityLabel(tr("Quality", "Qualität"))
                        Text("\(Int((settings.jpegQuality * 100).rounded())) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Picker(tr("Pictures to PDF: page", "Bilder zu PDF: Seite"), selection: $settings.imagesToPDFLayout) {
                    ForEach(PDFRenderer.ImagePageLayout.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Picker(tr("Strength", "Stärke"), selection: $settings.compressionPreset) {
                    ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(tr("Longest side of pictures", "Längste Seite von Bildern")) {
                    HStack {
                        TextField("", value: $settings.compressionResizeLongEdge, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .accessibilityLabel(tr("Longest side in pixels, 0 keeps the size", "Längste Seite in Pixeln, 0 behält die Größe"))
                        Text(tr("px (0 = keep)", "px (0 = behalten)")).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(tr("Compress", "Verkleinern"))
            } footer: {
                Text(tr("Start values of the Compress window; it remembers what was used last.", "Startwerte des Fensters Verkleinern; es merkt sich die zuletzt benutzten."))
            }
            Section(tr("Sound", "Ton")) {
                Picker(tr("MP3 bit rate", "MP3-Bitrate"), selection: $settings.mp3Bitrate) {
                    ForEach([128_000, 192_000, 256_000, 320_000], id: \.self) { Text("\($0 / 1000) kbit/s").tag($0) }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button(tr("Reset", "Zurücksetzen")) { settings.resetFormats() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy

struct PrivacyPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle(tr("Remove the place from photos and videos", "Ortsdaten aus Fotos und Videos entfernen"), isOn: $settings.removeLocation)
                Toggle(tr("Remove all metadata (camera, date, place …)", "Alle Metadaten entfernen (Kamera, Datum, Ort …)"), isOn: $settings.removeAllMetadata)
            } footer: {
                Text(tr("For every conversion and tool that saves pictures, videos or sound. Originals are never changed. \u{201C}Edit metadata\u{201D} does what you choose in its window.",
                        "Für alle Umwandlungen und Werkzeuge, die Bilder, Videos oder Ton speichern. Originale werden nie verändert. \u{201E}Metadaten bearbeiten\u{201C} macht, was du in seinem Fenster wählst."))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Helper programs

struct HelpersPane: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var found: [HelperProgram: String] = [:]
    @State private var checked = false

    var body: some View {
        Form {
            Section {
                ForEach(HelperProgram.allCases) { program in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: found[program] != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(found[program] != nil ? Theme.accentForeground : Color.secondary)
                            .accessibilityLabel(found[program] != nil ? tr("Installed", "Installiert") : tr("Not installed", "Nicht installiert"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(program.name).font(.headline)
                            Text(program.purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if let path = found[program] {
                                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            } else if checked {
                                HStack {
                                    Text(program.installCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    Button(tr("Copy", "Kopieren")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(program.installCommand, forType: .string)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text(tr("Separate programs some work needs", "Eigenständige Programme, die manche Arbeit braucht"))
            } footer: {
                Text(tr("They are installed with Homebrew in Terminal and never become part of \(AppIdentity.name). Without one, its items in the rings are gray.",
                        "Sie werden mit Homebrew im Terminal installiert und nie Teil von \(AppIdentity.name). Fehlt eines, sind seine Einträge in den Ringen grau."))
            }
            Section(tr("FFmpeg location (optional)", "Ort von FFmpeg (optional)")) {
                HStack {
                    TextField(tr("Found automatically", "Wird automatisch gefunden"), text: $settings.ffmpegPath)
                        .textFieldStyle(.roundedBorder)
                    Button(tr("Choose …", "Wählen …")) { chooseFFmpeg() }
                }
                HStack {
                    Spacer()
                    Button(tr("Check Again", "Erneut prüfen")) { Task { await check() } }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: settings.ffmpegPath) { await check() }
    }

    private func check() async {
        let result = await Task.detached { Dictionary(uniqueKeysWithValues: HelperProgram.allCases.compactMap { p in p.locate().map { (p, $0) } }) }.value
        found = result
        checked = true
        HelperPrograms.refreshIfOld(maxAge: 0)
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { settings.ffmpegPath = url.path }
    }
}

// MARK: Overview

/// Which format can become which, per kind of file, with a search field.
struct OverviewPane: View {
    @State private var search = ""

    private func rows(_ kind: FileKind) -> [(FileFormat, [FileFormat])] {
        kind.formats.map { ($0, ConversionMatrix.targets(for: $0)) }.filter { source, targets in
            guard !targets.isEmpty else { return false }
            let text = search.trimmingCharacters(in: .whitespaces).lowercased()
            guard !text.isEmpty else { return true }
            return ([source] + targets).contains { RingWords.formatLabel($0).lowercased().contains(text) }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField(tr("Search a format, e.g. HEIC", "Format suchen, z. B. HEIC"), text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(FileKind.kinds(for: .convert)) { kind in
                    let found = rows(kind)
                    if !found.isEmpty {
                        Section(kind.title) {
                            ForEach(found, id: \.0) { source, targets in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(RingWords.formatLabel(source)).font(.body.weight(.semibold)).frame(width: 90, alignment: .leading)
                                    Text(targets.map(RingWords.formatLabel).joined(separator: " · "))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            Text(tr("\(ConversionMatrix.totalConversions) conversions and \(ToolID.total) tools", "\(ConversionMatrix.totalConversions) Umwandlungen und \(ToolID.total) Werkzeuge"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: About

struct AboutPane: View {
    static var licenceText: String {
        AppIdentity.copyright + ". " + tr(
            "Free software under the GPL-3.0 license. Contains code from Satsuma by plyght (MIT License). Helper programs are separate programs with their own licenses.",
            "Freie Software unter der Lizenz GPL-3.0. Enthält Code aus Satsuma von plyght (MIT-Lizenz). Zusatzprogramme sind eigenständige Programme mit eigenen Lizenzen.")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(AppIdentity.name).font(.title2.weight(.semibold))
            Text("Version \(AppIdentity.versionText)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(tr("Converts and edits files on this Mac. Nothing is uploaded.", "Wandelt und bearbeitet Dateien auf diesem Mac. Nichts wird hochgeladen."))
                .multilineTextAlignment(.center)
            Text(Self.licenceText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            // Opens in the browser; twistel itself never goes online.
            Link("github.com/jonasnlt/twistel", destination: AppIdentity.repositoryURL)
                .font(.caption)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Window

/// Apple's settings window: a toolbar with one button per pane that always shows the chosen pane, the window titled after it, no zoom,
/// and the last pane opened again.
@MainActor
final class SettingsWindowController: NSTabViewController {
    static func makeWindow() -> NSWindow {
        let controller = SettingsWindowController()
        controller.tabStyle = .toolbar
        controller.canPropagateSelectedChildViewControllerTitle = true
        for tab in SettingsTab.allCases {
            let hosting = NSHostingController(rootView: SettingsPane(tab: tab).environmentObject(AppSettings.shared))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.identifier = tab.rawValue
            controller.addTabViewItem(item)
        }
        controller.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex { $0.rawValue == AppSettings.shared.settingsTab } ?? 0
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        // The window lives as long as the app: its tabs and title follow a change of language at once.
        followLanguage(controller) { [weak controller] in controller?.applyLanguage() }
        return window
    }

    /// Tabs, their pictures' descriptions and the window title in the app's language now.
    func applyLanguage() {
        for item in tabViewItems {
            guard let id = item.identifier as? String, let tab = SettingsTab(rawValue: id) else { continue }
            item.label = tab.title
            item.viewController?.title = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        }
        view.window?.title = tabViewItems[safe: selectedTabViewItemIndex]?.label ?? ""
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String { AppSettings.shared.settingsTab = id }
        view.window?.title = tabViewItem?.label ?? ""
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
