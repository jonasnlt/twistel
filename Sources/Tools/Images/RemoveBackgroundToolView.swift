import SwiftUI

@MainActor
struct RemoveBackgroundToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    /// nil: all subjects.
    @State private var subject: Int?
    @State private var subjects = 0
    @State private var previews: [Int?: CGImage] = [:]
    @State private var failure: String?

    init(session: ToolSession) {
        self.session = session
        _subject = State(initialValue: session.start["subject"].flatMap(Int.init))
    }

    var body: some View {
        FormShell(session: session, saveTitle: session.files.count == 1 ? tr("Save", "Sichern") : tr("Save \(session.files.count) pictures", "\(session.files.count) Bilder sichern"), saveEnabled: failure == nil || session.files.count > 1, onSave: run) {
            HStack(alignment: .top, spacing: 24) {
                ZStack {
                    CheckerboardBackground()
                    if let preview = previews[subject] {
                        Image(decorative: preview, scale: 1).resizable().interpolation(.high).scaledToFit()
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if subjects > 1, session.files.count == 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Keep", "Behalten")).font(.headline).padding(.bottom, 2)
                        choice(tr("All subjects", "Alle Motive"), nil)
                        ForEach(0..<subjects, id: \.self) { choice(tr("Subject \($0 + 1)", "Motiv \($0 + 1)"), $0) }
                        Text(tr("Counted from the left.", "Von links gezählt.")).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    .padding(14)
                    .frame(width: 180, alignment: .leading)
                    .card()
                }
            }
            FormHint(tr("The subject is found on this Mac with Apple Vision. Saved as PNG with transparency, in the size of the original.", "Das Motiv wird auf diesem Mac mit Apple Vision gefunden. Gesichert wird ein PNG mit transparentem Hintergrund, in der Größe des Originals.")
                + (session.files.count > 1 ? tr(" Shown is the first picture; each picture keeps all its subjects.", " Gezeigt wird das erste Bild; jedes Bild behält alle seine Motive.") : ""))
            Text(tr("Originals stay untouched; the copies are saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task(id: subject) { await loadPreview() }
    }

    private func choice(_ title: String, _ value: Int?) -> some View {
        Button { subject = value } label: {
            HStack(spacing: 8) {
                Image(systemName: subject == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(subject == value ? Theme.accentForeground : .secondary)
                Text(title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
    }

    private func loadPreview() async {
        guard previews[subject] == nil else { return }
        let url = session.primary, wanted = subject
        let result = await Task.detached { () -> Result<(CGImage, Int), Error> in
            do {
                let cutout = try await BackgroundRemover.cutout(try ImageIOBridge.load(url), subject: wanted)
                return .success((ImageIOBridge.resized(cutout.image, longEdge: 1200), cutout.subjects))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let (image, count)):
            previews[wanted] = image
            subjects = count
        case .failure(let error):
            failure = error.localizedDescription
        }
    }

    private func run() {
        session.start(Self.jobs(session, subject: session.files.count == 1 ? subject : nil))
    }

    /// `subject` applies to the first picture, the one shown.
    static func jobs(_ session: ToolSession, subject: Int? = nil) -> [ToolJob] {
        session.files.enumerated().map { index, url in
            let destination = BackgroundRemover.outputURL(for: url)
            return session.job(detail: url.lastPathComponent) { progress in
                progress(0.1)
                return [try await StagingArea.writing(destination) { destination in
                    try await BackgroundRemover.save(url, subject: index == 0 ? subject : nil, to: destination)
                }]
            }
        }
    }
}
