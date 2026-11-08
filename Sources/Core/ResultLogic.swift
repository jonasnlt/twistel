import Foundation

/// How progress is shown: honest, but calm. No bar for work that ends within about a second, a running stripe
/// while the length is unknown or nothing new was heard for a while, a bar that only moves forward and never waits at 99 %.
enum ProgressDisplay {
    enum Bar: Equatable {
        /// Nothing yet: the work may be over before a bar would mean anything.
        case none
        /// A stripe running back and forth: it is working, but how long is not known.
        case indeterminate
        case determinate(Double)
    }

    /// Work shorter than this shows no bar, only the tick at the end.
    static let quiet: TimeInterval = 1.0
    /// No new progress for this long: the stripe runs instead of a bar that stands still.
    static let stall: TimeInterval = 4.0
    /// From here on the last bit is shown as a running stripe, so the bar never sits at 99 %.
    static let nearlyDone = 0.97

    static func bar(elapsed: TimeInterval, progress: Double, sinceLastReport: TimeInterval) -> Bar {
        guard elapsed >= quiet else { return .none }
        guard progress > 0, progress < nearlyDone, sinceLastReport < stall else { return .indeterminate }
        return .determinate(progress)
    }

    /// The value the bar shows: never less than before, so a step that starts again from 0 doesn't make it jump back.
    static func forward(shown: Double, reported: Double) -> Double {
        min(1, max(shown, reported))
    }
}

/// "1.3 MB → 344 KB (−74 %)" for the result of compressing.
enum SizeChange {
    static func text(before: Int64, after: Int64) -> String? {
        guard before > 0, after > 0 else { return nil }
        let percent = Int(((Double(after) / Double(before) - 1) * 100).rounded())
        let sign = percent > 0 ? "+" : (percent < 0 ? "−" : "±")
        return "\(FileSizeFormatter.string(before)) → \(FileSizeFormatter.string(after)) (\(sign)\(abs(percent)) %)"
    }
}

/// "Undo" on the result card puts what the work made in the Trash, and nothing else: never an original, never a file that took the
/// result's place since, never what a job only moved (`Job.undoable`).
enum ResultUndo {
    /// A file as the disk knows it (volume and file number): the same name can later belong to another file.
    struct Identity: Equatable, Hashable {
        let device: UInt64
        let inode: UInt64

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    /// Where results go when undone; tests put them in a folder of their own instead of the real Trash.
    nonisolated(unsafe) static var trash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// The results that may be put in the Trash: made by this work (same file as when it finished), not one of its inputs.
    static func removable(outputs: [URL: Identity], inputs: [URL]) -> [URL] {
        let inputPaths = Set(inputs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let inputIDs = Set(inputs.compactMap(Identity.init))
        return outputs.keys.sorted { $0.path < $1.path }.filter { url in
            guard !inputPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) else { return false }
            guard let now = Identity(url), now == outputs[url], !inputIDs.contains(now) else { return false }
            return true
        }
    }

    /// Puts the removable results in the Trash. Returns what went there and what was left (with the reason in the log).
    static func undo(outputs: [URL: Identity], inputs: [URL]) -> (trashed: [URL], left: [URL]) {
        let removable = removable(outputs: outputs, inputs: inputs)
        var trashed: [URL] = []
        for url in removable {
            do {
                try trash(url)
                trashed.append(url)
            } catch {
                DiagnosticLog.log("undo: could not put \(url.lastPathComponent) in the Trash: \(error)")
            }
        }
        let left = outputs.keys.filter { !trashed.contains($0) }
        if !left.isEmpty { DiagnosticLog.log("undo: left \(left.map(\.lastPathComponent)) (not made by this work, changed since, or failed)") }
        return (trashed, left)
    }
}
