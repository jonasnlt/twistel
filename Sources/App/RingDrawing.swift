#if DEBUG
import AppKit
import SwiftUI

/// Test access for the rings (debug builds only), through `ToolDriver`:
///
///     --run-tool ring --input <file> … --output <folder> --draw-window <picture.png> [--option ring=tools] [--option count=8]
///                     [--option highlight=2] [--option style=glass|solid|contrast] [--option appearance=dark] [--language de]
///                     [--option name=below|above] [--option preview=true] [--option items=pageNumbersPDF,watermarkPDF]
///     --run-tool more --input <file> … --output <folder> --draw-window <picture.png> [--option ring=tools] [--option text=pa]
///     --run-tool measureRing --input <file> … --output <folder> [--option ring=tools] [--option times=30]
///     --run-tool ringWords --input <file> --output <folder>      (the table of short words, as Markdown)
///     --run-tool float --input <file> … --output <folder> --draw-window <picture.png> [--option state=hover|drop] [--option expanded=true] [--option appearance=dark]
///     --run-tool floatWindow --input <file> … --output <folder>  (the real floating window, see-through: focus, level, one by one, removing down to one picture)
///     --run-tool terminalChoices --input <file> … --output <folder>  (the terminal programs offered and the folders for the files)
@MainActor
enum RingDrawing {
    /// --option access=contrast: drawn as with "Increase contrast" (solid surfaces with strong edges, the contrast tones). Without it,
    /// and with access=transparency, surfaces are drawn solid, as with "Reduce transparency": real glass can't be drawn into a picture.
    static var highContrast = false

    static func drawnStyle() -> RingStyle { .solid(strongEdges: highContrast) }

