import SwiftUI

/// "Remove audio": runs at once from the ring. The window only shows when the tool is opened in another way.
@MainActor
struct RemoveAudioToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        FormShell(session: session, saveTitle: tr("Remove audio", "Ton entfernen"), onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        Text(url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            FormHint(tr("The pictures are copied unchanged (no new encoding): rotation, HDR and quality stay as they are. MKV, WebM, AVI and WMV need FFmpeg.",
                        "Die Bilder werden unverändert übernommen (kein neues Umrechnen): Drehung, HDR und Qualität bleiben. MKV, WebM, AVI und WMV brauchen FFmpeg."))
            Text(tr("Originals stay untouched; results are saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Ort der Ergebnisse: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        session.start(Self.jobs(session))
    }

    static func jobs(_ session: ToolSession) -> [ToolJob] {
        session.files.map { url in
            let format = FileFormat.detect(url) ?? .mp4
            let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                                         baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent),
                                                         suffix: tr("no audio", "ohne Ton"), ext: format.fileExtension)
            var job = session.job(detail: url.lastPathComponent) { progress in
                [try await StagingArea.writing(destination) { destination in
                    try await VideoOps.removeAudio(url, to: destination, progress: progress)
                }]
            }
            job.inputs = [url]
            return job
        }
    }
}
