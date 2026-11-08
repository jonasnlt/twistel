import AppKit
import Foundation
import Combine
import ServiceManagement

enum CompressionPreset: String, CaseIterable, Identifiable {
    case balanced
    case strong

    var id: String { rawValue }

    var title: String { self == .balanced ? tr("Balanced", "Ausgewogen") : tr("Strong", "Stark") }

    var imageQuality: Double { self == .balanced ? 0.72 : 0.5 }
    var videoScale: Double { self == .balanced ? 1.0 : 0.75 }
    var videoBitrateFactor: Double { self == .balanced ? 0.6 : 0.35 }
    var audioBitrate: Int { self == .balanced ? 128_000 : 64_000 }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal
    case downloads
    case desktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .besideOriginal: return tr("Next to the original", "Neben dem Original")
        case .downloads: return "Downloads"
        case .desktop: return tr("Desktop", "Schreibtisch")
        }
    }

    func directory(for source: URL) -> URL {
        switch self {
        case .besideOriginal: return source.deletingLastPathComponent()
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .desktop: return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
    }
}

/// Where settings are kept: UserDefaults in the app; tests use one in memory.
protocol SettingsStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsStore {}

final class AppSettings: ObservableObject {
    /// Replaced by one with an in-memory store in tests, so they never write a preferences file.
    static var shared = AppSettings()

    private let defaults: SettingsStore

    @Published var compressionPreset: CompressionPreset {
        didSet { defaults.set(compressionPreset.rawValue, forKey: "compressionPreset") }
    }

    /// 0 keeps the size; the field in Settings takes up to 20,000 (more is brought to that, less than 0 to 0).
    @Published var compressionResizeLongEdge: Int {
        didSet {
            let kept = min(max(compressionResizeLongEdge, 0), Self.largestResizeLongEdge)
            if kept != compressionResizeLongEdge { compressionResizeLongEdge = kept; return }
            defaults.set(compressionResizeLongEdge, forKey: "compressionResizeLongEdge")
        }
    }
    static let largestResizeLongEdge = 20_000

    @Published var outputLocation: OutputLocation {
        didSet { defaults.set(outputLocation.rawValue, forKey: "outputLocation") }
    }

    @Published var revealInFinder: Bool {
        didSet { defaults.set(revealInFinder, forKey: "revealInFinder") }
    }

