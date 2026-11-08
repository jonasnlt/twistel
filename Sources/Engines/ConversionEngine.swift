import Foundation

struct ConversionRequest {
    let source: URL
    let sourceFormat: FileFormat
    let target: FileFormat
    let destination: URL
    let progress: (Double) -> Void
    /// While staged: the place the result will finally have, for names that depend on what is already there.
    var finalDestination: URL?
    /// While staged: what is put in this folder ends up next to the result (the pictures of a Markdown file).
    var besideResult: URL?
}

protocol ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool
    func convert(_ request: ConversionRequest) async throws
}

enum Engines {
    static let all: [ConversionEngine] = [
        ImageEngine(),
        AudioEngine(),
        VideoEngine(),
        DocumentEngine(),
        OfficeEngine(),
        SubtitleEngine(),
        ArchiveEngine(),
    ]

    static func engine(from: FileFormat, to: FileFormat) -> ConversionEngine? {
        all.first { $0.supports(from: from, to: to) }
    }

    /// Returns what was made: `destination`, or a folder without the picture ending when several pages became pictures.
    @discardableResult
    static func convert(_ request: ConversionRequest) async throws -> URL {
        guard let engine = engine(from: request.sourceFormat, to: request.target) else {
            DiagnosticLog.log("no engine for \(request.sourceFormat.rawValue) -> \(request.target.rawValue)")
            throw AppError.unsupportedConversion(request.sourceFormat, request.target)
        }
        return try await convert(request, using: engine)
    }

    @discardableResult
    static func convert(_ request: ConversionRequest, using engine: ConversionEngine) async throws -> URL {
        DiagnosticLog.log("engine \(type(of: engine)) \(request.sourceFormat.rawValue) -> \(request.target.rawValue) src=\(request.source.path)")
        let staging = try StagingArea.makeDirectory(for: request.destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temp = staging.appendingPathComponent(request.destination.lastPathComponent)
        let staged = ConversionRequest(
            source: request.source,
            sourceFormat: request.sourceFormat,
            target: request.target,
            destination: temp,
            progress: request.progress,
            finalDestination: request.destination,
            besideResult: staging.appendingPathComponent("beside", isDirectory: true)
        )
        do {
            try await engine.convert(staged)
            try Task.checkCancellation()
            DiagnosticLog.log("engine finished, staged=\(temp.lastPathComponent)")
            guard FileManager.default.fileExists(atPath: temp.path), FileSizeFormatter.size(of: temp) > 0 else {
                throw AppError.invalidInput(tr("\(request.source.lastPathComponent) has no content that could be converted.", "\(request.source.lastPathComponent) enthält nichts, was umgewandelt werden könnte."))
            }
            let made: URL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: temp.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let folder = ConversionMatrix.uniqueDirectory(
                    directory: request.destination.deletingLastPathComponent(),
                    name: request.destination.deletingPathExtension().lastPathComponent
                )
                made = try StagingArea.publish(temp, to: folder, origin: [request.source])
            } else {
                made = try StagingArea.publish(temp, to: request.destination, origin: [request.source])
            }
            if let beside = staged.besideResult, let extras = try? FileManager.default.contentsOfDirectory(at: beside, includingPropertiesForKeys: nil) {
                var placed: [URL] = []
                do {
                    for extra in extras {
                        ResultOrigin.apply(to: extra, from: [request.source])
                        let target = request.destination.deletingLastPathComponent().appendingPathComponent(extra.lastPathComponent)
                        // Never in place of something that is there: a name taken in the meantime is an error, not a replacement.
                        try StagingArea.moveWithoutReplacing(extra, to: target)
                        placed.append(target)
                    }
                } catch {
                    // A Markdown file without its pictures is half a result. Only what this work put there goes away again.
                    try? FileManager.default.removeItem(at: made)
                    for target in placed { try? FileManager.default.removeItem(at: target) }
                    throw error
                }
            }
            return made
        } catch {
            DiagnosticLog.log("engine threw: \(error)")
            throw error
        }
    }
}

