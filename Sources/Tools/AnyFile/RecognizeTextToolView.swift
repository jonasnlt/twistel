import SwiftUI

@MainActor
struct RecognizeTextToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var output = ToolMemory.value(.recognizeText, "output", default: TextRecognizer.PDFOutput.standard)

    private var hasPDFs: Bool { session.files.contains { FileFormat.detect($0) == .pdf } }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? tr("Recognize text", "Text erkennen") : tr("Recognize text in \(session.files.count) files", "Text in \(session.files.count) Dateien erkennen"), onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(FileSizeFormatter.string(FileSizeFormatter.size(of: url)))
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

            if hasPDFs {
                FormRow(title: tr("Save as", "Sichern als")) {
                    SegmentedPicker(selection: $output, options: TextRecognizer.PDFOutput.allCases.map { ($0, $0.title) })
                }
                FormHint(tr("A searchable PDF looks exactly like the original; the recognized text lies invisibly on top, so you can search and select it. Pages that already contain text are kept as they are.", "Ein durchsuchbares PDF sieht genauso aus wie das Original. Der erkannte Text liegt unsichtbar darüber, so kannst du ihn suchen und auswählen. Seiten, die schon Text enthalten, bleiben, wie sie sind."))
            } else {
                FormHint(tr("The recognized text is saved as a .txt file.", "Der erkannte Text wird als TXT-Datei gesichert."))
            }
            FormHint(tr("Text is recognized on this Mac with Apple Vision, in German and English.", "Der Text wird auf diesem Mac mit Apple Vision erkannt, auf Deutsch und Englisch."))
            Text(tr("Originals stay untouched; results are saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        ToolMemory.remember(.recognizeText, ["output": output.rawValue])
        session.start(Self.jobs(session, output: output))
    }

    static func jobs(_ session: ToolSession, output: TextRecognizer.PDFOutput) -> [ToolJob] {
        session.files.map { url in
            let directory = AppSettings.shared.outputLocation.directory(for: url)
            var job = ToolJob(title: ToolID.recognizeText.progressTitle, detail: url.lastPathComponent, symbol: ToolID.recognizeText.symbol, steps: { report in
                try await TextRecognizer.runInBackground(url, output: output, in: directory) { report($0.fraction, $0.step) }
            })
            job.outputFolder = directory
            return job
        }
    }
}
