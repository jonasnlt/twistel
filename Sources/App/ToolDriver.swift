#if DEBUG
import AppKit
import PDFKit
import SwiftUI

/// Test access, only in debug builds: runs one tool or a conversion without mouse, Finder or windows and prints the
/// result as JSON, then quits.
///
///     twistel --run-tool <tool> --input <file> [--input <file> …] --output <folder> [--option key=value …]
///               [--cancel-after <seconds>]
///     twistel --run-tool <tool> --input <file> … --output <folder> --draw-window <picture.png> [--option appearance=dark]
///     twistel --run-tool <tool> --input <file> … --output <folder> --vision-hang-width <pixels> --vision-limit <seconds>
///
/// `--vision-hang-width` lets Vision calls on pictures of that width hang as they do in real life, to see what the result says.
/// `--lock-output` makes the output folder read-only once the copies are in it, to see what happens when the place next to the original cannot be written.
///
/// With `--draw-window` the tool is not run: its window is built off screen with the inputs and drawn into a PNG
/// (no screen recording, so no macOS permission is needed), to see a new window before trying it.
///
/// `<tool>` is a tool's id (e.g. `recognizeText`, see `ToolID`) or `convert` with `--option to=<format>`.
/// The jobs are built by the same functions the tool windows use and run through `JobRunner`, in the real app
/// (same bundle ID, same caches). The inputs are first copied into the output folder and the app saves "next to
/// the original" as usual, so the originals are never touched. Settings live in memory only; the log goes to
/// `<output>/logs`. A password is read from standard input (`--option password=-`), never from the command line.
@MainActor
enum ToolDriver {
    /// Written to the log on every test run. `scripts/release.sh` looks for it in the release build, which must not contain it.
    static let marker = "TWISTEL-DEBUG-TEST-ACCESS: tool driver compiled in"

    struct Arguments: Equatable {
        var tool: String
        var inputs: [URL]
        var output: URL
        var options: [String: String]
        var cancelAfter: Double?
        var drawWindow: URL?
        var visionHangWidth: Int?
        var visionLimit: Double?
        var lockOutput = false
        /// Texts and names of results; English unless `--language de`.
        var language: AppLanguage = .english
        /// `--remember key=value`: values the tool's window remembered from an earlier use (`ToolMemory`).
        var remembered: [String: String] = [:]
        /// `--max-seconds`: the instance ends itself after this long (`Watchdog`).
        var maxSeconds: Double = ToolDriver.defaultMaxSeconds
    }

    /// Longest a test instance may live unless `--max-seconds` says otherwise.
    nonisolated static let defaultMaxSeconds: Double = 300

    enum DriverError: LocalizedError {
        case usage(String)
        var errorDescription: String? {
            switch self {
            case .usage(let message): return message
            }
        }
    }

    struct JobResult: Encodable {
        let title: String
        let detail: String
        let status: String
        let message: String?
        let outputs: [String]
    }

    struct Result: Encodable {
        var tool: String
        var status: String
        var seconds: Double
        var inputs: [String]
        var outputs: [String]
        var messages: [String]
        var jobs: [JobResult]
        var longestMainThreadBlockSeconds: Double
    }

    // MARK: Arguments

