import Foundation

/// The language of the app's texts and of the names of its results. A Mac set to German starts in German, any other in English;
/// Settings › General switches it.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Its own name, as language pickers show it.
    var name: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    /// The language a new installation starts with: German when the Mac's first preferred language is German.
    static func startingLanguage(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard let first = preferred.first?.lowercased() else { return .english }
        return first == "de" || first.hasPrefix("de-") || first.hasPrefix("de_") ? .german : .english
    }

    var locale: Locale { Locale(identifier: self == .german ? "de_DE" : "en_US") }

    /// The one the app runs in now. Kept here (not only in `AppSettings`) so work in the background can name its results
    /// without reaching for the settings object.
    static var current: AppLanguage {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: AppLanguage = startingLanguage()
}

/// What Settings › General offers: follow the Mac (the default), or always German or English. A choice of German or English is kept;
/// with Automatic the app follows the Mac's first preferred language at every start.
enum LanguageChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case german = "de"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return tr("Automatic (System Language)", "Automatisch (Systemsprache)")
        case .german: return AppLanguage.german.name
        case .english: return AppLanguage.english.name
        }
    }

    /// The language this choice means on a Mac with these preferred languages.
    func resolved(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .automatic: return AppLanguage.startingLanguage(preferred: preferred)
        case .german: return .german
        case .english: return .english
        }
    }

    /// The stored value: "de" or "en" for a choice, nothing for Automatic (so a value saved before stays a choice).
    init(stored: String?) {
        self = stored.flatMap { LanguageChoice(rawValue: $0) }.flatMap { $0 == .automatic ? nil : $0 } ?? .automatic
    }
}

extension Notification.Name {
    /// Posted on the main thread when the app's language changed, so texts that AppKit keeps (window titles, tabs, tooltips) follow.
    static let appLanguageChanged = Notification.Name("TwistelAppLanguageChanged")
}

extension AppLanguage {
    /// Tells every `followLanguage` text to set itself again.
    static func announceChange() {
        NotificationCenter.default.post(name: .appLanguageChanged, object: nil)
    }
}

/// Runs `update` whenever the app's language changes, for as long as `owner` lives (a window, a button, a controller). For texts that
/// are set once in AppKit and would otherwise keep the language they were made in.
func followLanguage(_ owner: AnyObject, _ update: @escaping @MainActor () -> Void) {
    let follower = LanguageFollower(update: update)
    objc_setAssociatedObject(owner, Unmanaged.passUnretained(follower).toOpaque(), follower, .OBJC_ASSOCIATION_RETAIN)
}

private final class LanguageFollower: NSObject {
    private var token: NSObjectProtocol?

    init(update: @escaping @MainActor () -> Void) {
        super.init()
        token = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// A text in both languages, picked by `AppLanguage.current`. Every text the app shows is written this way, English first.
func tr(_ english: String, _ german: String) -> String {
    AppLanguage.current == .german ? german : english
}
