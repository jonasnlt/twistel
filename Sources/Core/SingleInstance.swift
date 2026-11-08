import AppKit
import Foundation

/// Only one copy of twistel runs, and never beside twistel dev: two apps would each open a ring for the same drag. Both
/// builds take one lock on a file in the user's temporary folder and write their name into it; a second start ends at once. The system
/// lets go of the lock when that instance ends, also after a crash, so a stale lock can't keep the app from starting.
/// The test access (debug builds) doesn't take the lock: it opens no rings, runs beside the app and ends itself (`Watchdog`).
enum SingleInstance {
    static var lockURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("io.github.jonasnlt.twistel.instance.lock")
    }

    enum Claim: Equatable {
        /// This is the only instance; the descriptor stays open (and the lock held) for the life of the process.
        case first(Int32)
        /// Another instance holds the lock: its name ("twistel" or "twistel dev").
        case second(running: String)
        /// The lock file could not be opened: the app starts (better than not starting at all) and says so in its log.
        case unknown
    }

    static func claim(at url: URL = lockURL, name: String = AppIdentity.name) -> Claim {
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return .unknown }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            let holder = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .second(running: [AppIdentity.releaseName, AppIdentity.debugName].contains(holder) ? holder : AppIdentity.releaseName)
        }
        let text = Array(name.utf8)
        ftruncate(descriptor, 0)
        _ = text.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, text.count, 0) }
        return .first(descriptor)
    }

    /// Whether another process holds the lock on `url` (a file that is not there is held by no one).
    static func isHeld(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// What the second app says before it quits, when the first is the other build.
    static func message(running: String, starting: String = AppIdentity.name) -> (title: String, text: String) {
        (tr("The app \(running) is already running", "Die App \(running) läuft schon"),
         tr("Only one of \(AppIdentity.releaseName) and \(AppIdentity.debugName) can run, so that a drag opens one ring. That's why \(starting) quits now. Quit \(running) in the menu bar first to use \(starting).",
            "Es läuft immer nur \(AppIdentity.releaseName) oder \(AppIdentity.debugName), damit beim Ziehen nur ein Ring erscheint. Deshalb wird \(starting) jetzt beendet. Um \(starting) zu verwenden, beende zuerst \(running) in der Menüleiste."))
    }

    /// Shows `message` for at most 15 seconds (an app started at login should not wait for a click for ever).
    @MainActor
    static func tellAndQuit(running: String) -> Never {
        let message = message(running: running)
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.text
        alert.addButton(withTitle: tr("OK", "OK"))
        NSApp.activate()
        let timer = Timer(timeInterval: 15, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        alert.runModal()
        exit(0)
    }
}
