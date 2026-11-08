import SwiftUI

@MainActor
struct PDFArchiveToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let missing = PDFArchive.ghostscriptPath == nil
        FormShell(session: session, saveTitle: session.files.count == 1 ? tr("Save as PDF/A", "Als PDF/A sichern") : tr("Save \(session.files.count) PDFs as PDF/A", "\(session.files.count) PDFs als PDF/A sichern"), saveEnabled: !missing, onSave: { session.start(Self.jobs(session)) }) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(tr("\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · saves as PDF/A-2b", "\(FileSizeFormatter.string(FileSizeFormatter.size(of: url))) · wird als PDF/A-2b gesichert"))
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
            FormHint(tr("PDF/A is the format for keeping documents for decades: fonts and colors travel in the file, so it looks the same on any computer. Text stays text. A PDF with a password has to be unlocked first; form fields become plain text, and attachments may be removed.", "PDF/A ist das Format, um Dokumente über Jahrzehnte aufzubewahren: Schriften und Farben stecken in der Datei, so sieht sie auf jedem Computer gleich aus. Text bleibt Text. Eine PDF mit Passwort muss zuerst entsperrt werden; Formularfelder werden zu normalem Text, Anhänge können entfernt werden."))
            FormHint(tr("The result is made by Ghostscript and checked for fonts, color profile and encryption. That is not an official validation; where one is required, have it checked with a validator such as veraPDF.", "Das Ergebnis erstellt Ghostscript, danach werden Schriften, Farbprofil und Verschlüsselung geprüft. Das ist keine offizielle Prüfung. Wo eine nötig ist, lass die Datei mit einem Prüfprogramm wie veraPDF prüfen."))
            if missing { FormHint(PDFArchive.missingHint) }
            Text(tr("Originals stay untouched; the copy is saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func jobs(_ session: ToolSession) -> [ToolJob] {
        session.files.map { url in
            let destination = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: "PDF-A", ext: "pdf")
            return session.job(detail: url.lastPathComponent) { progress in
                return [try await StagingArea.writing(destination) { destination in
                    try await PDFArchive.convert(url, to: destination, progress: progress)
                }]
            }
        }
    }
}