    /// nil when the app was started normally (no `--run-tool`).
    static func parse(_ arguments: [String]) throws -> Arguments? {
        guard let index = arguments.firstIndex(of: "--run-tool") else { return nil }
        var tool: String?
        var inputs: [URL] = []
        var output: URL?
        var options: [String: String] = [:]
        var cancelAfter: Double?
        var drawWindow: URL?
        var visionHangWidth: Int?
        var visionLimit: Double?
        var lockOutput = false
        var language = AppLanguage.english
        var remembered: [String: String] = [:]
        var maxSeconds = defaultMaxSeconds
        var rest = arguments[index...].makeIterator()
        while let flag = rest.next() {
            func value() throws -> String {
                guard let value = rest.next() else { throw DriverError.usage("\(flag) needs a value.") }
                return value
            }
            switch flag {
            case "--run-tool": tool = try value()
            case "--input": inputs.append(URL(fileURLWithPath: try value()).standardizedFileURL)
            case "--output": output = URL(fileURLWithPath: try value(), isDirectory: true).standardizedFileURL
            case "--option":
                let pair = try value()
                guard let equals = pair.firstIndex(of: "=") else { throw DriverError.usage("--option needs key=value, got \(pair).") }
                options[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            case "--draw-window": drawWindow = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--vision-hang-width": visionHangWidth = Int(try value())
            case "--vision-limit": visionLimit = Double(try value())
            case "--lock-output": lockOutput = true
            case "--remember":
                let pair = try value()
                guard let equals = pair.firstIndex(of: "=") else { throw DriverError.usage("--remember needs key=value, got \(pair).") }
                remembered[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            case "--language":
                guard let chosen = AppLanguage(rawValue: try value()) else { throw DriverError.usage("--language needs en or de.") }
                language = chosen
            case "--max-seconds":
                guard let seconds = Double(try value()), seconds > 0 else { throw DriverError.usage("--max-seconds needs a number.") }
                maxSeconds = seconds
            case "--cancel-after":
                guard let seconds = Double(try value()) else { throw DriverError.usage("--cancel-after needs seconds.") }
                cancelAfter = seconds
            default:
                throw DriverError.usage("Unknown argument \(flag).")
            }
        }
        guard let tool else { throw DriverError.usage("--run-tool needs a tool.") }
        guard !inputs.isEmpty else { throw DriverError.usage("At least one --input is needed.") }
        guard let output else { throw DriverError.usage("--output is needed.") }
        return Arguments(tool: tool, inputs: inputs, output: output, options: options, cancelAfter: cancelAfter, drawWindow: drawWindow,
                         visionHangWidth: visionHangWidth, visionLimit: visionLimit, lockOutput: lockOutput, language: language, remembered: remembered,
                         maxSeconds: maxSeconds)
    }

    // MARK: Running

    /// Called first thing at launch. Returns false when the app was started normally.
    static func startIfRequested(_ arguments: [String] = CommandLine.arguments) -> Bool {
        let parsed: Arguments?
        do {
            parsed = try parse(arguments)
        } catch {
            finish(Result(tool: "?", status: "error", seconds: 0, inputs: [], outputs: [], messages: [error.localizedDescription], jobs: [],
                          longestMainThreadBlockSeconds: 0))
            return true
        }
        guard let parsed else { return false }
        // A test instance ends itself after a while, whatever happens; its windows never take a click.
        Watchdog.start(seconds: parsed.maxSeconds, what: "Testzugang")
        // Before anything logs: the log of a test run goes next to its results, not into the app's real log.
        try? FileManager.default.createDirectory(at: parsed.output.appendingPathComponent("logs"), withIntermediateDirectories: true)
        setenv(DiagnosticLog.redirectKey, parsed.output.appendingPathComponent("logs").path, 1)
        DiagnosticLog.start()
        DiagnosticLog.log(marker)
        NSApp.setActivationPolicy(.accessory)
        AppSettings.shared = AppSettings(defaults: InMemorySettings())
        AppSettings.shared.language = parsed.language
        if let tool = ToolID(rawValue: parsed.tool), !parsed.remembered.isEmpty { ToolMemory.remember(tool, parsed.remembered) }
        // A test run never deletes the app's prepared recognition model (the real cache on this Mac): it only reports that it would.
        RecognitionCheck.shared = RecognitionCheck(resetModel: { DiagnosticLog.log("test access: would remove the recognition model cache") },
                                                   store: InMemorySettings())
        JobRunner.shared.showsWindows = false
        SignatureShelf.testVault = MemorySignatureVault(start: parsed.options["signatures"].flatMap { path in
            (try? Data(contentsOf: URL(fileURLWithPath: path))).map { [SavedSignature(name: "Test", png: $0)] }
        } ?? [])
        Task { finish(await run(parsed)) }
        return true
    }

    static func run(_ arguments: Arguments) async -> Result {
        let started = Date()
        let watch = MainThreadWatch()
        if let width = arguments.visionHangWidth { VisionLimit.simulatedHang = { $0?.width == width } }
        if let limit = arguments.visionLimit { VisionLimit.seconds = limit }
        var result = Result(tool: arguments.tool, status: "error", seconds: 0, inputs: arguments.inputs.map(\.path), outputs: [], messages: [],
                            jobs: [], longestMainThreadBlockSeconds: 0)
        do {
            try FileManager.default.createDirectory(at: arguments.output, withIntermediateDirectories: true)
            let copies = try arguments.inputs.map { input -> URL in
                let copy = ConversionMatrix.uniqueURL(directory: arguments.output, baseName: ConversionMatrix.strippedBaseName(input.lastPathComponent),
                                                      suffix: "", ext: input.pathExtension)
                try FileManager.default.copyItem(at: input, to: copy)
                return copy
            }
            if arguments.lockOutput { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: arguments.output.path) }
            var options = Options(arguments.options)
            if ["ring", "more", "measureRing", "ringWords", "settings", "checksum", "hud", "intro", "introWindow", "float", "floatWindow",
                "terminalChoices"].contains(arguments.tool) {
                result.messages += try await RingDrawing.run(arguments.tool, files: copies, options: &options, picture: arguments.drawWindow)
                try options.checkAllUsed()
                if let picture = arguments.drawWindow { result.outputs = [picture.path] }
                result.status = "done"
                result.seconds = Date().timeIntervalSince(started)
                result.longestMainThreadBlockSeconds = watch.stop()
                return result
            }
            if let picture = arguments.drawWindow {
                guard let tool = ToolID(rawValue: arguments.tool) else { throw DriverError.usage("Unknown tool \(arguments.tool).") }
                let dark = options.string("appearance", default: "light") == "dark"
                var start: [String: String] = [:]
                for key in startKeys(for: tool) where arguments.options[key] != nil { start[key] = options.string(key, default: "") }
                try options.checkAllUsed()
                try await drawWindow(tool, files: copies, start: start, to: picture, dark: dark)
                result.outputs = [picture.path]
                result.status = "done"
                result.seconds = Date().timeIntervalSince(started)
                result.longestMainThreadBlockSeconds = watch.stop()
                return result
            }
            let started = try await start(arguments.tool, files: copies, options: &options, messages: &result.messages)
            try options.checkAllUsed()
            if let seconds = arguments.cancelAfter {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    started.forEach { JobRunner.shared.cancel($0) }
                }
            }
            while !started.allSatisfy(\.status.isFinished) { try await Task.sleep(for: .milliseconds(50)) }
            result.jobs = started.map(jobResult)
            result.outputs = started.flatMap(\.outputs).map(\.path)
            let statuses = Set(result.jobs.map(\.status))
            result.status = statuses.count == 1 ? statuses.first! : (statuses.contains("failed") ? "failed" : "mixed")
            if started.isEmpty { result.status = "done" }
        } catch {
            result.messages.append(error.localizedDescription)
        }
        result.seconds = Date().timeIntervalSince(started)
        result.longestMainThreadBlockSeconds = watch.stop()
        return result
    }

