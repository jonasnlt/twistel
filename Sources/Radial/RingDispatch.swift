import AppKit

/// What happens with the item chosen in a ring or its "More …" list.
@MainActor
enum RingDispatch {
    enum Decision: Equatable { case run, window }

    /// Tools without settings run at once; with settings their window opens, unless Option was held; tools that need their window
    /// always get it (`ToolGroup`).
    nonisolated static func decision(for tool: ToolID, quickRun: Bool) -> Decision {
        switch tool.group {
        case .immediate: return .run
        case .window: return quickRun ? .run : .window
        case .windowOnly: return .window
        }
    }

    static func run(_ entry: RingEntry, files: [URL], ring: RingKind, quickRun: Bool, at point: NSPoint) {
        JobRunner.shared.presentationPoint = point
        switch entry.id {
        case .convert(let target):
            JobRunner.shared.convert(files, to: target)
        case .tool(let tool):
            DiagnosticLog.log("tool \(tool.rawValue) quickRun=\(quickRun) group=\(tool.group.rawValue)")
            guard decision(for: tool, quickRun: quickRun) == .run else {
                ToolWindowManager.shared.open(tool, files: files)
                return
            }
            Task { @MainActor in
                let session = ToolSession(tool: tool, files: files)
                var options = ToolOptions(ToolMemory.values(tool))
                do {
                    guard let jobs = try await QuickRun.jobs(tool, session: session, options: &options) else {
                        ToolWindowManager.shared.open(tool, files: files)
                        return
                    }
                    for job in jobs { job.start() }
                } catch {
                    // A remembered value that no longer fits: the window shows what to choose.
                    DiagnosticLog.log("quick run of \(tool.rawValue) failed (\(error)); opening its window")
                    ToolWindowManager.shared.open(tool, files: files)
                }
            }
        case .action(let action):
            FileActions.perform(action, on: files, at: point)
        case .more:
            break
        }
    }
}