/// Where conversions write before the result is moved into place.
///
/// Never the destination folder: iCloud Drive marks dot-named items in a synced folder as hidden
/// within a second, and the flag survives the rename, so the result would be invisible in Finder.
enum StagingArea {
    /// A new, empty folder on the same volume as `destination` (so the final move is a rename where possible),
    /// outside the destination folder. The caller removes it when done.
    static func makeDirectory(for destination: URL) throws -> URL {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent().standardizedFileURL
        if let directory = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true),
           !isInside(directory, parent) {
            return directory
        }
        let directory = fm.temporaryDirectory.appendingPathComponent("twistel-staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Runs `work` on a place in the staging area and only then puts the file where it belongs: whatever goes wrong before
    /// (cancel, full disk, a crash), no half file lies next to the original. Returns where it ended up.
    static func writing(_ destination: URL, _ work: (URL) async throws -> Void) async throws -> URL {
        let staging = try makeDirectory(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temp = staging.appendingPathComponent(destination.lastPathComponent)
        try await work(temp)
        try Task.checkCancellation()
        return try publish(temp, to: destination)
    }

    /// The same for a folder of results: `work` fills the folder and returns what it wrote there.
    static func writingFolder(_ folder: URL, _ work: (URL) async throws -> [URL]) async throws -> [URL] {
        let staging = try makeDirectory(for: folder)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temp = staging.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let written = try await work(temp)
        try Task.checkCancellation()
        let final = try publish(temp, to: folder)
        return written.map { final.appendingPathComponent($0.lastPathComponent) }
    }

    /// Moves a finished result into place, under a free name: nothing that is there is ever replaced or removed, also not a link
    /// that leads nowhere. On another volume this is a copy: if it fails on the way, what it copied goes away again.
    /// The result gets the quarantine mark and at most the permissions of the files it was made from (`ResultOrigin`).
    static func publish(_ temp: URL, to destination: URL, origin: [URL]? = nil) throws -> URL {
        ResultOrigin.apply(to: temp, from: origin ?? ResultOrigin.sources)
        let folder = destination.deletingLastPathComponent()
        var final = destination
        for _ in 0..<1_000 {
            if ConversionMatrix.isTaken(final) {
                // Taken since the name was chosen.
                final = destination.pathExtension.isEmpty
                    ? ConversionMatrix.uniqueDirectory(directory: folder, name: destination.lastPathComponent)
                    : ConversionMatrix.uniqueURL(directory: folder, baseName: destination.deletingPathExtension().lastPathComponent, suffix: "", ext: destination.pathExtension)
            }
            do {
                try moveWithoutReplacing(temp, to: final)
                ResultOrigin.done?.add(final)
                return final
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
    }

    /// A move that fails when the name is taken (`CocoaError.fileWriteFileExists`) instead of replacing what is there. On the same
    /// volume one atomic step. On another volume, and where the volume has no such step (exFAT, many USB sticks), a copy that
    /// creates every file and folder only if its name is free; only what that copy made is removed when it fails.
    static func moveWithoutReplacing(_ item: URL, to target: URL) throws {
        if renamex_np(item.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
        let code = errno
        if code == EEXIST { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path]) }
        guard code == EXDEV || code == ENOTSUP || code == EOPNOTSUPP else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: target.path]) }
        if code != EXDEV { DiagnosticLog.log("volume has no exclusive rename (errno \(code)), copying without replacing") }
        try copyWithoutReplacing(item, to: target)
    }

    /// The copy `moveWithoutReplacing` falls back to; the item goes away once the copy is complete.
    static func copyWithoutReplacing(_ item: URL, to target: URL) throws {
        var made: [String] = []
        do {
            try copyWithoutReplacing(item.path, to: target.path, made: &made)
        } catch {
            // Newest first, so folders are empty when they go. Only what this copy created.
            for path in made.reversed() {
                var status = stat()
                guard lstat(path, &status) == 0 else { continue }
                if (status.st_mode & S_IFMT) == S_IFDIR { rmdir(path) } else { unlink(path) }
            }
            throw error
        }
        try? FileManager.default.removeItem(at: item)
    }

    /// Each name is created with "only if new" (O_EXCL, mkdir, symlink): a file that appears there in the meantime is never written over.
    private static func copyWithoutReplacing(_ source: String, to target: String, made: inout [String]) throws {
        func failure(_ code: Int32) -> Error {
            code == EEXIST ? CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target])
                           : NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: target])
        }
        var status = stat()
        guard lstat(source, &status) == 0 else { throw failure(errno) }
        switch status.st_mode & S_IFMT {
        case S_IFLNK:
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: source)
            guard symlink(destination, target) == 0 else { throw failure(errno) }
            made.append(target)
        case S_IFDIR:
            guard mkdir(target, 0o700) == 0 else { throw failure(errno) }
            made.append(target)
            for name in try FileManager.default.contentsOfDirectory(atPath: source) {
                try copyWithoutReplacing(source + "/" + name, to: target + "/" + name, made: &made)
            }
            _ = copyfile(source, target, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_STAT | COPYFILE_NOFOLLOW))
        default:
            let flags = copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR | COPYFILE_STAT | COPYFILE_EXCL | COPYFILE_NOFOLLOW)
            if copyfile(source, target, nil, flags) != 0 {
                let code = errno
                // EEXIST: not ours, so it stays. Otherwise the file was created by this copy.
                if code != EEXIST, ConversionMatrix.isTaken(URL(fileURLWithPath: target)) { made.append(target) }
                throw failure(code)
            }
            made.append(target)
        }
        // copyfile rewrites the quarantine mark on the way; the result keeps it as it was.
        if (status.st_mode & S_IFMT) != S_IFLNK, let quarantine = ResultOrigin.quarantineMark(URL(fileURLWithPath: source)) {
            _ = quarantine.withUnsafeBytes { setxattr(target, ResultOrigin.quarantineName, $0.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW) }
        }
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path == folderPath || path.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
    }
}