    @Published var ffmpegPath: String {
        didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    @Published var jpegQuality: Double {
        didSet { defaults.set(jpegQuality, forKey: "jpegQuality") }
    }

    /// Page layout for images converted to PDF in the ring; preselected in the Create a PDF window.
    @Published var imagesToPDFLayout: PDFRenderer.ImagePageLayout {
        didSet { defaults.set(imagesToPDFLayout.rawValue, forKey: "imagesToPDFLayout") }
    }

    /// The language last chosen in the Transcribe window.
    @Published var transcriptionLanguage: Transcriber.Language {
        didSet { defaults.set(transcriptionLanguage.rawValue, forKey: "transcriptionLanguage") }
    }


    /// What Settings › General shows: Automatic (the Mac's language, the default), Deutsch or English. Stored as "de"/"en"; Automatic
    /// stores nothing, so a choice saved earlier is kept.
    @Published var languageChoice: LanguageChoice {
        didSet {
            defaults.set(languageChoice == .automatic ? nil : languageChoice.rawValue, forKey: "language")
            language = languageChoice.resolved(preferred: preferredLanguages)
        }
    }

    /// The app's language now (texts and names of results), from `languageChoice`.
    @Published var language: AppLanguage {
        didSet {
            // Only the app's own settings decide the language (tests make settings objects of their own).
            guard self === AppSettings.shared, oldValue != language || AppLanguage.current != language else { return }
            AppLanguage.current = language
            AppLanguage.announceChange()
        }
    }

    /// The Mac's preferred languages as read at the start: with Automatic, a change of the Mac's language is followed at the next start.
    private let preferredLanguages: [String]

    /// Which keys open which ring. A choice that would give two rings the same keys is not taken.
    @Published var ringKeys: RingKeys {
        didSet {
            guard ringKeys.isValid else { ringKeys = oldValue; return }
            defaults.set(try? JSONEncoder().encode(ringKeys), forKey: "ringKeys")
        }
    }

    /// Places in each ring (6, 8 or 10), "More …" included.
    @Published var ringItemCount: Int {
        didSet { defaults.set(ringItemCount, forKey: "ringItemCount") }
    }

    /// Favourites per ring and kind of file, keyed "ring.kind"; missing ones are the defaults (`RingCatalog.defaultList`).
    @Published private(set) var favorites: [String: FavoriteList] {
        didSet { defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites") }
    }

    func favoriteList(_ ring: RingKind, _ kind: FileKind) -> FavoriteList {
        (favorites["\(ring.rawValue).\(kind.rawValue)"] ?? RingCatalog.defaultList(ring, for: kind, count: ringItemCount)).completed(with: RingCatalog.offered(ring, for: kind))
    }

    func setFavoriteList(_ list: FavoriteList, _ ring: RingKind, _ kind: FileKind) {
        favorites["\(ring.rawValue).\(kind.rawValue)"] = list
    }

    func resetFavorites(_ ring: RingKind, _ kind: FileKind) {
        favorites["\(ring.rawValue).\(kind.rawValue)"] = nil
    }

    /// Settings › General: the app's sounds (done, error, cancelled, moving over the ring) and the trackpad's tick in the ring.
    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }

    /// The terminal program the "Terminal" action opens: a bundle identifier, or the path of an app chosen with "Other …".
    @Published var terminalApp: String {
        didSet { defaults.set(terminalApp, forKey: "terminalApp") }
    }

    /// Settings › Privacy (`Privacy.Rules`): leave out where photos and videos were taken (on), or all metadata (off).
    @Published var removeLocation: Bool {
        didSet { defaults.set(removeLocation, forKey: "removeLocation"); applyPrivacy() }
    }

    @Published var removeAllMetadata: Bool {
        didSet { defaults.set(removeAllMetadata, forKey: "removeAllMetadata"); applyPrivacy() }
    }

    /// Settings › Formats: bit rate of MP3 files made by converting.
    @Published var mp3Bitrate: Int {
        didSet { defaults.set(mp3Bitrate, forKey: "mp3Bitrate") }
    }

    /// The introduction was shown once (at the first start); after that it comes only from the menu bar.
    @Published var introductionShown: Bool {
        didSet { defaults.set(introductionShown, forKey: "introductionShown") }
    }

    /// The pane Settings opened with last time.
    @Published var settingsTab: String {
        didSet { defaults.set(settingsTab, forKey: "settingsTab") }
    }

    /// Only the app's own settings decide (tests make settings objects of their own).
    func applyPrivacy() {
        guard self === AppSettings.shared else { return }
        Privacy.current = Privacy.Rules(removeLocation: removeLocation, removeAllMetadata: removeAllMetadata)
    }

    /// Settings › Formats › Reset: the values a new installation starts with.
    func resetFormats() {
        jpegQuality = 0.9
        imagesToPDFLayout = .standard
        compressionPreset = .balanced
        compressionResizeLongEdge = 0
        mp3Bitrate = 192_000
    }

    /// The last values of each tool's window (`ToolMemory`), kept as "toolMemory.<tool>".
    func toolMemory(_ tool: ToolID) -> [String: String] {
        defaults.object(forKey: "toolMemory.\(tool.rawValue)") as? [String: String] ?? [:]
    }

    func setToolMemory(_ values: [String: String], for tool: ToolID) {
        defaults.set(values.isEmpty ? nil : values, forKey: "toolMemory.\(tool.rawValue)")
    }

    init(defaults: SettingsStore = UserDefaults.standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        languageChoice = LanguageChoice(stored: defaults.object(forKey: "language") as? String)
        language = LanguageChoice(stored: defaults.object(forKey: "language") as? String).resolved(preferred: preferredLanguages)
        ringKeys = (defaults.object(forKey: "ringKeys") as? Data).flatMap { try? JSONDecoder().decode(RingKeys.self, from: $0) }.flatMap { $0.isValid ? $0 : nil } ?? .standard
        ringItemCount = (defaults.object(forKey: "ringItemCount") as? Int).flatMap { RingBuilder.countChoices.contains($0) ? $0 : nil } ?? RingBuilder.standardCount
        removeLocation = defaults.object(forKey: "removeLocation") as? Bool ?? true
        removeAllMetadata = defaults.object(forKey: "removeAllMetadata") as? Bool ?? false
        // Numbers within what Settings offers: another app can write anything here (`defaults write`).
        mp3Bitrate = (defaults.object(forKey: "mp3Bitrate") as? Int).flatMap { [128_000, 192_000, 256_000, 320_000].contains($0) ? $0 : nil } ?? 192_000
        settingsTab = defaults.object(forKey: "settingsTab") as? String ?? "general"
        introductionShown = defaults.object(forKey: "introductionShown") as? Bool ?? false
        var savedFavorites = (defaults.object(forKey: "favorites") as? Data).flatMap { try? JSONDecoder().decode([String: FavoriteList].self, from: $0) } ?? [:]
        // An actions list still exactly as it came (before "Float" and "Terminal") takes the new start values; changed lists stay.
        if savedFavorites["actions.any"] == RingCatalog.oldActionsDefault {
            savedFavorites["actions.any"] = nil
            defaults.set(try? JSONEncoder().encode(savedFavorites), forKey: "favorites")
        }
        favorites = savedFavorites
        soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: "hapticsEnabled") as? Bool ?? true
        terminalApp = (defaults.object(forKey: "terminalApp") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? TerminalAction.appleTerminal
        compressionPreset = CompressionPreset(rawValue: (defaults.object(forKey: "compressionPreset") as? String) ?? "") ?? .balanced
        compressionResizeLongEdge = (defaults.object(forKey: "compressionResizeLongEdge") as? Int).map { min(max($0, 0), Self.largestResizeLongEdge) } ?? 0
        outputLocation = OutputLocation(rawValue: (defaults.object(forKey: "outputLocation") as? String) ?? "") ?? .besideOriginal
        // The result card has "Show in Finder"; opening a Finder window after every result is a choice in Settings.
        revealInFinder = defaults.object(forKey: "revealInFinder") as? Bool ?? false
        ffmpegPath = (defaults.object(forKey: "ffmpegPath") as? String) ?? ""
        jpegQuality = (defaults.object(forKey: "jpegQuality") as? Double).flatMap { $0.isFinite && (0.3...1).contains($0) ? $0 : nil } ?? 0.9
        imagesToPDFLayout = PDFRenderer.ImagePageLayout(rawValue: (defaults.object(forKey: "imagesToPDFLayout") as? String) ?? "") ?? .standard
        transcriptionLanguage = Transcriber.Language(rawValue: (defaults.object(forKey: "transcriptionLanguage") as? String) ?? "") ?? .german
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } else {
            launchAtLogin = false
        }
    }


    private func applyLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }
}
