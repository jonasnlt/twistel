import Darwin
import Foundation
import Synchronization

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

/// How long a separate program may take. Every call has a limit: a program that waits for ever (a hidden dialog, a damaged
/// file) would otherwise keep its job, and with two jobs at a time soon all the others, waiting for ever too.
struct ShellLimit: Sendable {
    /// Longest time in all, in seconds.
    var total: Double
    /// Longest time with neither output nor any computing: such a program is waiting for something that does not come.
    /// Long work (a film, hours of speech) has no fair total limit, but it keeps computing.
    var silent: Double?

    /// Asking a program something small: its version, the length of a file.
    static let quick = ShellLimit(total: 120, silent: nil)
    /// Reading or packing one file.
    static let task = ShellLimit(total: 3_600, silent: 300)
    /// Long work on one file, where hours are normal.
    static let work = ShellLimit(total: 86_400, silent: 300)
}

/// A program went over its limit and was stopped.
struct ShellTimeout: LocalizedError {
    let program: String
    let seconds: Double

    var errorDescription: String? {
        tr("\(program) stopped responding and was ended after \(Self.readable(seconds)). The file may be damaged or still downloading from iCloud. Please try again.",
           "\(program) hat nicht mehr reagiert und wurde nach \(Self.readable(seconds)) beendet. Die Datei ist vielleicht beschädigt oder wird noch aus iCloud geladen. Versuche es erneut.")
    }

    static func readable(_ seconds: Double) -> String {
        if seconds < 90 { return tr("\(Int(seconds)) seconds", "\(Int(seconds)) Sekunden") }
        if seconds < 5_400 { return tr("\(Int((seconds / 60).rounded())) minutes", "\(Int((seconds / 60).rounded())) Minuten") }
        return tr("\(Int((seconds / 3_600).rounded())) hours", "\(Int((seconds / 3_600).rounded())) Stunden")
    }
}

/// macOS's network lock does not work, so a program was not started: it could otherwise reach the internet with what it reads.
struct NetworkLockMissing: LocalizedError {
    let program: String

    var errorDescription: String? {
        tr("\(program) was not started: twistel runs other programs only with their network access blocked, and macOS's lock for that (sandbox-exec) does not work right now. Quit twistel and open it again; if that doesn't help, restart the Mac.",
           "\(program) wurde nicht gestartet: twistel führt andere Programme nur mit gesperrtem Netzzugang aus, und die Sperre von macOS dafür (sandbox-exec) funktioniert gerade nicht. Beende twistel und öffne es erneut; hilft das nicht, starte den Mac neu.")
    }
}

enum Shell {
    enum Stream: Sendable {
        case standardOutput
        case standardError
    }

