import AppKit
import PDFKit
import SwiftUI

/// The signatures kept on this Mac. Loading may wait for the keychain, so it does not happen on the main thread.
@MainActor
final class SignatureShelf: ObservableObject {
    @Published var signatures: [SavedSignature] = []
    @Published var problem: String?
    private let vault: SignatureVault
    #if DEBUG
    /// Test runs never touch the real keychain.
    nonisolated(unsafe) static var testVault: SignatureVault?
    #endif

    init(vault: SignatureVault? = nil) {
        #if DEBUG
        self.vault = vault ?? Self.testVault ?? KeychainSignatureVault()
        #else
        self.vault = vault ?? KeychainSignatureVault()
        #endif
    }

    func load() {
        let vault = vault
        Task.detached {
            let outcome = Result { try vault.all() }
            await MainActor.run {
                switch outcome {
                case .success(let list): self.signatures = list
                case .failure(let error): self.problem = error.localizedDescription
                }
            }
        }
    }

    func keep(_ signature: SavedSignature) {
        signatures.append(signature)
        let vault = vault
        Task.detached {
            do {
                try vault.save(signature)
            } catch {
                await MainActor.run { self.problem = error.localizedDescription }
            }
        }
    }

    func remove(_ id: UUID) {
        signatures.removeAll { $0.id == id }
        let vault = vault
        Task.detached { try? vault.delete(id) }
    }
}

@MainActor
struct SignPDFToolView: View {
    let session: ToolSession
    @StateObject private var board = AnnotateBoard()
    @StateObject private var shelf = SignatureShelf()
    @State private var picture: CGImage?
    @State private var pageSize = CGSize.zero
    @State private var pageCount = 1
    @State private var failure: String?
    @State private var creating = false
    @State private var monitor: Any?

