import SwiftUI

@MainActor
struct ExtractImagesToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var summaries: [URL: String] = [:]

    var body: some View {
        FormShell(session: session, saveTitle: tr("Extract images", "Bilder herausziehen"), onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(summaries[url] ?? tr("Looking for images…", "Suche nach Bildern …"))
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

            FormHint(tr("JPEG images are copied unchanged; all other images are saved as PNG. An image used on several pages is saved once. The images go into a folder \u{201C}Name (images)\u{201D}.", "JPEG-Bilder werden unverändert kopiert, alle anderen als PNG gesichert. Ein Bild, das auf mehreren Seiten vorkommt, wird nur einmal gesichert. Die Bilder kommen in einen Ordner \u{201E}Name Bilder\u{201C}."))
            Text(tr("Originals stay untouched; the folder is saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Ort des Ordners: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { await count() }
    }

    /// Counts the images in the background so the window opens at once.
    private func count() async {
        for url in session.files {
            let summary = await Task.detached { () -> String in
                guard let images = try? PDFImageExtractor.images(in: url) else { return tr("Can't read this PDF (password protected or damaged).", "Diese PDF lässt sich nicht lesen (mit Passwort geschützt oder beschädigt).") }
                return images.isEmpty ? tr("No images found", "Keine Bilder gefunden") : tr("\(images.count) image\(images.count == 1 ? "" : "s") found", "\(images.count) \(images.count == 1 ? "Bild" : "Bilder") gefunden")
            }.value
            summaries[url] = summary
        }
    }

    private func run() {
        session.start(Self.jobs(session))
    }

    static func jobs(_ session: ToolSession) -> [ToolJob] {
        session.files.map { url in
            let directory = AppSettings.shared.outputLocation.directory(for: url)
            // ToolJob already runs this in the background and passes Cancel on; an extra detached task would swallow Cancel.
            return session.job(detail: url.lastPathComponent) { progress in
                [try PDFImageExtractor.extractToFolder(from: url, in: directory, progress: progress)]
            }
        }
    }
}