    /// `input` is written to the program's standard input, e.g. a password that must not appear on the command line.
    /// `environment` adds to (or overrides) the app's own environment for this program.
    /// With `onLine`, each line of `stream` is handed over while the program runs (on a background queue).
    /// Cancelling the task ends the program; the caller checks for cancellation afterwards. Over the limit: `ShellTimeout`.
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil, input: Data? = nil,
                    environment: [String: String] = [:], limit: ShellLimit = .task, stream: Stream = .standardOutput,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> ShellResult {
        // sandbox-exec itself failed a few times under heavy load (exit 71, in a run of several tests at once; not to be reproduced on purpose): one more try.
        var tries = 0
        while true {
            let running = RunningProgram(executable: executable, limit: limit, job: JobNotes.current)
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    running.start(arguments: arguments, currentDirectory: currentDirectory, input: input, environment: environment,
                                  stream: stream, onLine: onLine, continuation: continuation)
                }
            } onCancel: {
                running.stop()
            }
            tries += 1
            guard result.status == 71, result.stderr.contains("sandbox-exec"), tries < 3, !Task.isCancelled else { return result }
            DiagnosticLog.log("sandbox-exec failed: \(result.stderr.prefix(200))")
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    /// Everything runs on this Mac, so no separate program may reach the network: an HTML file with a style sheet on some server made LibreOffice
    /// fetch it, so that a stranger's file could tell its sender when it is opened. macOS's `sandbox-exec` takes that away
    /// from each program, name lookups (DNS through mDNSResponder) included; local connections inside a program stay.
    static let networkLockProfile = "(version 1)(allow default)(deny network* (remote ip))"
        + "(deny network* (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")))"
    static let networkLockTool = "/usr/bin/sandbox-exec"

    /// The lock, or nil if `sandbox-exec` does not work here. Then no program runs at all (`NetworkLockMissing`): never without the lock.
    /// A lock that works is remembered; one that failed is tried again after a while (it failed under heavy load once).
    static var withoutNetwork: (tool: String, profile: String)? {
        let now = Date()
        let known: Bool? = lockState.withLock { state in
            if state.works { return true }
            if let checked = state.failedAt, now.timeIntervalSince(checked) < 30 { return false }
            return nil
        }
        if let known { return known ? (networkLockTool, networkLockProfile) : nil }
        let works = twice { lockWorks(tool: networkLockTool, profile: networkLockProfile) }
        lockState.withLock { state in
            state.works = works
            state.failedAt = works ? nil : now
        }
        if !works { DiagnosticLog.log("sandbox-exec does not work here: no program is started without the network lock") }
        return works ? (networkLockTool, networkLockProfile) : nil
    }

    /// A check that failed is made once more right away (a busy Mac can miss the five seconds once) before programs wait 30 s.
    static func twice(_ check: () -> Bool) -> Bool {
        if check() { return true }
        DiagnosticLog.log("network lock check failed, checking once more")
        return check()
    }

    private struct LockState { var works = false; var failedAt: Date? }
    private static let lockState = Mutex(LockState())

    /// Runs a program that does nothing through the lock: it must start and end well within a few seconds.
    static func lockWorks(tool: String, profile: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return false }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: tool)
        check.arguments = ["-p", profile, "/usr/bin/true"]
        check.standardInput = FileHandle.nullDevice
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        check.terminationHandler = { _ in done.signal() }
        guard (try? check.run()) != nil, done.wait(timeout: .now() + 5) == .success, check.terminationStatus == 0 else {
            if check.isRunning { check.terminate() }
            return false
        }
        return true
    }

    /// What is started for `executable`: always the lock with the program inside it. Without a lock, an error instead.
    static func launch(_ executable: String, _ arguments: [String], lock: (tool: String, profile: String)?) throws -> (executable: String, arguments: [String]) {
        guard let lock else { throw NetworkLockMissing(program: (executable as NSString).lastPathComponent) }
        return (lock.tool, ["-p", lock.profile, executable] + arguments)
    }

    static func which(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        var candidates = extra
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "\(fm.homeDirectoryForCurrentUser.path)/.local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path {
            candidates.insert(bundled, at: 0)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent(name).path {
            candidates.insert(resource, at: 1)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}

/// One program from start to end: reads its output, watches its limit, stops it, and answers exactly once.
private final class RunningProgram: @unchecked Sendable {
    /// After SIGTERM: how long a program gets to end by itself before SIGKILL.
    static let graceSeconds = 3.0
    /// After the end: how long the output may still come. A helper the program left behind can keep the pipes open for ever.
    static let drainSeconds = 2.0
    private static let checkInterval = 1.0
    /// Share of one processor below which a program counts as idle: even a waiting program computes a little now and then.
    private static let idleShare = 0.003
    private static let stderrKept = 8_000_000

    private let process = Process()
    private let executable: String
    private let limit: ShellLimit
    private let lock = NSLock()
    private let output = DispatchGroup()
    private var stdout = Data()
    private var stderr = Data()
    private var lines = Data()
    private var continuation: CheckedContinuation<ShellResult, Error>?
    private var stopAsked = false
    private var overLimit: Double?
    private var started = false
    private var answered = false
    private var openPipes: Set<ObjectIdentifier> = []
    private var watch: DispatchSourceTimer?
    private var lastSign = Date()
    private var lastComputing = 0.0
    private let job: JobNotes?

    init(executable: String, limit: ShellLimit, job: JobNotes?) {
        self.executable = executable
        self.limit = limit
        self.job = job
    }

    private var program: String { (executable as NSString).lastPathComponent }

    func start(arguments: [String], currentDirectory: URL?, input: Data?, environment: [String: String], stream: Shell.Stream,
               onLine: (@Sendable (String) -> Void)?, continuation: CheckedContinuation<ShellResult, Error>) {
        lock.withLock { self.continuation = continuation }
        // Through sandbox-exec, a missing program would only show as an exit status.
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            answer(.failure(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: executable])))
            return
        }
        // Process does not return an error for this: it ends the app with an exception.
        let commandLine = arguments.reduce(0) { $0 + $1.utf8.count + 1 } + executable.utf8.count + 200
        guard commandLine < Int(sysconf(_SC_ARG_MAX)) - 100_000 else {
            answer(.failure(AppError.toolFailed(program, tr("the list of files is too long", "Die Liste der Dateien ist zu lang."))))
            return
        }
        do {
            let launch = try Shell.launch(executable, arguments, lock: Shell.withoutNetwork)
            process.executableURL = URL(fileURLWithPath: launch.executable)
            process.arguments = launch.arguments
        } catch {
            answer(.failure(error))
            return
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = input.map { _ in Pipe() }
        if let inPipe {
            process.standardInput = inPipe
            // A program that ends without reading must not end the app with it (SIGPIPE).
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        } else {
            // Nothing can wait for an answer from the person.
            process.standardInput = FileHandle.nullDevice
        }
        read(outPipe, into: \.stdout, onLine: stream == .standardOutput ? onLine : nil)
        read(errPipe, into: \.stderr, onLine: stream == .standardError ? onLine : nil)
        process.terminationHandler = { [self] proc in
            DispatchQueue.global().async { [self] in
                _ = output.wait(timeout: .now() + Self.drainSeconds)
                close(outPipe)
                close(errPipe)
                finish(status: proc.terminationStatus)
            }
        }
        do {
            try process.run()
        } catch {
            close(outPipe)
            close(errPipe)
            answer(.failure(error))
            return
        }
        let stopNow: Bool = lock.withLock {
            started = true
            return stopAsked
        }
        startWatching()
        if stopNow { stop() }
        if let inPipe, let input {
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
    }

    /// Ends the program, by force if it does not listen. A program that cannot even be killed still gets an answer: the job must end.
    func stop() {
        let running: Bool = lock.withLock {
            stopAsked = true
            return started
        }
        guard running else { return }
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.graceSeconds) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainSeconds + Self.graceSeconds) { [self] in
                finish(status: SIGKILL)
            }
        }
    }

    private func read(_ pipe: Pipe, into buffer: ReferenceWritableKeyPath<RunningProgram, Data>, onLine: (@Sendable (String) -> Void)?) {
        output.enter()
        lock.withLock { _ = openPipes.insert(ObjectIdentifier(pipe)) }
        let isErrors = buffer == \RunningProgram.stderr
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                if let onLine { flushLines(onLine) }
                close(pipe)
                return
            }
            lock.withLock {
                lastSign = Date()
                self[keyPath: buffer].append(chunk)
                if isErrors, stderr.count > Self.stderrKept { stderr.removeFirst(stderr.count - Self.stderrKept) }
            }
            if let onLine { handLines(of: chunk, to: onLine) }
        }
    }

    /// No more reading from this pipe. Exactly one `leave` for each `enter`: a group left unbalanced crashes when it goes away.
    private func close(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        let wasOpen = lock.withLock { openPipes.remove(ObjectIdentifier(pipe)) != nil }
        if wasOpen { output.leave() }
    }

    private func handLines(of chunk: Data, to onLine: @Sendable (String) -> Void) {
        let found: [String] = lock.withLock {
            lines.append(chunk)
            var result: [String] = []
            while let newline = lines.firstIndex(of: 10) {
                result.append(String(decoding: lines[lines.startIndex..<newline], as: UTF8.self))
                lines = Data(lines[(newline + 1)...])
            }
            return result
        }
        found.forEach(onLine)
    }

    private func flushLines(_ onLine: @Sendable (String) -> Void) {
        let rest: Data = lock.withLock {
            defer { lines = Data() }
            return lines
        }
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }

    private func startWatching() {
        let begun = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + min(Self.checkInterval, limit.total), repeating: min(Self.checkInterval, max(limit.total / 4, 0.05)))
        timer.setEventHandler { [self] in
            let now = Date()
            // While a program runs, its limit here is what counts for the job.
            job?.beat()
            if now.timeIntervalSince(begun) > limit.total { return giveUp(after: limit.total) }
            guard let silent = limit.silent else { return }
            let computing = Self.computingSeconds(of: process.processIdentifier)
            let quiet: Double = lock.withLock {
                if computing - lastComputing >= silent * Self.idleShare {
                    lastComputing = computing
                    lastSign = now
                }
                return now.timeIntervalSince(lastSign)
            }
            if quiet > silent { giveUp(after: silent) }
        }
        lock.withLock { watch = timer }
        lock.withLock { lastSign = begun }
        timer.resume()
    }

    private func giveUp(after seconds: Double) {
        let first: Bool = lock.withLock {
            guard overLimit == nil else { return false }
            overLimit = seconds
            return true
        }
        guard first else { return }
        DiagnosticLog.log("\(program) over its limit of \(seconds) s, stopping it")
        stop()
    }

    /// Computing time so far, in seconds.
    private static func computingSeconds(of pid: pid_t) -> Double {
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V0, $0) }
        }
        guard result == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    private func finish(status: Int32) {
        let (out, err, over): (Data, Data, Double?) = lock.withLock { (stdout, stderr, overLimit) }
        if let over {
            answer(.failure(ShellTimeout(program: program, seconds: over)))
        } else {
            answer(.success(ShellResult(status: status, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))))
        }
    }

    private func answer(_ result: Result<ShellResult, Error>) {
        let waiting: CheckedContinuation<ShellResult, Error>? = lock.withLock {
            guard !answered else { return nil }
            answered = true
            watch?.cancel()
            watch = nil
            return continuation
        }
        waiting?.resume(with: result)
    }
}
