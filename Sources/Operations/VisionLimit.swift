import CoreGraphics
import Foundation

/// Apple Vision sometimes never answers: its task waits for ever, and cancelling does not reach it (about once in a
/// hundred calls with language correction). So every call gets a time limit. After it the call is left behind and tried once more;
/// if that gets no answer either, `NoAnswer` goes to whoever can do without: a page is skipped and reported, an extra reading left out.
enum VisionLimit {
    struct NoAnswer: LocalizedError {
        var errorDescription: String? { tr("Apple's text and image recognition did not answer. Please try again, or restart the Mac if it keeps happening.", "Apples Text- und Bilderkennung hat nicht geantwortet. Bitte versuch es noch einmal oder starte den Mac neu, wenn es wieder passiert.") }
    }

    /// The longest normal call measured was far below this, also for a picture of 100 megapixels.
    nonisolated(unsafe) static var seconds: Double = 60

    #if DEBUG
    /// Tests and the test access: calls on pictures for which this says yes hang like Vision does, not even a cancel ends them.
    nonisolated(unsafe) static var simulatedHang: (@Sendable (CGImage?) -> Bool)?
    private nonisolated(unsafe) static var hanging: [CheckedContinuation<Void, Never>] = []
    private static let hangingLock = NSLock()

    private static func hangIfAsked(_ image: CGImage?) async {
        guard simulatedHang?(image) == true else { return }
        await withCheckedContinuation { continuation in
            hangingLock.withLock { hanging.append(continuation) }
        }
    }
    #endif

    /// `work`, with its limit and one more try. `image` is only for `simulatedHang`.
    static func call<T>(on image: CGImage? = nil, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await attempt(on: image, work)
        } catch is NoAnswer {
            DiagnosticLog.log("Vision did not answer within \(seconds) s, trying once more")
            return try await attempt(on: image, work)
        }
    }

    /// For what can be done without: nil when Vision did not answer.
    static func optional<T>(_ work: () async throws -> T) async throws -> T? {
        do {
            return try await work()
        } catch is NoAnswer {
            DiagnosticLog.log("Vision did not answer, an extra step is left out")
            return nil
        }
    }

    /// Vision's older interface blocks its thread: the same limit, waiting on a thread of its own. Not on the main thread.
    static func blocking<T>(on image: CGImage? = nil, _ work: @escaping @Sendable () throws -> T) throws -> T {
        for _ in 0..<2 {
            let done = DispatchSemaphore(value: 0)
            let result = Once<Result<T, Error>>()
            DispatchQueue.global(qos: .userInitiated).async {
                #if DEBUG
                if simulatedHang?(image) == true { return }
                #endif
                result.set(Result { try work() })
                done.signal()
            }
            if done.wait(timeout: .now() + seconds) == .success, let value = result.value { return try value.get() }
            DiagnosticLog.log("Vision did not answer within \(seconds) s")
        }
        throw NoAnswer()
    }

    /// Waits for `work` or the limit, whichever comes first.
    private static func attempt<T>(on image: CGImage?, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        defer { JobNotes.beat() }
        return try await TimeLimit.attempt(seconds: seconds, giveUp: NoAnswer()) {
            #if DEBUG
            await hangIfAsked(image)
            #endif
            return try await work()
        }
    }

    private final class Once<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? { lock.withLock { stored } }
        func set(_ value: Value) { lock.withLock { stored = value } }
    }

    /// What the result says about pages left out.
    static func skippedPages(_ pages: [Int]) -> String {
        let list = pages.map(String.init).joined(separator: ", ")
        return tr((pages.count == 1 ? "Page \(list) was skipped" : "Pages \(list) were skipped") + ": Apple's text recognition did not answer.",
                  (pages.count == 1 ? "Seite \(list) wurde übersprungen" : "Seiten \(list) wurden übersprungen") + ": Apples Texterkennung hat nicht geantwortet.")
    }
}

/// Something the person should know about a finished job, such as a page left out. The job's work adds it from wherever it is; a
/// conversion cannot report it any other way. Tests run without a job: then it only goes to the log.
final class JobNotes: @unchecked Sendable {
    @TaskLocal static var current: JobNotes?
    private let lock = NSLock()
    private var notes: [String] = []
    private var lastSign = Date()

    var all: [String] { lock.withLock { notes } }

    /// A sign of life from the job's work, for `JobWatch`.
    func beat() { lock.withLock { lastSign = Date() } }
    static func beat() { current?.beat() }

    /// Seconds since the last sign of life.
    var silence: Double { lock.withLock { Date().timeIntervalSince(lastSign) } }

    static func add(_ note: String) {
        DiagnosticLog.log("note: \(note)")
        current?.lock.withLock { current?.notes.append(note) }
    }
}
