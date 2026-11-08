import Foundation

/// Apple's frameworks sometimes never answer, and cancelling does not reach them. So whoever waits for one waits with a limit: the call is
/// left behind (it cannot be ended from outside), the caller goes on. Separate programs have their limit in `Shell`.
enum TimeLimit {
    struct Exceeded: LocalizedError {
        let what: String
        let seconds: Double
        var errorDescription: String? {
            tr("\(what) did not answer within \(ShellTimeout.readable(seconds)). The file may be damaged or still downloading from iCloud. Please try again, or restart the Mac if it keeps happening.",
               "\(what) hat nicht innerhalb von \(ShellTimeout.readable(seconds)) geantwortet. Die Datei ist vielleicht beschädigt oder wird noch aus iCloud geladen. Versuche es erneut oder starte den Mac neu, wenn das öfter passiert.")
        }
    }

    /// `work`, or `Exceeded` after `seconds`. Cancelling ends the wait at once.
    static func call<T>(seconds: Double, what: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await attempt(seconds: seconds, giveUp: Exceeded(what: what, seconds: seconds), work)
    }

    /// `work`, or nil after `seconds`, for what can be done without.
    static func optional<T>(seconds: Double, what: String, _ work: @escaping @Sendable () async throws -> T?) async -> T? {
        do {
            return try await call(seconds: seconds, what: what, work)
        } catch {
            if error is Exceeded { DiagnosticLog.log("\(what) did not answer within \(seconds) s") }
            return nil
        }
    }

    /// Waits for `work` or the limit, whichever comes first. The work runs on its own: a task group would wait for it for ever.
    static func attempt<T>(seconds: Double, giveUp: Error, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let answer = Answer<T>()
        let worker = Task.detached {
            do {
                answer.finish(.success(try await work()))
            } catch {
                answer.finish(.failure(error))
            }
        }
        let timer = DispatchWorkItem {
            answer.finish(.failure(giveUp))
            worker.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await answer.value()
        } onCancel: {
            answer.finish(.failure(CancellationError()))
            worker.cancel()
        }
    }

    /// The first result wins and goes to the waiting caller, whichever of the two comes first.
    final class Answer<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?
        private var waiting: CheckedContinuation<T, Error>?
        private var delivered = false

        func value() async throws -> T {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                waiting = continuation
                lock.unlock()
                deliver()
            }
        }

        func finish(_ value: Result<T, Error>) {
            lock.lock()
            if result == nil { result = value }
            lock.unlock()
            deliver()
        }

        private func deliver() {
            lock.lock()
            defer { lock.unlock() }
            guard !delivered, let result, let waiting else { return }
            delivered = true
            waiting.resume(with: result)
        }
    }
}

/// The last net for a whole job, whatever it waits for: Cancel always ends it, and a job with no sign of life for a long time ends with a message.
/// Otherwise a job stuck in one of Apple's frameworks would keep its place for ever, and with two jobs at a time soon no job would run any more.
enum JobWatch {
    /// No progress, no working program, no answer from Vision for this long. Far above any measured job: a hundred megapixels take 27 s.
    nonisolated(unsafe) static var silentSeconds: Double = 1_800
    /// After Cancel: how long the work gets to clean up after itself before it is left behind.
    nonisolated(unsafe) static var cancelGraceSeconds: Double = 10

    struct Silent: LocalizedError {
        let seconds: Double
        var errorDescription: String? {
            tr("This job stopped responding and was ended after \(ShellTimeout.readable(seconds)). The file may be damaged. Please try again, or restart the Mac if it keeps happening.",
               "Diese Aufgabe hat nicht mehr reagiert und wurde nach \(ShellTimeout.readable(seconds)) beendet. Die Datei ist vielleicht beschädigt. Versuche es erneut oder starte den Mac neu, wenn das öfter passiert.")
        }
    }

    /// Waits for `work` (already running), or until it goes silent, or for a moment after Cancel.
    static func wait<T>(for work: Task<T, Error>, notes: JobNotes) async throws -> T {
        let answer = TimeLimit.Answer<T>()
        let limit = silentSeconds, grace = cancelGraceSeconds
        Task.detached {
            do {
                answer.finish(.success(try await work.value))
            } catch {
                answer.finish(.failure(error))
            }
        }
        let watcher = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(1, limit / 4)))
                if notes.silence > limit {
                    DiagnosticLog.log("job silent for \(limit) s, leaving it behind")
                    answer.finish(.failure(Silent(seconds: limit)))
                    work.cancel()
                    return
                }
            }
        }
        defer { watcher.cancel() }
        return try await withTaskCancellationHandler {
            try await answer.value()
        } onCancel: {
            work.cancel()
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                answer.finish(.failure(CancellationError()))
            }
        }
    }
}
