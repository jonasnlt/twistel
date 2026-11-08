import PDFKit
import SwiftUI

/// The PDFs of the session as cards, as in the other PDF tools.
private struct PDFFileCards: View {
    let files: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(files, id: \.self) { url in
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        let pages = PDFDocument(url: url)?.pageCount ?? 0
                        Text(tr("\(pages) page\(pages == 1 ? "" : "s")", "\(pages) \(pages == 1 ? "Seite" : "Seiten")"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// One page of the first PDF with the stamp on it, small; drawn in the background when a setting changes.
private struct StampPreview: View {
    let url: URL
    let pageIndex: Int
    let key: String
    let stamp: @Sendable (CGContext, CGRect, Int, Int) -> Void
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 170, height: 220)
        .task(id: key) {
            let url = url, pageIndex = pageIndex, stamp = stamp
            image = await Task.detached { PDFStamp.preview(url, pageIndex: pageIndex, width: 340, stamp: stamp) }.value
        }
    }
}

@MainActor
struct WatermarkPDFToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var watermark = WatermarkPDFToolView.remembered()
    @State private var formFields = false

    private var ready: Bool { !watermark.text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        FormShell(session: session, saveTitle: tr("Add watermark", "Wasserzeichen hinzufügen"), saveEnabled: ready, onSave: run) {
            PDFFileCards(files: session.files)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    FormRow(title: tr("Text", "Text")) {
                        TextField("", text: $watermark.text)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                    }
                    FormRow(title: tr("Direction", "Richtung")) {
                        SegmentedPicker(selection: $watermark.direction, options: PDFStamp.Watermark.Direction.allCases.map { ($0, $0.title) })
                    }
                    FormRow(title: tr("Position", "Position")) {
                        SegmentedPicker(selection: $watermark.position, options: PDFStamp.Watermark.Position.allCases.map { ($0, $0.title) })
                    }
                    LabeledSlider(title: tr("Size", "Größe"), value: Binding(get: { Double(watermark.fontSize) }, set: { watermark.fontSize = CGFloat($0.rounded()) }),
                                  range: 24...160, format: { "\(Int($0)) pt" })
                    LabeledSlider(title: tr("Opacity", "Deckkraft"), value: Binding(get: { Double(watermark.opacity) }, set: { watermark.opacity = CGFloat($0) }),
                                  range: 0.05...1, format: { "\(Int(($0 * 100).rounded())) %" })
                }
                StampPreview(url: session.primary, pageIndex: 0, key: "\(watermark)") { [watermark] context, page, _, _ in
                    PDFStamp.draw(watermark, in: context, page: page)
                }
            }
            if formFields {
                FormHint(tr("This PDF has form fields. They are not kept in the copy; fill in the form first.", "Diese PDF hat Formularfelder. Sie bleiben in der Kopie nicht erhalten; füll das Formular vorher aus."))
            }
            FormHint(tr("Gray, on top of every page. A text too long for the page is made smaller. The PDF's own text stays searchable; the watermark itself is drawn as shapes, so it does not get in the way when copying text.", "Grau, über jeder Seite. Ein Text, der zu lang für die Seite ist, wird verkleinert. Der Text der PDF bleibt durchsuchbar; das Wasserzeichen selbst wird als Form gezeichnet und stört deshalb nicht beim Kopieren von Text."))
            Text(tr("Originals stay untouched; the copy is saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { formFields = await PDFStamp.anyFormFields(session.files) }
    }

    /// The last watermark of this window (Option at the drop uses it too).
    static func remembered() -> PDFStamp.Watermark {
        var watermark = PDFStamp.Watermark()
        watermark.text = ToolMemory.values(.watermarkPDF)["text"] ?? watermark.text
        watermark.fontSize = CGFloat(ToolMemory.value(.watermarkPDF, "size", default: Double(watermark.fontSize)))
        watermark.opacity = CGFloat(ToolMemory.value(.watermarkPDF, "opacity", default: Double(watermark.opacity)))
        watermark.direction = ToolMemory.value(.watermarkPDF, "direction", default: watermark.direction)
        watermark.position = ToolMemory.value(.watermarkPDF, "position", default: watermark.position)
        return watermark
    }

    private func run() {
        ToolMemory.remember(.watermarkPDF, ["text": watermark.text, "size": "\(Double(watermark.fontSize))", "opacity": "\(Double(watermark.opacity))",
                                            "direction": watermark.direction.rawValue, "position": watermark.position.rawValue])
        session.start(Self.jobs(session, watermark: watermark))
    }

    static func jobs(_ session: ToolSession, watermark: PDFStamp.Watermark) -> [ToolJob] {
        session.files.map { url in
            let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                                         baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: tr("watermark", "Wasserzeichen"), ext: "pdf")
            return session.job(detail: url.lastPathComponent) { progress in
                return [try await StagingArea.writing(destination) { destination in
                    try PDFStamp.addWatermark(watermark, to: url, destination: destination, progress: progress)
                }]
            }
        }
    }
}

@MainActor
struct PageNumbersPDFToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var numbers = PageNumbersPDFToolView.remembered()
    @State private var formFields = false

