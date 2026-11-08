import SwiftUI

@MainActor
struct ReadQRToolView: View {
    let session: ToolSession
    @State private var results: [URL: Result<[QRReader.Code], Error>] = [:]

    private var allTexts: [String] { session.files.flatMap { (try? results[$0]?.get()) ?? [] }.filter { !$0.isNote }.map(\.text) }

    var body: some View {
        FormShell(session: session, saveTitle: tr("Copy all", "Alle kopieren"), saveEnabled: !allTexts.isEmpty, onSave: { QRReader.copy(allTexts) }) {
            ForEach(session.files, id: \.self) { url in
                VStack(alignment: .leading, spacing: 10) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    switch results[url] {
                    case nil:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(tr("Looking for QR codes…", "QR-Codes werden gesucht …")).foregroundStyle(.secondary)
                        }
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.secondary)
                    case .success(let codes) where codes.isEmpty:
                        Text(tr("No QR code found.", "Kein QR-Code gefunden.")).foregroundStyle(.secondary)
                    case .success(let codes):
                        ForEach(codes) { code in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let page = code.page {
                                        Text(tr("Page \(page)", "Seite \(page)")).font(.caption).foregroundStyle(.secondary)
                                    }
                                    // Plain, selectable text: a link is shown, never opened.
                                    Text(verbatim: code.text)
                                        .font(.body.monospaced())
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if !code.isNote { Button(tr("Copy", "Kopieren")) { QRReader.copy([code.text]) } }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            FormHint(tr("QR codes are read on this Mac with Apple Vision. Links are shown as text and never opened.", "QR-Codes werden auf diesem Mac mit Apple Vision gelesen. Links werden nur als Text gezeigt und nie geöffnet."))
        }
        .task { await read() }
    }

    /// Reads in the background so the window opens at once.
    private func read() async {
        for url in session.files {
            results[url] = await Self.codes(in: url)
        }
    }

    /// What the window shows for one file; the debug test access reads codes the same way.
    static func codes(in url: URL) async -> Result<[QRReader.Code], Error> {
        await Task.detached { Result { try QRReader.codes(in: url) } }.value
    }
}
