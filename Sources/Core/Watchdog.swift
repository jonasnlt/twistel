import Foundation

/// Ends a test process that runs too long, even when its main thread hangs: no test instance may stay behind (a test
/// left a window over the whole screen while it kept working). Used by the test program and the test access, never by the app.
enum Watchdog {
    private(set) static var deadline: Date?

    static func start(seconds: TimeInterval, what: String) {
        deadline = Date().addingTimeInterval(seconds)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            FileHandle.standardError.write(Data("\(what): Zeitgrenze von \(Int(seconds)) s erreicht, beendet sich selbst.\n".utf8))
            exit(3)
        }
    }
}
