import PDFKit
import SwiftUI

@MainActor
struct RedactPDFToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var search = RedactionSearch()
    @State private var page = 0
    @State private var pageCount = 0
    @State private var picture: NSImage?
    @State private var pageSize = CGSize.zero
    /// Places drawn by hand, per page, in the page's points.
    @State private var areas: [Int: [RectangleOverlay]] = [:]
    @State private var selected: UUID?
    @State private var failure: String?

    private var handCount: Int { areas.values.map(\.count).reduce(0, +) }
    private var total: Int { search.ticked.count + handCount }

    var body: some View {
        ToolShell(session: session, saveTitle: total == 0 ? tr("Black out", "Schwärzen") : tr("Black out \(total)", "\(total) schwärzen"), saveEnabled: total > 0 && failure == nil, onSave: save) {
            VStack(spacing: 8) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let picture, pageSize.width > 0 {
                        ZStack {
                            RectangleEditorCanvas(image: picture, imageSize: pageSize, rectangles: Binding(get: { areas[page] ?? [] }, set: { areas[page] = $0 }), selected: $selected, allowMultiple: true)
                            RedactionFindsOverlay(finds: search.finds.filter { $0.page == page }, ticked: search.ticked, imageSize: pageSize)
                        }
                        .padding(12)
                    } else {
                        LoadingOrError(error: failure)
                    }
                }
                if pageCount > 1 {
                    HStack {
                        Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                        Text(tr("Page \(page + 1) of \(pageCount)", "Seite \(page + 1) von \(pageCount)")).font(.callout.monospacedDigit())
                        Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled(page >= pageCount - 1)
                    }
                    .padding(.bottom, 8)
                }
            }
        } sidebar: {
            RedactionFindPanel(search: search, showsPages: true, onFind: find, onShow: { page = $0.page })
            SidebarSection(title: tr("Drawn by hand (\(handCount))", "Von Hand gezogen (\(handCount))")) {
                Text(tr("Drag on the page to black out any place.", "Auf der Seite ziehen, um eine beliebige Stelle zu schwärzen.")).font(.caption).foregroundStyle(.secondary)
                if handCount > 0 { Button(tr("Remove all", "Alle entfernen")) { areas = [:]; selected = nil }.controlSize(.small) }
                if let selected {
                    Button(tr("Remove selected", "Ausgewählte entfernen")) {
                        areas[page]?.removeAll { $0.id == selected }
                        self.selected = nil
                    }
                    .controlSize(.small)
                }
            }
            FormHint(tr("Pages with a black place are saved as pictures with real black in them, then made searchable again. Other pages stay as they are. Comments, form fields, attachments, scripts and metadata are removed, and the result is checked before it is saved.", "Seiten mit einer schwarzen Stelle werden als Bild mit echtem Schwarz gesichert und danach wieder durchsuchbar gemacht. Andere Seiten bleiben, wie sie sind. Kommentare, Formularfelder, Anhänge, Skripte und Metadaten werden entfernt, und das Ergebnis wird vor dem Sichern geprüft. In der Vorschau sind die Stellen halbdurchsichtig, im Ergebnis echt schwarz."))
        }
        .task(id: page) { await loadPage() }
        .task {
            pageCount = PDFDocument(url: session.primary)?.pageCount ?? 0
            if let terms = session.start["terms"] { search.termsText = terms.replacingOccurrences(of: "|", with: "\n") }
            if let patterns = session.start["patterns"] { search.patterns = Set(patterns.split(separator: ",").compactMap { RedactionFinder.Pattern(rawValue: String($0)) }) }
            if session.start["faces"] == "true" { search.faces = true }
            if !search.request.isEmpty { find() }
        }
        .onDeleteCommand {
            if let selected { areas[page]?.removeAll { $0.id == selected }; self.selected = nil }
        }
    }

    private func loadPage() async {
        let url = session.primary, number = page
        let result = await Task.detached { () -> Result<(CGImage, CGSize), Error> in
            Result {
                let document = try PDFRedactor.open(url)
                guard let page = document.page(at: number), let image = PDFRenderer.render(page: page, dpi: 130) else { throw AppError.unreadable(url) }
                return (image, PDFToWord.pageSize(page))
            }
        }.value
        switch result {
        case .success(let (image, size)):
            picture = ImageOps.nsImage(image)
            pageSize = size
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    private func find() {
        let url = session.primary
        search.start { request, progress in try await RedactionFinder.find(inPDF: url, request: request, progress: progress) }
    }

    private func save() {
        let hand = areas.flatMap { number, overlays in
            overlays.map { PDFRedactor.Area(page: number, box: CGRect(x: $0.rect.minX / pageSize.width, y: $0.rect.minY / pageSize.height, width: $0.rect.width / pageSize.width, height: $0.rect.height / pageSize.height)) }
        }
        session.start(Self.jobs(session, finds: search.chosen, left: search.left, areas: hand))
    }

    static func jobs(_ session: ToolSession, finds: [RedactionFinder.Find], left: [RedactionFinder.Find] = [], areas: [PDFRedactor.Area]) -> [ToolJob] {
        let url = session.primary
        let destination = session.outputURL(suffix: tr("redacted", "geschwärzt"), ext: "pdf")
        return [session.job(detail: url.lastPathComponent) { progress in
            return [try await StagingArea.writing(destination) { destination in
                try await PDFRedactor.redact(url, finds: finds, left: left, areas: areas, to: destination, progress: progress)
            }]
        }]
    }
}
