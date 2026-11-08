import SwiftUI

@MainActor
struct TranscribeToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var output = ToolMemory.value(.transcribe, "output", default: Transcriber.Output.text)

    private var setupHint: String? {
        Transcriber.hint(for: Transcriber.problems(whisper: Transcriber.whisperPath, modelsFolder: Transcriber.modelsFolder),
                         modelsFolder: Transcriber.modelsFolder)
    }

    var body: some View {
        let hint = setupHint
        FormShell(session: session, saveTitle: session.files.count == 1 ? tr("Transcribe", "Transkribieren") : tr("Transcribe \(session.files.count) files", "\(session.files.count) Dateien transkribieren"),
                  saveEnabled: hint == nil, onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(tr("\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · saves as \(output.format.displayName)", "\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · wird als \(output.format.displayName) gesichert"))
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

            FormRow(title: tr("Language", "Sprache")) {
                SegmentedPicker(selection: $settings.transcriptionLanguage, options: Transcriber.Language.allCases.map { ($0, $0.title) })
            }
            FormRow(title: tr("Save as", "Sichern als")) {
                SegmentedPicker(selection: $output, options: Transcriber.Output.allCases.map { ($0, $0.title) })
            }
            FormHint(tr("Speech is recognized on this Mac with whisper (large-v3 model); silent parts are skipped. Long recordings take a while; the progress shows while it runs, and you can cancel it there.", "Die Sprache wird auf diesem Mac mit whisper erkannt (Modell large-v3), stille Stellen werden übersprungen. Lange Aufnahmen dauern eine Weile. Der Fortschritt wird währenddessen angezeigt, dort kannst du auch abbrechen."))
            if let hint {
                FormHint(hint)
            }

            Text(tr("Originals stay untouched; the result is saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        ToolMemory.remember(.transcribe, ["output": output.rawValue, "language": settings.transcriptionLanguage.rawValue])
        session.start(Self.jobs(session, language: settings.transcriptionLanguage, output: output))
    }

    static func jobs(_ session: ToolSession, language: Transcriber.Language, output: Transcriber.Output = .text) -> [ToolJob] {
        session.files.map { url in
            let directory = AppSettings.shared.outputLocation.directory(for: url)
            let destination = ConversionMatrix.uniqueURL(directory: directory, baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: "", ext: output.format.fileExtension)
            return session.job(detail: url.lastPathComponent) { progress in
                let report = UncheckedBox(progress)
                return [try await StagingArea.writing(destination) { destination in
                    try await Transcriber.transcribe(url, to: destination, language: language, output: output, progress: { report.value($0) })
                }]
            }
        }
    }
}