    private var pageCount: Int { PDFDocument(url: session.primary)?.pageCount ?? 1 }

    var body: some View {
        FormShell(session: session, saveTitle: tr("Add page numbers", "Seitenzahlen hinzufügen"), onSave: run) {
            PDFFileCards(files: session.files)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    FormRow(title: tr("Position", "Position")) {
                        Picker("", selection: $numbers.position) {
                            ForEach(PDFStamp.PageNumbers.Position.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    FormRow(title: tr("Format", "Format")) {
                        SegmentedPicker(selection: $numbers.format, options: PDFStamp.PageNumbers.Format.allCases.map { format in
                            var example = numbers
                            example.format = format
                            example.skipFirstPage = false
                            example.start = 1
                            return (format, example.label(page: 0, of: 9) ?? "1")
                        })
                    }
                    NumberField(title: tr("Start number", "Erste Zahl"), value: Binding(get: { numbers.start }, set: { numbers.start = max(0, $0) }))
                        .frame(maxWidth: 260)
                    Toggle(tr("Leave out the first page", "Erste Seite auslassen"), isOn: $numbers.skipFirstPage)
                        .toggleStyle(.switch)
                }
                StampPreview(url: session.primary, pageIndex: numbers.skipFirstPage && pageCount > 1 ? 1 : 0, key: "\(numbers)") { [numbers] context, page, index, count in
                    if let label = numbers.label(page: index, of: count) { PDFStamp.draw(label, numbers: numbers, in: context, page: page) }
                }
            }
            FormHint(numbers.skipFirstPage
                     ? tr("The first page (a cover) gets no number; the second page gets the start number.", "Die erste Seite (ein Deckblatt) bekommt keine Zahl; die zweite Seite bekommt die erste Zahl.")
                     : tr("Every page gets a number, starting with the start number.", "Jede Seite bekommt eine Zahl, beginnend mit der ersten Zahl."))
            FormHint(tr("The numbers are real text: the PDF stays searchable, and so are the numbers.", "Die Zahlen sind echter Text: Die PDF bleibt durchsuchbar, die Zahlen ebenso."))
            if formFields {
                FormHint(tr("This PDF has form fields. They are not kept in the copy; fill in the form first.", "Diese PDF hat Formularfelder. Sie bleiben in der Kopie nicht erhalten; füll das Formular vorher aus."))
            }
            Text(tr("Originals stay untouched; the copy is saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { formFields = await PDFStamp.anyFormFields(session.files) }
    }

    static func remembered() -> PDFStamp.PageNumbers {
        var numbers = PDFStamp.PageNumbers()
        numbers.position = ToolMemory.value(.pageNumbersPDF, "position", default: numbers.position)
        numbers.format = ToolMemory.value(.pageNumbersPDF, "format", default: numbers.format)
        numbers.start = ToolMemory.value(.pageNumbersPDF, "start", default: numbers.start)
        numbers.skipFirstPage = ToolMemory.value(.pageNumbersPDF, "skipFirst", default: numbers.skipFirstPage)
        return numbers
    }

    private func run() {
        ToolMemory.remember(.pageNumbersPDF, ["position": numbers.position.rawValue, "format": numbers.format.rawValue, "start": "\(numbers.start)",
                                              "skipFirst": "\(numbers.skipFirstPage)"])
        session.start(Self.jobs(session, numbers: numbers))
    }

    static func jobs(_ session: ToolSession, numbers: PDFStamp.PageNumbers) -> [ToolJob] {
        session.files.map { url in
            let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                                         baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: tr("numbered", "nummeriert"), ext: "pdf")
            return session.job(detail: url.lastPathComponent) { progress in
                return [try await StagingArea.writing(destination) { destination in
                    try PDFStamp.addPageNumbers(numbers, to: url, destination: destination, progress: progress)
                }]
            }
        }
    }
}
