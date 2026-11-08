import Foundation

/// One job a tool starts when its main button is clicked. The tool window and the debug test access
/// (`ToolDriver`) build it with the same function, so both take exactly the same path through `JobRunner`.
struct ToolJob {
    let title: String
    let detail: String
    let symbol: String
    /// Where the result goes, for a message when it can't be saved.
    var outputFolder: URL?
    /// The files it reads (never touched by "Undo"), and whether the card shows the size before and after (compressing).
    var inputs: [URL] = []
    var reportsSizes = false
    /// @Sendable on purpose: a closure written inside a tool window (main actor) would otherwise belong to the main
    /// thread and hop back there even when started in the background, freezing the app during e.g. a PDF merge.
    let work: @Sendable (@escaping (Double, String?) -> Void) async throws -> [URL]

    init(title: String, detail: String, symbol: String, work: @escaping @Sendable (@escaping (Double) -> Void) async throws -> [URL]) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.work = { report in try await work { report($0, nil) } }
    }

    /// For work that also reports a step text, e.g. "Page 2 of 5".
    init(title: String, detail: String, symbol: String, steps: @escaping @Sendable (@escaping (Double, String?) -> Void) async throws -> [URL]) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.work = steps
    }

    @MainActor @discardableResult
    func start() -> Job {
        let work = work
        let job = JobRunner.shared.runWithSteps(title: title, detail: detail, symbol: symbol, outputFolder: outputFolder, inputs: inputs, reportsSizes: reportsSizes) { report in
            // JobRunner's tasks belong to the main thread, and much tool work is synchronous (writing a PDF): run it in
            // the background so the app never freezes. Cancel reaches it through the handler.
            let notes = JobNotes.current
            let origin = ResultOrigin.sources
            let done = ResultOrigin.done
            let task = Task.detached {
                try await JobNotes.$current.withValue(notes) {
                    try await ResultOrigin.$sources.withValue(origin) { try await ResultOrigin.$done.withValue(done) { try await work(report) } }
                }
            }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        return job
    }
}

extension ToolSession {
    /// A job of this session's tool, titled like the tool's progress card.
    func job(_ title: String? = nil, detail: String? = nil, work: @escaping @Sendable (@escaping (Double) -> Void) async throws -> [URL]) -> ToolJob {
        let files = files
        var job = ToolJob(title: title ?? tool.progressTitle, detail: detail ?? primary.lastPathComponent, symbol: tool.symbol) { progress in
            for file in files { try InputCheck.check(file) }
            return try await work(progress)
        }
        job.outputFolder = outputDirectory
        job.inputs = files
        return job
    }

    /// Closes the tool window and starts the jobs, as the main button does.
    @MainActor
    func start(_ jobs: [ToolJob]) {
        ToolWindowManager.shared.close(self)
        for job in jobs { job.start() }
    }
}