    private static func jobResult(_ job: Job) -> JobResult {
        let status: String
        var message: String?
        switch job.status {
        case .done: status = "done"; message = job.note
        case .cancelled: status = "cancelled"
        case .failed(let text): status = "failed"; message = text
        case .waiting, .running: status = "unfinished"
        }
        return JobResult(title: job.title, detail: job.detail, status: status, message: message, outputs: job.outputs.map(\.path))
    }

    private static func finish(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(result)) ?? Data("{\"status\":\"error\"}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        DiagnosticLog.flush()
        exit(result.status == "done" ? 0 : 1)
    }

    // MARK: The tools

    /// Starts the jobs of one tool exactly as its window's main button does, with the window's defaults unless an option says otherwise.
    static func start(_ tool: String, files: [URL], options: inout Options, messages: inout [String]) async throws -> [Job] {
        if tool == "convert" {
            let target = try options.value("to", FileFormat.self, default: nil)
            let before = Set(JobRunner.shared.jobs.map(\.id))
            JobRunner.shared.convert(files, to: target)
            return JobRunner.shared.jobs.filter { !before.contains($0.id) }
        }
        guard let id = ToolID(rawValue: tool) else {
            throw DriverError.usage("Unknown tool \(tool). Tools: convert, \(ToolID.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let formats = files.compactMap(FileFormat.detect)
        // preset=<key>: a preset of the tool's fan ("crop.16x9", "rotate.3", "compress.5mb", "video.720p"), as the ring runs it.
        let presetKey = options.string("preset", default: "")
        if !presetKey.isEmpty, let preset = RingPresets.presets(for: id, formats: formats).first(where: { $0.key == presetKey }) {
            guard preset.action != .customize else { throw DriverError.usage("customize opens the window.") }
            return RingPresets.jobs(preset, files: files).map { $0.start() }
        } else if !presetKey.isEmpty, !RingPresets.presets(for: id, formats: formats).isEmpty {
            throw DriverError.usage("No preset \(presetKey) for \(id.rawValue). Presets: \(RingPresets.presets(for: id, formats: formats).map(\.key).joined(separator: ", ")).")
        }
        guard id.applies(to: formats) else {
            throw DriverError.usage("\(id.title) is not offered for \(files.map(\.lastPathComponent).joined(separator: ", ")).")
        }
        let session = ToolSession(tool: id, files: files)
        // The tools that may run without their window are built exactly as Option at the drop builds them.
        if let quick = try await QuickRun.jobs(id, session: session, options: &options) {
            return quick.map { $0.start() }
        }
        let jobs: [ToolJob]
        switch id {
        case .editMetadata:
            let fields = await MetadataOps.read(session.primary)
            jobs = MetadataToolView.jobs(session, .init(edits: fields.filter(\.editable),
                                                        removeAll: try options.value("removeAll", Bool.self, default: false),
                                                        removeSensitive: try options.value("removeSensitive", Bool.self, default: false)))
        case .readQR:
            for url in files {
                switch await ReadQRToolView.codes(in: url) {
                case .success(let codes): messages += codes.map { "\(url.lastPathComponent)\($0.page.map { " page \($0)" } ?? ""): \($0.text)" }
                case .failure(let error): messages.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            jobs = []
        case .editImage:
            var adjustments = PhotoAdjustments()
            adjustments.exposure = try options.value("exposure", Double.self, default: adjustments.exposure)
            adjustments.brightness = try options.value("brightness", Double.self, default: adjustments.brightness)
            adjustments.contrast = try options.value("contrast", Double.self, default: adjustments.contrast)
            adjustments.saturation = try options.value("saturation", Double.self, default: adjustments.saturation)
            jobs = EditImageToolView.jobs(session, original: try await original(of: session), adjustments: adjustments)
        case .frameImage:
            let original = try await original(of: session)
            var frame = ImageOps.FrameOptions()
            frame.aspect = CGSize(width: original.width, height: original.height)
            frame.padding = try options.value("padding", Double.self, default: 0.08)
            frame.cornerRadius = try options.value("corner", Double.self, default: 24)
            frame.shadow = try options.value("shadow", Double.self, default: 24)
            frame.background = .color(.white)
            jobs = FrameImageToolView.jobs(session, original: original, frame: frame, format: ImageToolSupport.outputFormat(for: session.primary))
        case .cropImage:
            let original = try await original(of: session)
            jobs = CropImageToolView.jobs(session, original: original,
                                          rect: try options.rect("rect", default: centerHalf(CGSize(width: original.width, height: original.height))))
        case .redactImage:
            let original = try await original(of: session)
            let request = try findRequest(&options)
            if request.isEmpty {
                var redaction = Redaction(rect: try options.rect("rect", default: centerHalf(CGSize(width: original.width, height: original.height))))
                redaction.style = try options.value("style", RedactionStyle.self, default: .solid)
                jobs = RedactImageToolView.jobs(session, original: original, redactions: [redaction])
            } else {
                let finds = try await RedactionFinder.find(in: original, request: request)
                messages += finds.map { "found \($0.kindTitle): \($0.text)" }
                let faceStyle = try options.value("faceStyle", RedactionStyle.self, default: try options.value("style", RedactionStyle.self, default: .solid))
                let color = options.string("color", default: "black") == "red" ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(gray: 0, alpha: 1)
                let gone = RedactionFinder.gone(ticked: finds, left: [])
                jobs = RedactImageToolView.jobs(session, original: original, redactions: RedactImageToolView.redactions(of: finds, imageSize: CGSize(width: original.width, height: original.height), style: faceStyle, color: color),
                                                terms: gone.terms, parts: gone.parts)
            }
        case .trimVideo, .trimAudio:
            let duration = await MediaInfo.load(session.primary).duration
            let start = try options.value("start", Double.self, default: 0)
            let end = try options.value("end", Double.self, default: duration / 2)
            jobs = id == .trimVideo ? TrimVideoToolView.jobs(session, start: start, end: end) : TrimAudioToolView.jobs(session, start: start, end: end)
        case .cropVideo:
            let size = await MediaInfo.load(session.primary).naturalSize
            jobs = CropVideoToolView.jobs(session, rect: try options.rect("rect", default: centerHalf(size)), outputSize: nil)
        case .videoSnapshots:
            let duration = await MediaInfo.load(session.primary).duration
            jobs = VideoSnapshotsToolView.jobs(session, times: try options.list("times", default: [0, duration / 2]),
                                               format: try options.value("format", FileFormat.self, default: .png))
        case .splitVideo:
            let duration = await MediaInfo.load(session.primary).duration
            jobs = SplitVideoToolView.jobs(session, points: try options.list("points", default: [duration / 2]), duration: duration)
        case .redactVideo:
            let size = await MediaInfo.load(session.primary).naturalSize
            jobs = RedactVideoToolView.jobs(session, redactions: [Redaction(rect: try options.rect("rect", default: centerHalf(size)))], displaySize: size)
        case .redactAudio:
            let ranges = try options.list("ranges", default: [1, 2])
            guard ranges.count.isMultiple(of: 2) else { throw DriverError.usage("ranges needs start,end pairs.") }
            let bleeps = stride(from: 0, to: ranges.count, by: 2).map { AudioOps.BleepRange(start: ranges[$0], end: ranges[$0 + 1]) }
            jobs = RedactAudioToolView.jobs(session, ranges: bleeps, frequency: try options.value("frequency", Double.self, default: 1000))
        case .organizePDF:
            var pages: [PDFPageRef] = []
            for url in files {
                guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
                pages += (0..<document.pageCount).map { PDFPageRef(sourceIndex: $0, rotation: document.page(at: $0)?.rotation ?? 0, sourceURL: url) }
            }
            if let selection = try options.optionalList("selection") {
                jobs = [OrganizePDFToolView.selectionJob(session, chosen: selection.map { pages[Int($0) - 1] })]
            } else {
                let order = try options.list("order", default: pages.indices.map { Double($0 + 1) })
                jobs = OrganizePDFToolView.jobs(session, pages: order.map { pages[Int($0) - 1] })
            }
        case .redactPDF:
            // areas=page,x,y,width,height;… as fractions; skip=numbers of finds (from 1) left unticked.
            let result = try await RedactionFinder.find(inPDF: session.primary, request: try findRequest(&options))
            messages += result.finds.enumerated().map { "found \($0.offset + 1), page \($0.element.page + 1), \($0.element.kindTitle): \($0.element.text)" }
            messages += result.unreadPages.map { "not read: page \($0)" }
            let skip = Set(try options.list("skip", default: []).map { Int($0) - 1 })
            let areas = options.string("areas", default: "").split(separator: ";").compactMap { part -> PDFRedactor.Area? in
                let numbers = part.split(separator: ",").compactMap { Double($0) }
                return numbers.count == 5 ? PDFRedactor.Area(page: Int(numbers[0]), box: CGRect(x: numbers[1], y: numbers[2], width: numbers[3], height: numbers[4])) : nil
            }
            jobs = RedactPDFToolView.jobs(session, finds: result.finds.enumerated().filter { !skip.contains($0.offset) }.map(\.element),
                                          left: result.finds.enumerated().filter { skip.contains($0.offset) }.map(\.element), areas: areas)
        case .annotate:
            // marks=<JSON file>: a list of marks; only `kind` is needed, the rest has defaults.
            let data = try Data(contentsOf: URL(fileURLWithPath: options.string("marks", default: "")))
            let marks = try JSONDecoder().decode([Mark].self, from: data)
            let mode = try options.value("mode", AnnotationSaver.PDFMode.self, default: .comments)
            jobs = AnnotateToolView.jobs(session, marks: marks, mode: mode, original: session.primaryFormat == .pdf ? nil : try await original(of: session))
        case .signPDF:
            // marks=<JSON file>, as for annotate; a picture is its PNG in Base64.
            _ = options.string("signatures", default: "")
            let data = try Data(contentsOf: URL(fileURLWithPath: options.string("marks", default: "")))
            jobs = SignPDFToolView.jobs(session, marks: try JSONDecoder().decode([Mark].self, from: data))
        case .burnSubtitles:
            // subtitles=<file>; without it, the one next to the input is not there in a test run's copy.
            let subtitles = URL(fileURLWithPath: options.string("subtitles", default: ""))
            var burn = SubtitleBurner.Options()
            burn.style = try options.value("style", SubtitleBurner.Style.self, default: burn.style)
            burn.size = try options.value("size", SubtitleBurner.Size.self, default: burn.size)
            burn.position = try options.value("position", SubtitleBurner.Position.self, default: burn.position)
            burn.words = try options.value("words", SubtitleBurner.Words.self, default: burn.words)
            if let colour = BurnSubtitlesToolView.colour(options.string("color", default: "")) { burn.color = colour }
            if let colour = BurnSubtitlesToolView.colour(options.string("highlight", default: "")) { burn.highlight = colour }
            jobs = BurnSubtitlesToolView.jobs(session, subtitles: subtitles, options: burn, language: try options.value("language", Transcriber.Language.self, default: .german))
        case .comparePDF:
            guard files.count == 2 else { throw DriverError.usage("comparePDF needs two --input.") }
            guard case let (old?, new?) = ComparePDFToolView.oldAndNew(files) else { throw DriverError.usage("comparePDF needs two --input.") }
            let comparison = try await PDFComparison.compare(old, new)
            messages += PDFComparisonReport.summary(comparison)
            messages += comparison.changes.map { "\($0.kind.rawValue): [\($0.oldText)] -> [\($0.newText)]" }
            messages += comparison.pairs.map { "\(PDFComparisonReport.title(of: $0)): \($0.regions.count) places" }
            jobs = ComparePDFToolView.jobs(session, result: comparison)
        case .pdfPassword:
            guard options.string("password", default: "") == "-" else { throw DriverError.usage("pdfPassword reads the password from standard input: --option password=-") }
            let password = (readLine(strippingNewline: true) ?? "")
            jobs = PDFPasswordToolView.jobs(session, action: try options.value("action", PDFPassword.Action.self, default: PDFPassword.suggestedAction(for: files)),
                                            password: password)
        default:
            throw DriverError.usage("\(id.title) is not handled.")
        }
        return jobs.map { $0.start() }
    }

    /// terms=a|b, patterns=email,phone,iban,date, faces=true.
    private static func findRequest(_ options: inout Options) throws -> RedactionFinder.Request {
        var request = RedactionFinder.Request(terms: options.string("terms", default: "").split(separator: "|").map(String.init), faces: try options.value("faces", Bool.self, default: false))
        for name in options.string("patterns", default: "").split(separator: ",") {
            guard let pattern = RedactionFinder.Pattern(rawValue: String(name)) else { throw DriverError.usage("Unknown pattern \(name).") }
            request.patterns.insert(pattern)
        }
        return request
    }

    /// Options that set how a drawn window starts (read by the tool's view from `ToolSession.start`).
    static func startKeys(for tool: ToolID) -> [String] {
        switch tool {
        case .socialMedia: return ["preset", "window"]
        case .removeBackground: return ["subject"]
        case .videoPresets: return ["preset", "window"]
        case .redactPDF: return ["terms", "patterns", "faces"]
        case .redactImage: return ["terms", "patterns", "faces", "faceStyle", "style", "color", "areas"]
        case .annotate: return ["marks", "tool", "page", "selected", "mode"]
        case .comparePDF: return ["show"]
        case .burnSubtitles: return ["subtitles", "style", "size", "position", "words", "color", "highlight"]
        case .signPDF: return ["marks", "page", "selected", "create", "name", "font", "photo", "sensitivity", "signatures"]
        default: return []
        }
    }

    /// Builds the tool's window content off screen, lets it settle (previews load in the background) and draws it.
    static func drawWindow(_ tool: ToolID, files: [URL], start: [String: String], to picture: URL, dark: Bool) async throws {
        let session = ToolSession(tool: tool, files: files, start: start)
        let size = ToolWindowManager.preferredSize(for: tool)
        // The window's own background is not part of the view; drawn off screen it has to be put underneath.
        let hosting = NSHostingView(rootView: ToolRootView(session: session).environmentObject(AppSettings.shared)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.alphaValue = 0
        window.contentView = hosting
        window.orderFrontRegardless()
        // A window that looks for something at its start takes longer.
        try await Task.sleep(for: .seconds(start.isEmpty ? 2 : 12))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw DriverError.usage("Window could not be drawn.") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.orderOut(nil)
        try FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: picture)
    }

    /// The picture as the image tools load it (`ImageDocument`), once loaded.
    private static func original(of session: ToolSession) async throws -> CGImage {
        let document = ImageDocument(url: session.primary)
        while document.original == nil {
            if let error = document.error { throw DriverError.usage(error) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return document.original!
    }

    private static func centerHalf(_ size: CGSize) -> CGRect {
        CGRect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2).integral
    }

    // MARK: Options

    typealias Options = ToolOptions
}

/// Signatures for a test run: in memory, the keychain is not touched.
final class MemorySignatureVault: SignatureVault, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SavedSignature]
    init(start: [SavedSignature] = []) { list = start }
    func all() throws -> [SavedSignature] { lock.withLock { list } }
    func save(_ signature: SavedSignature) throws { lock.withLock { list.append(signature) } }
    func delete(_ id: UUID) throws { lock.withLock { list.removeAll { $0.id == id } } }
}

/// Settings for a test run: the app's defaults, nothing is written to its preferences.
private final class InMemorySettings: SettingsStore, @unchecked Sendable {
    private var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// Measures the longest time the main thread did not get to run (the window would have frozen that long).
@MainActor
final class MainThreadWatch {
    private var timer: Timer?
    private var last = Date()
    private var longest: TimeInterval = 0
    private let interval: TimeInterval = 0.01

    init() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        longest = max(longest, now.timeIntervalSince(last) - interval)
        last = now
    }

    func stop() -> TimeInterval {
        tick()
        timer?.invalidate()
        return max(0, longest)
    }
}
#endif