    static func run(_ what: String, files: [URL], options: inout ToolDriver.Options, picture: URL?) async throws -> [String] {
        highContrast = options.string("access", default: "") == "contrast"
        Theme.drawingWithIncreasedContrast = highContrast
        let ring = try options.value("ring", RingKind.self, default: .tools)
        let count = try options.value("count", Int.self, default: RingBuilder.standardCount)
        AppSettings.shared.ringItemCount = count
        // fill=1: every item of the kind is a favourite, so the ring has exactly `count` places (to judge sizes).
        if try options.value("fill", Bool.self, default: false), let format = files.first.flatMap(FileFormat.detect) {
            let kind = ring == .actions ? FileKind.any : FileKind.of(format)
            var list = AppSettings.shared.favoriteList(ring, kind)
            list.enabled = Set(list.order)
            AppSettings.shared.setFavoriteList(list, ring, kind)
        }
        // items=a,b,…: exactly these tools (by their ID), in this order, are the ring's items (to look at particular words).
        let items = options.string("items", default: "").split(separator: ",").map { "tool.\($0)" }
        if !items.isEmpty, let format = files.first.flatMap(FileFormat.detect) {
            let kind = ring == .actions ? FileKind.any : FileKind.of(format)
            var list = AppSettings.shared.favoriteList(ring, kind)
            list.order = items + list.order.filter { !items.contains($0) }
            list.enabled = Set(items)
            AppSettings.shared.setFavoriteList(list, ring, kind)
        }
        switch what {
        case "ring":
            guard let picture else { throw ToolDriver.DriverError.usage("ring needs --draw-window <picture.png>.") }
            let highlight = try options.value("highlight", Int.self, default: -1)
            let style = options.string("style", default: "glass")
            let dark = options.string("appearance", default: "light") == "dark"
            let view = RadialView(frame: NSRect(x: 0, y: 0, width: RadialWheelView.side, height: RadialWheelView.side))
            let layout = RadialController.fill(view, ring: ring, urls: files, settings: AppSettings.shared)
            if highlight >= 0 { view.highlight(highlight) }
            var content = view.content
            content.style = style == "glass" ? .glass : .solid(strongEdges: style == "contrast" || highContrast)
            let side = RadialWheelView.side
            // preview=true: the picture Finder drags along under the pointer (the middle of the ring), to judge what it covers.
            let preview = try options.value("preview", Bool.self, default: false)
            let dragged = NSWorkspace.shared.icon(forFile: files[0].path)
            try await draw(RadialWheelView(content: content)
                .overlay { if preview { Image(nsImage: dragged).resizable().frame(width: 128, height: 128).opacity(0.8).offset(x: 14, y: 18) } }
                .background(Backdrop(dark: dark)), size: CGSize(width: side, height: side), dark: dark, to: picture)
            return layout.slots.map { "\($0.shortLabel) | \($0.title)\($0.missing.map { " (needs \($0.name))" } ?? "")" }
        case "more":
            guard let picture else { throw ToolDriver.DriverError.usage("more needs --draw-window <picture.png>.") }
            let dark = options.string("appearance", default: "light") == "dark"
            let text = options.string("text", default: "")
            let view = RadialView(frame: .zero)
            let layout = RadialController.fill(view, ring: ring, urls: files, settings: AppSettings.shared)
            let label = files.count == 1 ? files[0].lastPathComponent : tr("\(files.count) files", "\(files.count) Dateien")
            let model = MoreListModel(entries: layout.all, title: ring.title, files: label, text: text)
            try await draw(MoreListView(model: model) { _, _ in }.background(Color(nsColor: .windowBackgroundColor)), size: MoreListView.size, dark: dark, to: picture)
            return model.shown.map(\.title)
        case "measureRing":
            return try await measure(ring: ring, files: files, times: try options.value("times", Int.self, default: 30))
        case "ringWords":
            return [wordTable()]
        case "checksum":
            guard let picture else { throw ToolDriver.DriverError.usage("checksum needs --draw-window <picture.png>.") }
            let model = ChecksumModel(files: files)
            model.expected = options.string("expected", default: "")
            while model.rows.contains(where: { $0.sum == nil && $0.error == nil }) { try await Task.sleep(for: .milliseconds(50)) }
            try await draw(ChecksumView(model: model).background(Color(nsColor: .windowBackgroundColor)), size: CGSize(width: 560, height: 120 + 70 * files.count),
                           dark: options.string("appearance", default: "light") == "dark", to: picture)
            return model.rows.compactMap(\.sum)
        case "hud":
            // state=running|unknown|many|done|compressed|failed|cancelled|several|note
            guard let picture else { throw ToolDriver.DriverError.usage("hud needs --draw-window <picture.png>.") }
            let state = options.string("state", default: "done")
            let dark = options.string("appearance", default: "light") == "dark"
            func job(_ status: Job.Status, title: String = tr("Compressing", "Verkleinern"), detail: String = files[0].lastPathComponent, outputs: [URL] = []) -> Job {
                let job = Job(title: title, detail: detail, symbol: ToolID.compress.symbol)
                job.status = status
                job.outputs = outputs
                job.inputs = [files[0]]
                job.startedAt = Date().addingTimeInterval(-3)
                job.lastReportAt = Date()
                job.outputIdentities = Dictionary(outputs.compactMap { url in ResultUndo.Identity(url).map { (url, $0) } }, uniquingKeysWith: { a, _ in a })
                return job
            }
            let output = files.count > 1 ? files[1] : files[0]
            let view: AnyView
            switch state {
            case "running", "unknown", "many":
                let running = job(.running, title: tr("Recognizing text", "Text erkennen"))
                running.progress = state == "unknown" ? 0 : 0.42
                running.step = state == "unknown" ? nil : tr("Page 3 of 7", "Seite 3 von 7")
                var jobs = [running]
                if state == "many" { jobs += [job(.done, outputs: [output]), job(.waiting)] }
                view = AnyView(ProgressPill(jobs: jobs, cancel: {}).padding(8).modifier(HUDSurface(style: drawnStyle())).padding(12))
            default:
                var jobs: [Job]
                switch state {
                case "compressed":
                    let done = job(.done, outputs: [output])
                    done.reportsSizes = true
                    jobs = [done]
                case "failed": jobs = [job(.failed(tr("There isn\u{2019}t enough free space on the disk to save the result. Free up some space and try again.",
                                                      "Auf dem Laufwerk ist nicht genug Platz für das Ergebnis. Bitte Platz schaffen und erneut versuchen.")))]
                case "cancelled": jobs = [job(.cancelled)]
                case "note":
                    let done = job(.done, outputs: [output])
                    done.note = tr("Page 2 could not be read and was left as it was.", "Seite 2 ließ sich nicht lesen und blieb, wie sie war.")
                    jobs = [done]
                case "several": jobs = (0..<12).map { _ in job(.done, outputs: [output]) }
                default: jobs = [job(.done, outputs: [output])]
                }
                view = AnyView(ResultCard(model: ResultCardModel(jobs: jobs), undoMessage: nil, close: {}, undo: {}, glass: false).padding(8)
                    .modifier(HUDSurface(style: drawnStyle())).padding(12))
            }
            // As in the app (`NotchHUDView`): the pill shows while another app is in front, its colours stay those of an active window.
            try await draw(view.environment(\.appearsActive, true).background(Backdrop(dark: dark)), size: CGSize(width: 380, height: state.hasPrefix("running") || state == "unknown" || state == "many" ? 100 : (state == "failed" ? 150 : 130)), dark: dark, to: picture)
            return []
        case "intro":
            guard let picture else { throw ToolDriver.DriverError.usage("intro needs --draw-window <picture.png>.") }
            let model = IntroductionModel(practiceFile: IntroductionModel.makePracticeFile(in: files[0].deletingLastPathComponent().appendingPathComponent("practice")))
            if options.string("seen", default: "") == "convert" { model.ringOpened(.convert, files: model.practiceFile.map { [$0] } ?? []) }
            try await draw(IntroductionView(model: model, close: {}).environmentObject(AppSettings.shared).background(Color(nsColor: .windowBackgroundColor)),
                           size: CGSize(width: 600, height: 470), dark: options.string("appearance", default: "light") == "dark", to: picture)
            return []
        case "introWindow":
            // The real window, as the menu bar opens it, kept invisible; it must survive a few display cycles and keep its size.
            // --option window=checksum: the checksum panel instead, which sizes itself the same way.
            let window: NSWindow
            if options.string("window", default: "intro") == "checksum" {
                ChecksumPanel.show(files)
                guard let panel = NSApp.windows.last(where: { $0 is ChecksumPanel && $0.isVisible }) else { throw ToolDriver.DriverError.usage("No checksum panel.") }
                window = panel
            } else {
                IntroductionWindow.shared.show()
                guard let shown = IntroductionWindow.shared.window else { throw ToolDriver.DriverError.usage("No introduction window.") }
                window = shown
            }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            var sizes: [CGSize] = []
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(100))
                sizes.append(window.frame.size)
            }
            if let picture, let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: picture)
            }
            window.close()
            return ["\(Int(sizes[0].width))x\(Int(sizes[0].height))", Set(sizes.map { "\($0)" }).count == 1 ? "steady" : "changing"]
        case "float":
            guard let picture else { throw ToolDriver.DriverError.usage("float needs --draw-window <picture.png>.") }
            let dark = options.string("appearance", default: "light") == "dark"
            let model = FloatShelfModel(files: files)
            let state = options.string("state", default: "")
            model.hovering = state == "hover"
            model.dropTargeted = state == "drop"
            if state == "hover" { model.hoveredFile = model.files.first }
            if try options.value("expanded", Bool.self, default: false) { model.setExpanded(true) }
            // selected=N: the file chosen with the arrow keys; focused=true: the window has the keyboard.
            let selected = try options.value("selected", Int.self, default: -1)
            if model.files.indices.contains(selected) { model.selection = model.files[selected] }
            model.focused = try options.value("focused", Bool.self, default: false)
            await model.waitForThumbnails()
            let shelf = FloatShelfView.size(expanded: model.expanded, count: model.files.count)
            let size = CGSize(width: shelf.width + 80, height: shelf.height + 60)
            try await draw(FloatShelfView(model: model, close: {}, style: drawnStyle()).frame(width: shelf.width, height: shelf.height)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                .frame(width: size.width, height: size.height).background(Backdrop(dark: dark)), size: size, dark: dark, to: picture)
            return [model.title, model.accessibilityLabel]
        case "floatWindow":
            // The real window, see-through: no focus, floats everywhere; opens one by one (top edge kept); the x of each file takes it
            // out of the window only, the last one closes it.
            let wasActive = NSApp.isActive
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let panel = FloatShelf.show(Array(files.prefix(1)), at: NSPoint(x: screen.midX, y: screen.midY), visible: false)
            try await Task.sleep(for: .milliseconds(300))
            var lines = ["shown=\(panel.isVisible)", "key=\(panel.isKeyWindow)", "appActivated=\(!wasActive && NSApp.isActive)",
                         "level=\(panel.level == .floating ? "floating" : "\(panel.level.rawValue)")",
                         "allSpaces=\(panel.collectionBehavior.contains(.canJoinAllSpaces))", "fullScreen=\(panel.collectionBehavior.contains(.fullScreenAuxiliary))",
                         "nonactivating=\(panel.styleMask.contains(.nonactivatingPanel))", "hidesOnDeactivate=\(panel.hidesOnDeactivate)",
                         "onScreen=\(NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) })",
                         "clickThrough=\(panel.ignoresMouseEvents)"]
            panel.model.add(Array(files.dropFirst()))
            lines.append("files=\(panel.model.files.count)")
            let top = panel.frame.maxY
            // The window grows and shrinks with a short animation: wait until it has settled (at most 2 s), then look.
            func settled(at size: CGSize) async throws -> Bool {
                for _ in 0..<40 where panel.frame.size != size { try await Task.sleep(for: .milliseconds(50)) }
                return panel.frame.size == size
            }
            panel.model.setExpanded(true)
            let open = FloatShelfView.size(expanded: true, count: panel.model.files.count)
            let grew = try await settled(at: open)
            lines.append("expanded=\(grew && abs(panel.frame.maxY - top) < 1)")
            lines.append("expandedFrame=\(Int(panel.frame.width))x\(Int(panel.frame.height)) want \(Int(open.width))x\(Int(open.height)), top moved \(Int(panel.frame.maxY - top))")
            let before = files.map { (try? Data(contentsOf: $0)) ?? Data() }
            for file in panel.model.files.dropLast() { panel.model.remove(file) }
            // One file left: its picture again, not a list of one.
            let shrank = try await settled(at: FloatShelfView.collapsedSize)
            lines.append("shrunk=\(shrank && panel.isVisible)")
            panel.model.remove(panel.model.files[0])
            lines.append("closed=\(!panel.isVisible && !FloatShelf.panels.contains { $0 === panel })")
            let after = files.map { (try? Data(contentsOf: $0)) ?? Data() }
            lines.append("originals=\(before == after && files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? "untouched" : "changed")")
            return lines
        case "terminalChoices":
            let choices = TerminalAction.choices(current: AppSettings.shared.terminalApp)
            var lines = choices.map { program in
                let app = TerminalAction.appURL(program.id)
                return "\(program.name) (\(program.id)): \(app?.path ?? "not installed"), folders=\(app.map { TerminalAction.acceptsFolders($0) } ?? false)"
            }
            lines += TerminalAction.folders(for: files).map { "folder: \($0.path)" }
            return lines
        case "settings":
            guard let picture else { throw ToolDriver.DriverError.usage("settings needs --draw-window <picture.png>.") }
            let dark = options.string("appearance", default: "light") == "dark"
            let model = SettingsTabModel()
            if let tab = SettingsTab(rawValue: options.string("tab", default: model.tab.rawValue)) { model.tab = tab }
            let view = SettingsView(model: model).environmentObject(AppSettings.shared).background(Color(nsColor: .windowBackgroundColor))
            try await draw(view, size: CGSize(width: SettingsView.width, height: model.tab.height), dark: dark, to: picture)
            return []
        default:
            throw ToolDriver.DriverError.usage("Unknown ring command \(what).")
        }
    }

    /// Something to look through the glass at: a calm desktop-like gradient with a few shapes.
    struct Backdrop: View {
        let dark: Bool
        var body: some View {
            ZStack {
                LinearGradient(colors: dark ? [Color(white: 0.15), Color(red: 0.1, green: 0.14, blue: 0.24)] : [Color(red: 0.86, green: 0.9, blue: 0.96), Color(red: 0.95, green: 0.92, blue: 0.88)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: 10).fill(dark ? Color(white: 0.22) : .white).frame(width: 260, height: 170).offset(x: -90, y: -70)
                Circle().fill(Color.blue.opacity(0.35)).frame(width: 120).offset(x: 120, y: 110)
            }
        }
    }

    static func draw<V: View>(_ view: V, size: CGSize, dark: Bool, to picture: URL) async throws {
        // Drawn as an active window, as the person sees it while using it (an inactive window greys its controls).
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).environment(\.appearsActive, true))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: highContrast ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua))
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = hosting
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(600))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ToolDriver.DriverError.usage("Could not draw.") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.orderOut(nil)
        try FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: picture)
    }

    /// From asking for the ring to the ring drawn on screen, `times` times; the first is without the panel made beforehand.
    static func measure(ring: RingKind, files: [URL], times: Int) async throws -> [String] {
        let controller = RadialController()
        // Shown to be measured, but it never takes a click.
        controller.passive = true
        let point = NSPoint(x: (NSScreen.main?.frame.midX ?? 600), y: (NSScreen.main?.frame.midY ?? 400))
        var durations: [Double] = []
        for _ in 0..<max(1, times) {
            let start = Date()
            controller.present(urls: files, at: point, ring: ring)
            controller.displayNow()
            CATransaction.flush()
            durations.append(Date().timeIntervalSince(start) * 1000)
            try await Task.sleep(for: .milliseconds(80))
            controller.hide()
            try await Task.sleep(for: .milliseconds(40))
        }
        let warm = Array(durations.dropFirst()).sorted()
        let median = warm.isEmpty ? durations[0] : warm[warm.count / 2]
        let worst = warm.last ?? durations[0]
        let prepared = RadialController()
        prepared.passive = true
        prepared.prepare()
        let start = Date()
        prepared.present(urls: files, at: point, ring: ring)
        prepared.displayNow()
        CATransaction.flush()
        let firstPrepared = Date().timeIntervalSince(start) * 1000
        prepared.hide()
        return [String(format: "first ring without preparing: %.1f ms", durations[0]),
                String(format: "first ring with the panel prepared at launch: %.1f ms", firstPrepared),
                String(format: "following rings: median %.1f ms, slowest %.1f ms (%d times)", median, worst, warm.count),
                "plus up to 17 ms until the drag monitor notices the keys (it looks 60 times a second during a drag)"]
    }

    /// Every short word and full name in both languages, as a Markdown table.
    static func wordTable() -> String {
        let saved = AppLanguage.current
        defer { AppLanguage.current = saved }
        func both(_ text: () -> String) -> (String, String) {
            AppLanguage.current = .german
            let german = text()
            AppLanguage.current = .english
            return (german, text())
        }
        var lines = ["| Ring | Deutsch kurz | Deutsch voll | Englisch kurz | Englisch voll |", "| --- | --- | --- | --- | --- |"]
        for format in FileFormat.allCases where ConversionMatrix.totalConversions > 0 && FileFormat.allCases.contains(where: { ConversionMatrix.targets(for: $0).contains(format) }) {
            let short = both { RingWords.formatLabel(format) }
            let full = both { RingWords.convertTitle(format, from: []) }
            lines.append("| \(both { RingKind.convert.title }.0) | \(short.0) | \(full.0) | \(short.1) | \(full.1) |")
        }
        lines.append("| \(both { RingKind.convert.title }.0) | DOCX | \(both { RingWords.convertTitle(.docx, from: [.jpg]) }.0) | DOCX | \(both { RingWords.convertTitle(.docx, from: [.jpg]) }.1) |")
        for tool in ToolID.allCases {
            let short = both { RingWords.toolLabel(tool) }
            let full = both { tool.title }
            lines.append("| \(both { RingKind.tools.title }.0) | \(short.0) | \(full.0) | \(short.1) | \(full.1) |")
        }
        for action in FileAction.allCases {
            let short = both { action.shortLabel }
            let full = both { action.title }
            lines.append("| \(both { RingKind.actions.title }.0) | \(short.0) | \(full.0) | \(short.1) | \(full.1) |")
        }
        let more = both { RingWords.moreLabel }
        let moreTitle = both { RingWords.moreTitle }
        lines.append("| alle | \(more.0) | \(moreTitle.0) | \(more.1) | \(moreTitle.1) |")
        return lines.joined(separator: "\n")
    }
}
#endif
