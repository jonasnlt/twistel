import Darwin
import Foundation
import Synchronization

enum DiagnosticLog {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = directory(environment: ProcessInfo.processInfo.environment, library: base)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Debug builds only: `TWISTEL_LOG_DIRECTORY` (an absolute path) redirects the log, so the tests keep the real log clean.
    /// The release build has no such switch: nothing from outside decides where the app writes.
    static func directory(environment: [String: String], library: URL) -> URL {
        #if DEBUG
        if let custom = environment[redirectKey], custom.hasPrefix("/") {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #endif
        return library.appendingPathComponent("Logs/\(AppIdentity.name)", isDirectory: true)
    }

    #if DEBUG
    static let redirectKey = "TWISTEL_LOG_DIRECTORY"
    #endif

    static let logFile = directory.appendingPathComponent("twistel.log")
    static let crashFile = directory.appendingPathComponent("crash.log")

    private static let queue = DispatchQueue(label: "\(AppIdentity.bundleID).log")
    private static let handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = FileHandle(forWritingAtPath: logFile.path)
        handle?.seekToEndOfFile()
        return handle
    }()

    private static var crashPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    private static let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE]
    /// Set by the first crash signal: any later one (the same trap again, a fault while writing) ends the app at once.
    private static let crashing = Atomic<Bool>(false)
    /// The crash log is only written while it is smaller than this; at the start a larger one goes to the side.
    static let largestCrashLogBytes: Int64 = 1_000_000
    #if DEBUG
    nonisolated(unsafe) static var exitsOnCrash = false
    #endif
    /// Room for the main thread to handle a crash even when its stack has run out.
    private static let alternateStackBytes = 128 * 1024

    /// Before the first entry: a log that has grown goes to the side, the one before it away. The log never grows without end.
    static let largestLogBytes: Int64 = 5_000_000
    static func rotateIfLarge(_ file: URL, limit: Int64 = largestLogBytes) {
        guard FileSizeFormatter.size(of: file) > limit else { return }
        let old = file.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }

    static func start() {
        rotateIfLarge(logFile)
        rotateIfLarge(crashFile, limit: largestCrashLogBytes)
        _ = crashFile.path.withCString { source in
            strlcpy(&crashPath, source, crashPath.count)
        }
        installCrashHandler()
        log("\(AppIdentity.name) \(AppIdentity.versionText) started, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(getpid())")
    }

    static func log(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        let text = withoutFolders(message())
        let thread = Thread.isMainThread ? "main" : "bg"
        let stamp = ISO8601DateFormatter.shared.string(from: Date())
        let entry = "\(stamp) [\(thread)] \(file):\(line) \(text)\n"
        queue.sync {
            // The throwing call: the older one ends the app when the disk is full.
            try? handle?.write(contentsOf: Data(entry.utf8))
        }
        DragDebug.log(text)
    }

    /// The log names files, never the folders they are in: a path says whose Mac it is and how it is organised. Every absolute
    /// path in a message (also inside an error text of macOS or a program) keeps only its last part, "…/Brief.pdf".
    static func withoutFolders(_ text: String) -> String {
        guard text.contains("/") else { return text }
        return text.replacingOccurrences(of: folderPattern, with: "…/", options: .regularExpression)
    }

    /// From a slash at the start or after a space, quote (also „ “ ” « » ‘ ’), bracket, "=", "," or ";" up to the last slash of that path;
    /// each folder name begins with something other than a space ("min 1.00 / max 2.00" is no path) and has no colon (a path ends
    /// before "file:///…") and no double quotes („ “ ” « »). A folder name may hold spaces and apostrophes ("Anna's Fotos"), so two
    /// paths with only such text between them become one: the text in between is lost, never a folder.
    private static let folderPattern = #"(?<=^|[\s"'(\[{<=:,;„“”«»‘’‚])(?:~|file://)?/(?:[^/\s"<>|:„“”«»][^/\n\t"<>|:„“”«»]*/)+"#

    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// Catches the crash signals. A Swift runtime error arrives as SIGTRAP, for which macOS ignores SA_RESETHAND: the handler
    /// itself puts the default back and ends the app, so a crash can never turn into an endless loop of log entries.
    static func installCrashHandler() {
        if let stack = malloc(alternateStackBytes) {
            var alternate = stack_t(ss_sp: stack, ss_size: alternateStackBytes, ss_flags: 0)
            sigaltstack(&alternate, nil)
        }
        // backtrace() loads what it needs on its first call; in the handler that must already be done.
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 4)
        _ = backtrace(&frames, Int32(frames.count))
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = crashHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }

    /// Only async-signal-safe calls in here: no Swift strings, arrays or anything else that may allocate memory.
    private static let crashHandler: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { signal, info, _ in
        if crashing.exchange(true, ordering: .sequentiallyConsistent) { _exit(128 + signal) }
        for each in signals { Darwin.signal(each, SIG_DFL) }
        let fd = crashPath.withUnsafeBufferPointer { open($0.baseAddress!, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        if fd >= 0 {
            var status = stat()
            if fstat(fd, &status) == 0, Int64(status.st_size) < largestCrashLogBytes {
                writeText(fd, "==== twistel crash ====\nsignal ")
                writeNumber(fd, UInt(signal))
                writeText(fd, " (")
                writeText(fd, name(of: signal))
                writeText(fd, ")\n")
                if let info {
                    writeText(fd, "code ")
                    writeNumber(fd, UInt(bitPattern: Int(info.pointee.si_code)))
                    writeText(fd, " address ")
                    writeNumber(fd, UInt(bitPattern: info.pointee.si_addr))
                    writeText(fd, "\n")
                }
                writeText(fd, pthread_main_np() != 0 ? "thread main\n" : "thread background\n")
                withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
                    let count = backtrace(frames.baseAddress!, Int32(frames.count))
                    backtrace_symbols_fd(frames.baseAddress!, count, fd)
                }
                writeText(fd, "\n")
            }
            close(fd)
        }
        #if DEBUG
        // The tests end their crashing child this way: no crash report of macOS in ~/Library for a crash made on purpose.
        if exitsOnCrash { _exit(128 + signal) }
        #endif
        // With the default back in place the signal ends the app (and macOS writes its crash report).
        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, signal)
        pthread_sigmask(SIG_UNBLOCK, &unblock, nil)
        raise(signal)
        _exit(128 + signal)
    }

    private static func name(of signal: Int32) -> StaticString {
        switch signal {
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGABRT: return "SIGABRT"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        default: return "?"
        }
    }

    private static func writeText(_ fd: Int32, _ text: StaticString) {
        _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
    }

    private static func writeNumber(_ fd: Int32, _ number: UInt) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { digits in
            var value = number, index = digits.count
            repeat {
                index -= 1
                digits[index] = UInt8(48 + value % 10)
                value /= 10
            } while value > 0
            _ = write(fd, digits.baseAddress! + index, digits.count - index)
        }
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