/// What a result inherits from the files it was made from. A file downloaded from the internet carries macOS's quarantine mark, and
/// Gatekeeper checks it before anything in it runs: an app or a script in an archive repacked or unpacked by twistel keeps that check.
/// And a result is never readable by more people than its original: from a file only its owner may read (0600) no copy for all (0644)
/// is made.
enum ResultOrigin {
    /// The inputs of the job that is running (set by `JobRunner`); `StagingArea.publish` uses them for each result.
    @TaskLocal static var sources: [URL] = []
    /// The results of the running job that already have both (set by `JobRunner`), so it does not go through them a second time.
    @TaskLocal static var done: Done?

    final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func add(_ url: URL) { lock.withLock { paths.append(url.standardizedFileURL.path) } }

        /// True for a recorded result and for anything inside a recorded folder.
        func contains(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return lock.withLock { paths.contains { path == $0 || path.hasPrefix($0 + "/") } }
        }
    }

    static let quarantineName = "com.apple.quarantine"

    #if DEBUG
    /// Tests only: told of each `apply`, and whether it ran on the main thread.
    nonisolated(unsafe) static var watcher: ((URL, Bool) -> Void)?
    #endif

    /// Applies both to `result` and, for a folder, to everything in it. Links are left as they are.
    static func apply(to result: URL, from sources: [URL]) {
        guard !sources.isEmpty else { return }
        #if DEBUG
        watcher?(result, Thread.isMainThread)
        #endif
        let allowed = allowedOthers(of: sources)
        let quarantine = sources.lazy.compactMap(quarantineMark).first
        var items = [result]
        if let walker = FileManager.default.enumerator(at: result, includingPropertiesForKeys: nil, options: []) {
            for case let item as URL in walker { items.append(item) }
        }
        for item in items {
            var status = stat()
            guard lstat(item.path, &status) == 0, (status.st_mode & S_IFMT) != S_IFLNK else { continue }
            let isFolder = (status.st_mode & S_IFMT) == S_IFDIR
            let mode = status.st_mode & 0o7777
            let wanted = permissions(mode, allowedOthers: allowed, isFolder: isFolder)
            if wanted != mode { chmod(item.path, wanted) }
            if let quarantine, getxattr(item.path, quarantineName, nil, 0, 0, XATTR_NOFOLLOW) < 0 {
                _ = quarantine.withUnsafeBytes { setxattr(item.path, quarantineName, $0.baseAddress, quarantine.count, 0, XATTR_NOFOLLOW) }
            }
        }
    }

    /// The group and others bits all sources share (0o077 at most).
    static func allowedOthers(of sources: [URL]) -> mode_t {
        sources.reduce(mode_t(0o077)) { allowed, source in
            var status = stat()
            guard stat(source.path, &status) == 0 else { return allowed }
            return allowed & status.st_mode & 0o077
        }
    }

    /// The owner keeps what the result has; group and others get no more than the sources allow (a folder may be entered where its
    /// contents may be read). Set-user and set-group bits never come along.
    static func permissions(_ mode: mode_t, allowedOthers: mode_t, isFolder: Bool) -> mode_t {
        var others = allowedOthers
        if isFolder { others |= (allowedOthers & 0o044) >> 2 }
        return (mode & 0o1700) | (mode & others & 0o077)
    }

    static func quarantineMark(_ file: URL) -> Data? {
        let size = getxattr(file.path, quarantineName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(file.path, quarantineName, $0.baseAddress, size, 0, 0) }
        return read == size ? data : nil
    }
}

/// The app's own working files in the system's temporary folder. They go away with each job; what a crash or a forced quit leaves behind (possibly copies of
/// someone's documents) goes at the next start. macOS would only do that after days.
enum TemporaryFiles {
    static func removeLeftovers(in folder: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-age)
        for item in items where item.lastPathComponent.hasPrefix("twistel-") {
            guard let changed = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, changed < limit else { continue }
            try? fm.removeItem(at: item)
        }
    }
}