    var body: some View {
        ToolShell(session: session, saveTitle: tr("Save signed copy", "Unterschriebene Kopie sichern"), saveEnabled: !board.marks.isEmpty && failure == nil, onSave: save) {
            if creating {
                SignatureCreator(start: session.start, onDone: { signature, keep in
                    creating = false
                    if let signature {
                        if keep { shelf.keep(signature) }
                        place(signature)
                    }
                })
            } else {
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
            }
        } sidebar: {
            SidebarSection(title: tr("Signature", "Unterschrift")) {
                if shelf.signatures.isEmpty {
                    Text(tr("None kept yet.", "Noch keine gesichert.")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(shelf.signatures) { signature in
                    HStack(spacing: 8) {
                        Button { place(signature) } label: {
                            if let image = NSImage(data: signature.png) {
                                Image(nsImage: image).resizable().scaledToFit().frame(height: 34).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                        }
                        .buttonStyle(.plain)
                        .help(tr("Put \(signature.name) on this page", "\(signature.name) auf diese Seite setzen"))
                        Button { shelf.remove(signature.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(tr("Delete this signature", "Diese Unterschrift löschen"))
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                }
                Button(tr("New signature …", "Neue Unterschrift …")) { creating = true }
                if let problem = shelf.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Text(tr("Kept only on this Mac, in its keychain.", "Nur auf diesem Mac gesichert, in seinem Schlüsselbund.")).font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Date and text", "Datum und Text")) {
                HStack {
                    Button(tr("Date", "Datum")) { placeDate() }
                    Button(tr("Text", "Text")) {
                        board.perform(.tool(.text))
                    }
                    .help(tr("Then click on the page and write: a place, a name.", "Dann auf die Seite klicken und schreiben: einen Ort, einen Namen."))
                }
                .controlSize(.small)
                if board.tool == .text { Text(tr("Click on the page and write. Esc ends it.", "Klick auf die Seite und schreib. Esc beendet das Schreiben.")).font(.caption).foregroundStyle(.secondary) }
                LabeledSlider(title: tr("Text size", "Textgröße"), value: Binding(get: { Double(board.shownFontSize) }, set: { board.setFontSize(CGFloat($0)) }), range: 8...36, format: { String(format: "%.0f", $0) })
            }
            SidebarSection(title: tr("Selected", "Ausgewählt")) {
                Text(tr("Drag to move, drag a corner to resize.", "Ziehen zum Bewegen, an einer Ecke ziehen für die Größe.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(tr("Delete", "Löschen")) { board.deleteSelected() }.disabled(board.selected == nil).help(tr("Delete (⌫)", "Löschen (⌫)"))
                    Button(tr("On all pages", "Auf allen Seiten")) { board.copySelectedToAllPages() }.disabled(board.selected == nil || pageCount < 2).help(tr("Also on all other pages, at the same place", "Auch auf allen anderen Seiten, an derselben Stelle"))
                }
                .controlSize(.small)
                HStack {
                    Button { board.undo() } label: { Label(tr("Undo", "Widerrufen"), systemImage: "arrow.uturn.backward") }.disabled(!board.canUndo).help(tr("Undo (⌘Z)", "Widerrufen (⌘Z)"))
                    Button { board.redo() } label: { Label(tr("Redo", "Wiederholen"), systemImage: "arrow.uturn.forward") }.disabled(!board.canRedo).help(tr("Redo (⇧⌘Z)", "Wiederholen (⇧⌘Z)"))
                }
                .controlSize(.small)
            }
            FormHint(tr("This puts a visible signature on the page. It is not a digital certificate signature: it does not prove who signed, and it does not show if the file is changed later.", "Das setzt eine sichtbare Unterschrift auf die Seite. Es ist keine digitale Signatur mit Zertifikat: Sie beweist nicht, wer unterschrieben hat, und zeigt nicht, ob die Datei später geändert wurde."))
        }
        .task(id: board.page) { await loadPage() }
        .onAppear(perform: start)
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private func start() {
        board.tool = .select
        board.offeredTools = [.select, .text]
        shelf.load()
        monitor = AnnotateToolView.watchKeys(of: board, windowID: session.id.uuidString)
        if session.start["create"] != nil { creating = true }
        if let path = session.start["marks"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let marks = try? JSONDecoder().decode([Mark].self, from: data) {
            board.setMarksForDrawing(marks)
        }
        if let page = session.start["page"].flatMap(Int.init) { board.page = page }
        if let index = session.start["selected"].flatMap(Int.init), board.marks.indices.contains(index) { board.selected = board.marks[index].id }
    }

    /// Low on the page, about as wide as a signature on paper, where most documents want it; then it is dragged into place.
    private func place(_ signature: SavedSignature) {
        guard let mark = Self.mark(for: signature, pageSize: pageSize) else { return }
        board.place(mark)
    }

    nonisolated static func mark(for signature: SavedSignature, pageSize: CGSize) -> Mark? {
        let picture = MarkPicture(data: signature.png)
        guard let image = picture.image, image.height > 0 else { return nil }
        let width = min(170, pageSize.width * 0.5), height = width * CGFloat(image.height) / CGFloat(image.width)
        var mark = Mark(kind: .picture, frame: CGRect(x: (pageSize.width - width) / 2, y: pageSize.height * 0.75, width: width, height: height))
        mark.picture = picture
        return mark
    }

    private func placeDate() {
        let text = Date().formatted(date: .numeric, time: .omitted)
        let size = MarkPainter.textSize(text, fontSize: board.fontSize, width: .greatestFiniteMagnitude)
        board.place(Mark(kind: .text, frame: CGRect(x: pageSize.width * 0.15, y: pageSize.height * 0.77, width: size.width, height: size.height), color: MarkColor(red: 0, green: 0, blue: 0), fontSize: board.fontSize, text: text))
    }

    private func loadPage() async {
        let url = session.primary, number = board.page
        let result = await Task.detached { () -> Result<(CGImage, CGSize, Int), Error> in
            Result {
                let document = try AnnotationSaver.open(url)
                let (image, size) = try AnnotationSaver.picture(ofPage: number, in: url, dpi: 200)
                return (image, size, document.pageCount)
            }
        }.value
        switch result {
        case .success(let (image, size, pages)):
            picture = image
            pageSize = size
            pageCount = pages
            board.pageCount = pages
            board.pageSize = size
            board.color = MarkColor(red: 0, green: 0, blue: 0)
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    private func save() {
        board.finishEditing()
        guard !board.marks.isEmpty else { return }
        session.start(Self.jobs(session, marks: board.marks))
    }

    static func jobs(_ session: ToolSession, marks: [Mark]) -> [ToolJob] {
        let url = session.primary
        let destination = session.outputURL(suffix: tr("signed", "unterschrieben"), ext: "pdf")
        return [session.job(detail: url.lastPathComponent) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try AnnotationSaver.save(url, marks: marks, mode: .burned, to: destination, progress: progress)
            }]
        }]
    }
}

/// Making a new signature: drawn, from a photo of paper, or typed.
struct SignatureCreator: View {
    enum Way: String, CaseIterable, Identifiable {
        case draw, photo, type
        var id: String { rawValue }
        var title: String {
            switch self {
            case .draw: return tr("Draw", "Zeichnen")
            case .photo: return tr("Photo", "Foto")
            case .type: return tr("Type", "Tippen")
            }
        }
    }

    private static let inks = [MarkColor(red: 0, green: 0, blue: 0), MarkColor(red: 0.05, green: 0.15, blue: 0.6)]

    let start: [String: String]
    var onDone: (SavedSignature?, Bool) -> Void
    @State private var way = Way.draw
    @State private var strokes: [[InkPoint]] = []
    @State private var ink = SignatureCreator.inks[0]
    @State private var photo: SignaturePhoto?
    /// The line cut out, in black; shown and used in the ink chosen (`tinted`), so that changing the ink needs no new cut.
    @State private var photoShape: CGImage?
    @State private var photoResult: CGImage?
    /// A cut for the latest position of the slider is still on its way: "Use" waits for it.
    @State private var photoPending = false
    @State private var sensitivity = 0.5
    @State private var photoWork = 0
    @State private var cutter = PhotoCutter()
    @State private var photoProblem: String?
    @State private var name = ""
    @State private var font = SignatureMaker.handwritingFonts.first ?? "SnellRoundhand"
    @State private var keep = true

    private var hasResult: Bool {
        switch way {
        case .draw: return !strokes.isEmpty
        case .photo: return photoShape != nil && !photoPending
        case .type: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var result: CGImage? {
        switch way {
        case .draw: return SignatureMaker.picture(strokes: strokes, lineWidth: SignaturePad.lineWidth, color: ink)
        case .photo: return photoShape.flatMap { SignatureMaker.tinted($0, color: ink) }
        case .type: return SignatureMaker.picture(name: name, font: font, color: ink)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $way) {
                ForEach(Way.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Group {
                switch way {
                case .draw: drawPanel
                case .photo: photoPanel
                case .type: typePanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Text(tr("Ink", "Tinte")).font(.callout)
                ForEach(Self.inks, id: \.self) { color in
                    Button { ink = color } label: {
                        Circle().fill(Color(nsColor: color.nsColor()))
                            .overlay(Circle().stroke(ink == color ? Theme.accentForeground : Color.secondary.opacity(0.4), lineWidth: ink == color ? 2 : 1))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Toggle(tr("Keep for next time", "Für das nächste Mal behalten"), isOn: $keep)
                Button(tr("Cancel", "Abbrechen")) { onDone(nil, false) }
                Button(tr("Use", "Verwenden")) {
                    guard let image = result, let png = SignatureMaker.png(image) else { return }
                    onDone(SavedSignature(name: way == .type ? name : tr("Signature", "Unterschrift"), png: png), keep)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasResult)
            }
        }
        .padding(16)
        // Leaving the panel (Use, Cancel, closing the window) drops cutting still waiting: it held up the next window.
        .onDisappear { cutter.stop() }
        .onChange(of: sensitivity) { _, _ in cutPhoto() }
        // Only the colour: at once, no new cut (took seconds, and "Use" took the old colour).
        .onChange(of: ink) { _, _ in photoResult = photoShape.flatMap { SignatureMaker.tinted($0, color: ink) } }
        .onAppear {
            if let start = start["create"].flatMap(Way.init(rawValue:)) { way = start }
            if let text = start["name"] { name = text }
            if let chosen = start["font"] { font = chosen }
            if start["create"] == "draw" { strokes = Self.sampleStrokes }
            if let path = start["photo"] { loadPhoto(URL(fileURLWithPath: path)) }
            if let level = start["sensitivity"].flatMap(Double.init) { sensitivity = level }
        }
    }

    /// Only for showing the window drawn (test access).
    private static let sampleStrokes: [[InkPoint]] = [
        (0..<60).map { InkPoint(x: 40 + Double($0) * 6, y: 90 + 35 * sin(Double($0) / 3), time: Double($0) / 60) },
        (0..<20).map { InkPoint(x: 120 + Double($0) * 14, y: 150 - Double($0) * 1.5, time: Double($0) / 120) },
    ]

    private var drawPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Sign here with the trackpad or the mouse.", "Unterschreib hier mit dem Trackpad oder der Maus.")).font(.caption).foregroundStyle(.secondary)
            ZStack {
                Color.white
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1).padding(.horizontal, 30).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 60)
                SignaturePad(strokes: strokes, ink: ink) { strokes.append($0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button(tr("Clear", "Leeren")) { strokes = [] }.disabled(strokes.isEmpty)
                Button(tr("Undo line", "Linie widerrufen")) { _ = strokes.popLast() }.disabled(strokes.isEmpty)
            }
            .controlSize(.small)
        }
    }

    private var photoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Sign on white paper, take a photo in good light, with nothing else on the sheet.", "Unterschreib auf weißem Papier und fotografiere es bei gutem Licht, ohne etwas anderes auf dem Blatt.")).font(.caption).foregroundStyle(.secondary)
            ZStack {
                CheckerLight()
                if let photoResult {
                    Image(nsImage: ImageOps.nsImage(photoResult)).resizable().scaledToFit().padding(20)
                } else if let photoProblem {
                    Text(photoProblem).foregroundStyle(.orange).multilineTextAlignment(.center).padding()
                } else if photoWork > 0 {
                    ProgressView()
                } else {
                    Text(tr("Drag a photo here, or choose one", "Zieh ein Foto hierher oder wähle eins")).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .fileDrop([.image]) { loadPhoto($0[0]) }
            HStack {
                Button(tr("Choose photo …", "Foto wählen …"), action: choosePhoto)
                if photoPending { ProgressView().controlSize(.small) }
                if photo != nil {
                    LabeledSlider(title: tr("Sensitivity", "Empfindlichkeit"), value: $sensitivity, range: 0...1, format: { String(format: "%.0f %%", $0 * 100) })
                        .help(tr("Higher finds faint and thin lines; lower keeps shadows and paper out.", "Höher findet blasse und dünne Linien, niedriger lässt Schatten und Papier weg."))
                }
            }
        }
    }

    private var typePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(tr("Your name", "Dein Name"), text: $name).textFieldStyle(.roundedBorder).font(.title3)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(SignatureMaker.handwritingFonts, id: \.self) { candidate in
                        Button { font = candidate } label: {
                            HStack {
                                if let image = SignatureMaker.picture(name: name.isEmpty ? "Erika Mustermann" : name, font: candidate, color: ink) {
                                    Image(nsImage: ImageOps.nsImage(image)).resizable().scaledToFit().frame(height: 48)
                                }
                                Spacer()
                                Text(SignatureMaker.fontTitle(candidate)).font(.caption).foregroundStyle(.gray)
                            }
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(font == candidate ? Theme.accentForeground : Color.secondary.opacity(0.3), lineWidth: font == candidate ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPhoto(url)
    }

    /// Measured once in the background; each move of the slider only cuts again. One at a time, the latest wins (`PhotoCutter`).
    private func loadPhoto(_ url: URL) {
        photo = nil
        photoShape = nil
        photoResult = nil
        photoProblem = nil
        photoWork += 1
        photoPending = true
        let sensitivity = sensitivity
        cutter.submit({ () throws -> (SignaturePhoto, CGImage) in
            let measured = try SignaturePhoto(try ImageIOBridge.load(url))
            return (measured, try measured.cut(sensitivity: sensitivity, color: SignatureMaker.black))
        }, done: { outcome in
            photoPending = false
            switch outcome {
            case .success(let (measured, shape)):
                photo = measured
                show(shape)
            case .failure(let error):
                photoProblem = error.localizedDescription
            }
        })
    }

    private func cutPhoto() {
        guard let photo else { return }
        photoPending = true
        let sensitivity = sensitivity
        cutter.submit({ try photo.cut(sensitivity: sensitivity, color: SignatureMaker.black) }, done: { outcome in
            photoPending = false
            switch outcome {
            case .success(let shape):
                show(shape)
            case .failure(let error):
                photoShape = nil
                photoResult = nil
                photoProblem = error.localizedDescription
            }
        })
    }

    private func show(_ shape: CGImage) {
        photoShape = shape
        photoResult = SignatureMaker.tinted(shape, color: ink)
        photoProblem = nil
    }
}

/// The surface a signature is written on, with AppKit's own mouse events: each one, from the press on, with its time.
/// SwiftUI's drag gesture hands over fewer points and its first one late, so the start of a line went missing and fast parts turned into corners.
struct SignaturePad: NSViewRepresentable {
    var strokes: [[InkPoint]]
    var ink: MarkColor
    var onStroke: ([InkPoint]) -> Void

    static let lineWidth: CGFloat = 3

    func makeNSView(context: Context) -> SignaturePadView {
        SignaturePadView()
    }

    func updateNSView(_ view: SignaturePadView, context: Context) {
        view.onStroke = onStroke
        view.strokes = strokes
        view.ink = ink
    }
}

final class SignaturePadView: NSView {
    var strokes: [[InkPoint]] = [] { didSet { if strokes != oldValue { needsDisplay = true } } }
    var ink = MarkColor(red: 0, green: 0, blue: 0) { didSet { if ink != oldValue { needsDisplay = true } } }
    var onStroke: (([InkPoint]) -> Void)?
    private(set) var current: [InkPoint] = []
    /// macOS merges mouse movements while an app is busy; during a line every one counts.
    private var coalescingBefore: Bool?

    override var isFlipped: Bool { true }
    /// The first click into the window already writes.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if coalescingBefore == nil { coalescingBefore = NSEvent.isMouseCoalescingEnabled }
        NSEvent.isMouseCoalescingEnabled = false
        current = [point(event)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !current.isEmpty else { return }
        current.append(point(event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !current.isEmpty else { return }
        current.append(point(event))
        finish()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finish() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func finish() {
        if let coalescingBefore { NSEvent.isMouseCoalescingEnabled = coalescingBefore }
        coalescingBefore = nil
        guard !current.isEmpty else { return }
        let stroke = current
        current = []
        strokes.append(stroke)
        onStroke?(stroke)
    }

    private func point(_ event: NSEvent) -> InkPoint {
        let at = convert(event.locationInWindow, from: nil)
        return InkPoint(x: at.x, y: at.y, time: event.timestamp)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(ink.cgColor())
        for stroke in strokes + [current] { SignatureMaker.draw(stroke, lineWidth: SignaturePad.lineWidth, in: context) }
    }
}

/// Light squares, to see what is transparent.
private struct CheckerLight: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color((row + column) % 2 == 0 ? Color.white : Color(white: 0.9)))
                }
            }
        }
    }
}
