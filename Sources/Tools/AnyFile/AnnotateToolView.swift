import AppKit
import PDFKit
import SwiftUI

/// Draws on a picture or the pages of a PDF. The look is plain for now: it comes with the app's own design later.
@MainActor
struct AnnotateToolView: View {
    let session: ToolSession
    @StateObject private var board = AnnotateBoard()
    @State private var picture: CGImage?
    @State private var original: CGImage?
    @State private var pageSize = CGSize.zero
    @State private var pageCount = 1
    @State private var failure: String?
    @State private var mode = AnnotationSaver.PDFMode.comments
    @State private var copied = false
    @State private var monitor: Any?

    private var isPDF: Bool { session.primaryFormat == .pdf }
    private static let swatches = [MarkColor.red, MarkColor(red: 1, green: 0.55, blue: 0), .yellow, MarkColor(red: 0.1, green: 0.65, blue: 0.2), MarkColor(red: 0.1, green: 0.35, blue: 0.95), MarkColor(red: 0, green: 0, blue: 0), MarkColor(red: 1, green: 1, blue: 1)]

    var body: some View {
        ToolShell(session: session, saveEnabled: !board.marks.isEmpty && failure == nil, onSave: save) {
            VStack(spacing: 8) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let picture, pageSize.width > 0 {
                        AnnotateCanvas(board: board, picture: picture, pageSize: pageSize).padding(12)
                    } else {
                        LoadingOrError(error: failure)
                    }
                }
                if pageCount > 1 {
                    HStack {
                        Button { board.page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(board.page == 0)
                        Text(tr("Page \(board.page + 1) of \(pageCount)", "Seite \(board.page + 1) von \(pageCount)")).font(.callout.monospacedDigit())
                        Button { board.page += 1 } label: { Image(systemName: "chevron.right") }.disabled(board.page >= pageCount - 1)
                    }
                    .padding(.bottom, 8)
                }
            }
        } sidebar: {
            toolsSection
            styleSection
            SidebarSection(title: tr("Steps", "Schritte")) {
                HStack {
                    Button { board.undo() } label: { Label(tr("Undo", "Widerrufen"), systemImage: "arrow.uturn.backward") }.disabled(!board.canUndo).help(tr("Undo (⌘Z)", "Widerrufen (⌘Z)"))
                    Button { board.redo() } label: { Label(tr("Redo", "Wiederholen"), systemImage: "arrow.uturn.forward") }.disabled(!board.canRedo).help(tr("Redo (⇧⌘Z)", "Wiederholen (⇧⌘Z)"))
                }
                .controlSize(.small)
                Button(tr("Delete selected", "Auswahl löschen")) { board.deleteSelected() }.controlSize(.small).disabled(board.selected == nil).help(tr("Delete (⌫)", "Löschen (⌫)"))
            }
            if isPDF {
                SidebarSection(title: tr("Save as", "Sichern als")) {
                    Picker("", selection: $mode) {
                        ForEach(AnnotationSaver.PDFMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(mode == .comments ? tr("Can still be changed in Preview. The PDF's text stays searchable. Numbers and magnifiers can be moved, resized and deleted, but keep their content.", "Lässt sich in Vorschau noch ändern. Der Text des PDFs bleibt durchsuchbar. Nummern und Lupen lassen sich verschieben, in der Größe ändern und löschen, ihr Inhalt bleibt aber gleich.")
                         : tr("Part of the page: nobody can change or remove them. The PDF's text stays searchable.", "Teil der Seite: Niemand kann sie ändern oder entfernen. Der Text des PDFs bleibt durchsuchbar."))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SidebarSection(title: tr("Clipboard", "Zwischenablage")) {
                    Button(copied ? tr("Copied", "Kopiert") : tr("Copy to clipboard", "In die Zwischenablage kopieren"), action: copy).disabled(original == nil)
                }
            }
        }
        .task(id: board.page) { await loadPage() }
        .onAppear(perform: start)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private var toolsSection: some View {
        SidebarSection(title: tr("Tools", "Werkzeuge")) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach(AnnotateBoard.Tool.allCases) { tool in
                    Button {
                        board.perform(.tool(tool))
                    } label: {
                        // The whole button, not only the symbol.
                        Image(systemName: tool.symbol).frame(maxWidth: .infinity, minHeight: 26).contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .background(board.tool == tool ? Theme.accent.opacity(0.3) : Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .help("\(tool.title) (\(String(tool.key).uppercased()))")
                }
            }
            Text(tr("\(board.tool.title) · key \(String(board.tool.key).uppercased())", "\(board.tool.title) · Taste \(String(board.tool.key).uppercased())")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var styleSection: some View {
        SidebarSection(title: tr("Style", "Stil")) {
            HStack(spacing: 5) {
                ForEach(Self.swatches, id: \.self) { swatch in
                    Button { board.setColor(swatch) } label: {
                        Circle().fill(Color(nsColor: swatch.nsColor()))
                            .overlay(Circle().stroke(board.shownColor == swatch ? Theme.accentForeground : Color.secondary.opacity(0.4), lineWidth: board.shownColor == swatch ? 2 : 1))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                }
            }
            ColorSwatchPicker(title: tr("Other color", "Andere Farbe"), color: Binding(get: { Color(nsColor: board.shownColor.nsColor()) }, set: { board.setColor(MarkColor($0.nsColor)) }))
            LabeledSlider(title: tr("Line", "Linie"), value: Binding(get: { Double(board.shownLineWidth) }, set: { board.setLineWidth(CGFloat($0)) }), range: board.isHighlighting ? 6...40 : 1...20, format: { String(format: "%.0f", $0) })
            LabeledSlider(title: tr("Text size", "Textgröße"), value: Binding(get: { Double(board.shownFontSize) }, set: { board.setFontSize(CGFloat($0)) }), range: 8...72, format: { String(format: "%.0f", $0) })
            if board.tool == .magnifier || board.selectedMark?.kind == .magnifier {
                LabeledSlider(title: tr("Zoom", "Vergrößerung"), value: Binding(get: { Double(board.shownZoom) }, set: { board.setZoom(CGFloat($0)) }), range: 1.5...5, format: { String(format: "%.1f×", $0) })
            }
        }
    }

    private func start() {
        if let path = session.start["marks"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let marks = try? JSONDecoder().decode([Mark].self, from: data) {
            board.setMarksForDrawing(marks)
        }
        if let tool = session.start["tool"].flatMap(AnnotateBoard.Tool.init(rawValue:)) { board.tool = tool }
        if let page = session.start["page"].flatMap(Int.init) { board.page = page }
        if let index = session.start["selected"].flatMap(Int.init), board.marks.indices.contains(index) { board.selected = board.marks[index].id }
        if session.start["mode"] == "burned" { mode = .burned }
        monitor = Self.watchKeys(of: board, windowID: session.id.uuidString)
    }

    /// Letters and ⌘Z belong to the board, unless a text is being written.
    static func watchKeys(of board: AnnotateBoard, windowID: String) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak board] event in
            guard let board, event.window?.identifier?.rawValue == windowID else { return event }
            if (event.window?.firstResponder as? NSText) != nil {
                if event.keyCode == 53 || (event.keyCode == 36 && event.modifierFlags.contains(.command)) {
                    event.window?.makeFirstResponder(nil)
                    board.finishEditing()
                    return nil
                }
                return event
            }
            guard let command = AnnotateBoard.command(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modifiers: event.modifierFlags, selection: board.selected != nil) else { return event }
            board.perform(command)
            return nil
        }
    }

    private func loadPage() async {
        let url = session.primary, number = board.page, pdf = isPDF
        let result = await Task.detached { () -> Result<(CGImage, CGImage?, CGSize, Int), Error> in
            Result {
                if pdf {
                    let document = try AnnotationSaver.open(url)
                    let (image, size) = try AnnotationSaver.picture(ofPage: number, in: url, dpi: 200)
                    return (image, nil, size, document.pageCount)
                }
                let full = try ImageIOBridge.load(url)
                return (ImageIOBridge.resized(full, longEdge: 2400), full, CGSize(width: full.width, height: full.height), 1)
            }
        }.value
        switch result {
        case .success(let (image, full, size, pages)):
            picture = image
            if let full { original = full }
            pageSize = size
            pageCount = pages
            board.pageCount = pages
            board.pageSize = size
            // A picture is treated like an A4 page: a line of 3 looks the same on a screenshot and on a photo.
            board.unit = pdf ? 1 : max(size.width, size.height) / 842
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    private func copy() {
        guard let original else { return }
        let marks = board.marks
        Task.detached {
            guard let image = AnnotationSaver.render(original, marks: marks) else { return }
            try? AnnotationSaver.copy(image)
            await MainActor.run {
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
    }

    private func save() {
        board.finishEditing()
        guard !board.marks.isEmpty else { return }
        session.start(Self.jobs(session, marks: board.marks, mode: mode, original: original))
    }

    static func jobs(_ session: ToolSession, marks: [Mark], mode: AnnotationSaver.PDFMode, original: CGImage?) -> [ToolJob] {
        let url = session.primary
        if session.primaryFormat == .pdf {
            let destination = session.outputURL(suffix: tr("annotated", "annotiert"), ext: "pdf")
            return [session.job(detail: url.lastPathComponent) { progress in
                return [try await StagingArea.writing(destination) { destination in
                    try AnnotationSaver.save(url, marks: marks, mode: mode, to: destination, progress: progress)
                }]
            }]
        }
        guard let original else { return [] }
        let format = AnnotationSaver.outputFormat(for: url, image: original)
        let destination = session.outputURL(suffix: tr("annotated", "annotiert"), ext: format.fileExtension)
        let quality = AppSettings.shared.jpegQuality
        let metadata = ImageIOBridge.properties(url)
        return [session.job(detail: url.lastPathComponent) { progress in
            guard let image = AnnotationSaver.render(original, marks: marks) else { throw AppError.encodeFailed(tr("Rendering failed", "Bild konnte nicht erstellt werden")) }
            progress(0.6)
            return [try await StagingArea.writing(destination) { destination in
                try await AnnotationSaver.save(image, metadata: metadata, to: destination, format: format, quality: quality)
            }]
        }]
    }
}

/// The page, the marks over it, handles, and the text being written.
struct AnnotateCanvas: View {
    @ObservedObject var board: AnnotateBoard
    let picture: CGImage
    let pageSize: CGSize
    @FocusState private var writing: Bool

    var body: some View {
        GeometryReader { proxy in
            let fit = FitGeometry(container: proxy.size, image: pageSize)
            let source = MarkPainter.Source(picture: picture, size: pageSize)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(nsImage: ImageOps.nsImage(picture))
                    .resizable().interpolation(.high)
                    .frame(width: fit.displayRect.width, height: fit.displayRect.height)
                    .offset(x: fit.displayRect.minX, y: fit.displayRect.minY)
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.translateBy(x: fit.displayRect.minX, y: fit.displayRect.minY)
                        cg.scaleBy(x: fit.scale, y: fit.scale)
                        cg.clip(to: CGRect(origin: .zero, size: pageSize))
                        for mark in board.marksOnPage { MarkPainter.draw(mark, in: cg, source: source) }
                        if let live = board.live { MarkPainter.draw(live, in: cg, source: source) }
                    }
                    if let mark = board.selectedMark, mark.page == board.page {
                        let box = fit.toDisplay(mark.kind == .arrow ? .zero : mark.bounds)
                        if mark.kind != .arrow {
                            context.stroke(Path(box), with: .color(Theme.accentForeground), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        for handle in mark.handles {
                            let point = CGPoint(x: fit.displayRect.minX + handle.x * fit.scale, y: fit.displayRect.minY + handle.y * fit.scale)
                            let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                            context.fill(dot, with: .color(.white))
                            context.stroke(dot, with: .color(Theme.accentForeground), lineWidth: 1.5)
                        }
                    }
                }
                .allowsHitTesting(false)
                if let editing = board.editing {
                    let shown = fit.toDisplay(editing.frame)
                    let width = max(shown.width, 220), height = max(CGFloat(board.editing?.text.filter(\.isNewline).count ?? 0) + 2, 2) * editing.fontSize * fit.scale * 1.35
                    TextEditor(text: Binding(get: { board.editing?.text ?? "" }, set: { board.setEditedText($0) }))
                        .font(.custom("Helvetica", size: editing.fontSize * fit.scale))
                        .foregroundStyle(Color(nsColor: editing.color.nsColor()))
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .focused($writing)
                        .frame(width: width, height: height)
                        .overlay(Rectangle().stroke(Theme.accentForeground, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .offset(x: shown.minX, y: shown.minY)
                        .onAppear { writing = true }
                        .onDisappear { writing = false }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        board.pointSize = 1 / max(fit.scale, 0.0001)
                        if value.translation == .zero || !isDragging {
                            isDragging = true
                            board.press(at: fit.toImage(value.startLocation))
                        }
                        board.dragged(to: fit.toImage(value.location))
                    }
                    .onEnded { _ in
                        isDragging = false
                        board.released()
                    }
            )
            .onAppear { board.pointSize = 1 / max(fit.scale, 0.0001) }
        }
    }

    @State private var isDragging = false
}
