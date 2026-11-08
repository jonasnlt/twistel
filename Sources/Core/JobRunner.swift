import AppKit
import Combine
import SwiftUI

final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
    @Published var progress: Double = 0
    /// What the job is doing right now, e.g. "Page 2 of 5"; shown next to the file name.
    @Published var step: String?
    @Published var status: Status = .waiting
    /// What the person should know about the finished result, e.g. a page left out (`JobNotes`).
    @Published var note: String?
    var outputs: [URL] = []
    /// False when the outputs are not new files of this job (a moved original): "Undo" must never put them in the Trash.
    var undoable = true
    /// The files the work reads; "Undo" never touches them.
    var inputs: [URL] = []
    /// Compressing: the result card shows the size before and after.
    var reportsSizes = false
    /// When it began to run, and when it last reported progress (for the running stripe, `ProgressDisplay`).
    var startedAt: Date?
    var lastReportAt = Date()
    /// The results as the disk knew them when the work ended: "Undo" only takes what is still these files.
    var outputIdentities: [URL: ResultUndo.Identity] = [:]
    var task: Task<Void, Never>?
    /// Where the result goes, for a message when it can't be saved.
    var outputFolder: URL?

    enum Status: Equatable {
        case waiting
        case running
        case done
        case cancelled
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .done, .cancelled, .failed: return true
            case .waiting, .running: return false
            }
        }
    }

    init(title: String, detail: String, symbol: String = "arrow.triangle.2.circlepath") {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

@MainActor
final class JobRunner: ObservableObject {
    static let shared = JobRunner()

    @Published private(set) var jobs: [Job] = []
    private lazy var hud = NotchHUD(runner: self)
    /// Where the files were dropped: progress and result show on that screen.
    var presentationPoint: NSPoint?
    private let semaphore = AsyncSemaphore(limit: 2)
    private var jobSubscriptions: [UUID: AnyCancellable] = [:]
    /// Off only in tests: no progress window on screen and no Finder window afterwards.
    var showsWindows = true

    private init() {}

    /// The job's second line: the file name, plus a hint when a large image goes to WebP, which takes a while.
    nonisolated static func detail(for url: URL, target: FileFormat) -> String {
        guard target == .webp, FileFormat.detect(url)?.category == .image else { return url.lastPathComponent }
        let size = ImageIOBridge.pixelSize(url)
        return size.width * size.height > 40_000_000 ? tr("\(url.lastPathComponent) · large image, WebP takes longer", "\(url.lastPathComponent) · großes Bild, WebP dauert länger") : url.lastPathComponent
    }

    func convert(_ urls: [URL], to target: FileFormat) {
        DiagnosticLog.log("convert \(urls.map(\.lastPathComponent)) -> \(target.displayName)")
        var reserved = Set<String>()
        for url in urls {
            guard let source = FileFormat.detect(url) else {
                DiagnosticLog.log("skipping \(url.lastPathComponent): format not detected")
                continue
            }
            let directory = AppSettings.shared.outputLocation.directory(for: url)
            let destination = ConversionMatrix.outputURL(for: url, target: target, in: directory, existing: reserved)
            DiagnosticLog.log("destination \(destination.path)")
            reserved.insert(destination.lastPathComponent)
            let job = Job(title: tr("Converting to \(target.displayName)", "In \(target.displayName) umwandeln"), detail: Self.detail(for: url, target: target), symbol: target.category.symbol)
            job.outputFolder = directory
            job.inputs = [url]
            enqueue(job) { progress in
                try InputCheck.check(url)
                let request = ConversionRequest(source: url, sourceFormat: source, target: target, destination: destination, progress: progress)
                return [try await Engines.convert(request)]
            }
        }
    }

    func enqueue(_ job: Job, work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        enqueueWithSteps(job) { report in try await work { report($0, nil) } }
    }

    /// Like `enqueue`, but the work also reports a step text with its progress.
    func enqueueWithSteps(_ job: Job, work: @escaping (@escaping (Double, String?) -> Void) async throws -> [URL]) {
        // New work after a finished batch starts a new one (a new card).
        if !jobs.isEmpty, jobs.allSatisfy({ $0.status.isFinished }) {
            jobs.removeAll()
            jobSubscriptions.removeAll()
        }
        jobs.append(job)
        jobSubscriptions[job.id] = job.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        DiagnosticLog.log("enqueue \(job.title) / \(job.detail); jobs=\(jobs.count)")
        showHUD()
        job.task = Task {
            await semaphore.wait()
            guard !Task.isCancelled else {
                DiagnosticLog.log("job cancelled before it started: \(job.detail)")
                job.status = .cancelled
                await semaphore.signal()
                scheduleHide()
                return
            }
            DiagnosticLog.log("job running: \(job.detail)")
            job.status = .running
            job.startedAt = Date()
            job.lastReportAt = Date()
            let notes = JobNotes()
            let progress: (Double, String?) -> Void = { value, step in
                notes.beat()
                Task { @MainActor in
                    job.progress = ProgressDisplay.forward(shown: job.progress, reported: value)
                    job.lastReportAt = Date()
                    if let step { job.step = step }
                }
            }
            do {
                let inputs = job.inputs
                let done = ResultOrigin.Done()
                let running = Task {
                    try await JobNotes.$current.withValue(notes) {
                        try await ResultOrigin.$sources.withValue(inputs) { try await ResultOrigin.$done.withValue(done) { try await work(progress) } }
                    }
                }
                let outputs = try await JobWatch.wait(for: running, notes: notes)
                // Results that did not go through `StagingArea.publish` get quarantine and permissions here, in the background (a folder
                // of thousands of files takes a while); the others already have them.
                let rest = job.undoable ? outputs.filter { !done.contains($0) } : []
                if !rest.isEmpty {
                    await Task.detached(priority: .userInitiated) { for output in rest { ResultOrigin.apply(to: output, from: inputs) } }.value
                }
                job.outputs = outputs
                job.outputIdentities = Dictionary(outputs.compactMap { url in ResultUndo.Identity(url).map { (url, $0) } }, uniquingKeysWith: { a, _ in a })
                job.note = notes.all.isEmpty ? nil : notes.all.joined(separator: " ")
                job.progress = 1
                job.status = .done
                DiagnosticLog.log("job done: \(job.detail) -> \(outputs.map(\.lastPathComponent))")
                if showsWindows, AppSettings.shared.revealInFinder, job.undoable, !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            } catch is CancellationError {
                DiagnosticLog.log("job cancelled: \(job.detail)")
                job.status = .cancelled
            } catch AppError.cancelled {
                DiagnosticLog.log("job cancelled: \(job.detail)")
                job.status = .cancelled
            } catch where Task.isCancelled {
                // A program ended by Cancel reports that as an error of its own; the person asked for it.
                DiagnosticLog.log("job cancelled: \(job.detail)")
                job.status = .cancelled
            } catch {
                DiagnosticLog.log("job failed: \(job.detail): \(error)")
                job.status = .failed(FailureMessage.text(for: error, folder: job.outputFolder))
            }
            await semaphore.signal()
            scheduleHide()
        }
    }

    /// The Cancel button of one job. The card stays and shows "Cancelled" once the work has stopped, then goes away
    /// with the others (`scheduleHide`). If the work finishes anyway, it says "Done".
    func cancel(_ job: Job) {
        DiagnosticLog.log("cancel requested: \(job.detail)")
        guard !job.status.isFinished else { return dismiss(job) }
        job.step = tr("Canceling", "Wird abgebrochen …")
        job.task?.cancel()
    }

    /// The card's close button. Work still running is cancelled like with its own Cancel: the card says "Cancelled" before it goes
    /// (it vanished at once, and nothing said whether the work had stopped). With nothing running it closes at once.
    func cancelAll() {
        let running = jobs.filter { !$0.status.isFinished }
        guard !running.isEmpty else { return dismissAll() }
        for job in running { cancel(job) }
    }

    func run(title: String, detail: String, symbol: String = "arrow.triangle.2.circlepath", work: @escaping (@escaping (Double) -> Void) async throws -> [URL]) {
        enqueue(Job(title: title, detail: detail, symbol: symbol), work: work)
    }

    @discardableResult
    func runWithSteps(title: String, detail: String, symbol: String = "arrow.triangle.2.circlepath", outputFolder: URL? = nil,
                      inputs: [URL] = [], reportsSizes: Bool = false,
                      work: @escaping (@escaping (Double, String?) -> Void) async throws -> [URL]) -> Job {
        let job = Job(title: title, detail: detail, symbol: symbol)
        job.outputFolder = outputFolder
        job.inputs = inputs
        job.reportsSizes = reportsSizes
        enqueueWithSteps(job, work: work)
        return job
    }

    private func showHUD() {
        guard showsWindows else { return }
        hud.update()
    }

    /// All work of the batch is over: the card says how it went (`NotchHUD` decides how long it stays).
    private func scheduleHide() {
        guard jobs.allSatisfy({ $0.status.isFinished }) else { return }
        if showsWindows { return hud.update() }
        // Without windows (tests, test access) the batch ends after the card's time, as it would on screen.
        guard let seconds = NotchHUD.cardSeconds(for: jobs) else { return }
        let batch = jobs.map(\.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.jobs.map(\.id) == batch else { return }
            self.dismissAll()
        }
    }

    func dismiss(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        jobSubscriptions[job.id] = nil
        if showsWindows { hud.update() }
    }

    func dismissAll() {
        jobs.removeAll()
        jobSubscriptions.removeAll()
        if showsWindows { hud.update() }
    }

    /// "Undo" on the result card: what these jobs made goes to the Trash; originals and moved files never.
    @discardableResult
    func undo(_ finished: [Job]) -> (trashed: [URL], left: [URL]) {
        var trashed: [URL] = []
        var left: [URL] = []
        for job in finished where job.status == .done {
            guard job.undoable else { left += job.outputs; continue }
            let result = ResultUndo.undo(outputs: job.outputIdentities, inputs: job.inputs)
            trashed += result.trashed
            left += result.left
        }
        DiagnosticLog.log("undo: trashed \(trashed.map(\.lastPathComponent)), left \(left.map(\.lastPathComponent))")
        return (trashed, left)
    }
}

actor AsyncSemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    init(limit: Int) { self.limit = limit }

    /// Returns when it is this one's turn, or at once when cancelled: a job that gives up does not wait for others to finish.
    /// Either way, `signal` afterwards.
    func wait() async {
        if count < limit {
            count += 1
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.giveUp(id) }
        }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        } else {
            count = max(0, count - 1)
        }
    }

    /// A waiter that was cancelled goes on at once and takes a place for the moment; its `signal` gives it back.
    private func giveUp(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        count += 1
        waiters.remove(at: index).continuation.resume()
    }
}
