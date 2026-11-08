import SwiftUI

@MainActor
struct PDFPasswordToolView: View {
    let session: ToolSession
    @EnvironmentObject private var settings: AppSettings
    @State private var action: PDFPassword.Action
    // Kept only while the window is open; never saved or logged.
    @State private var password = ""
    @State private var repeated = ""

    init(session: ToolSession) {
        self.session = session
        _action = State(initialValue: PDFPassword.suggestedAction(for: session.files))
    }

    private var qpdfMissing: Bool { PDFPassword.qpdfPath == nil }

    private var ready: Bool {
        guard !qpdfMissing, PDFPassword.passwordProblem(password) == nil else { return false }
        return action == .remove || password == repeated
    }

    var body: some View {
        FormShell(session: session, saveTitle: action.title, saveEnabled: ready, onSave: run) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.files, id: \.self) { url in
                    HStack(spacing: 14) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(PDFPassword.isProtected(url) ? tr("Has a password", "Hat ein Passwort") : tr("No password", "Kein Passwort"))
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

            FormRow(title: tr("Action", "Aktion")) {
                SegmentedPicker(selection: $action, options: PDFPassword.Action.allCases.map { ($0, $0.title) })
            }
            // A grid, so both fields start at the same place.
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 18) {
                GridRow {
                    Text(tr("Password", "Passwort"))
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                if action == .add {
                    GridRow {
                        Text(tr("Repeat", "Wiederholen"))
                        SecureField("", text: $repeated)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                    }
                }
            }
            if !password.isEmpty, let problem = PDFPassword.passwordProblem(password) {
                FormHint(problem)
            }
            if action == .add {
                if !repeated.isEmpty, repeated != password {
                    FormHint(tr("The two passwords are not the same.", "Die beiden Passwörter stimmen nicht überein."))
                }
                FormHint(tr("The copy can only be opened with this password (AES-256 encryption). There is no way to recover a forgotten password.", "Die Kopie lässt sich nur mit diesem Passwort öffnen (AES-256-Verschlüsselung). Ein vergessenes Passwort lässt sich nicht wiederherstellen."))
            } else {
                FormHint(tr("Enter the password that opens the PDF. The copy then opens without a password.", "Gib das Passwort ein, mit dem sich die PDF öffnen lässt. Die Kopie öffnet sich dann ohne Passwort."))
            }
            if qpdfMissing {
                FormHint(PDFPassword.qpdfMissingHint)
            }
            Text(tr("Originals stay untouched; the copy is saved to \(settings.outputLocation.title.lowercased()).", "Die Originale bleiben unverändert. Gesichert wird: \(settings.outputLocation.title)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func run() {
        session.start(Self.jobs(session, action: action, password: password))
    }

    static func jobs(_ session: ToolSession, action: PDFPassword.Action, password: String) -> [ToolJob] {
        session.files.map { url in
            let directory = AppSettings.shared.outputLocation.directory(for: url)
            return session.job(action.progressTitle, detail: url.lastPathComponent) { _ in
                [try await PDFPassword.run(action, on: url, password: password, in: directory)]
            }
        }
    }
}
