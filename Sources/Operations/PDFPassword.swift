import Foundation
import PDFKit

/// Sets or removes a PDF's open password with qpdf (AES-256), a separately installed program. The password goes to
/// qpdf through its standard input; it never appears on a command line, in a file or in the log.
enum PDFPassword {
    enum Action: String, CaseIterable, Identifiable {
        case add
        case remove

        var id: String { rawValue }
        var title: String {
            switch self {
            case .add: return tr("Add password", "Passwort hinzufügen")
            case .remove: return tr("Remove password", "Passwort entfernen")
            }
        }
        var progressTitle: String {
            switch self {
            case .add: return tr("Adding password", "Passwort wird hinzugefügt")
            case .remove: return tr("Removing password", "Passwort wird entfernt")
            }
        }
        var suffix: String {
            switch self {
            case .add: return tr("protected", "geschützt")
            case .remove: return tr("unlocked", "entsperrt")
            }
        }
    }

    static var qpdfPath: String? { Shell.which("qpdf") }
    static var unsupportedCharactersHint: String {
        tr("Umlauts, \u{00DF} and other special letters can't be used in the password: Apple's PDF engine, "
            + "which Preview uses, would not accept the correct password, and the PDF could not be opened in Preview. "
            + "Please use only A\u{2013}Z, a\u{2013}z, digits, spaces and common symbols such as ! ? - _ #.",
           "Umlaute, \u{00DF} und andere Sonderbuchstaben gehen im Passwort nicht: Apples PDF-Technik, "
            + "die auch Vorschau verwendet, würde das richtige Passwort nicht annehmen, und das PDF ließe sich in Vorschau nicht öffnen. "
            + "Bitte verwende nur A\u{2013}Z, a\u{2013}z, Ziffern, Leerzeichen und gängige Zeichen wie ! ? - _ #.")
    }
    static var qpdfMissingHint: String { tr("PDF passwords need qpdf. To install it, run \u{201C}brew install qpdf\u{201D} in Terminal.", "Für PDF-Passwörter brauchst du qpdf. Zum Installieren gib im Terminal \u{201E}brew install qpdf\u{201C} ein.") }

    /// Why this password can't be used, or nil. Only A–Z, digits, space and common symbols: qpdf encrypts umlauts
    /// correctly, but Apple's PDFKit (Preview) then doesn't accept the password, and a line break would split qpdf's input.
    static func passwordProblem(_ password: String) -> String? {
        if password.isEmpty { return tr("Please enter a password.", "Bitte gib ein Passwort ein.") }
        guard password.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return unsupportedCharactersHint }
        return nil
    }

    /// True when the PDF is encrypted (with an open password or only with restrictions).
    static func isProtected(_ url: URL) -> Bool {
        PDFDocument(url: url)?.isEncrypted ?? false
    }

    /// The suitable action for these files: remove when the first one has a password, otherwise add.
    static func suggestedAction(for urls: [URL]) -> Action {
        urls.first.map(isProtected) == true ? .remove : .add
    }

    /// What qpdf reads from its standard input, one argument per line (qpdf's "@-").
    static func arguments(_ action: Action, password: String, input: URL, output: URL) -> [String] {
        switch action {
        case .add:
            // The same password opens the file and allows everything; AES-256 is qpdf's "--bits=256".
            return ["--encrypt", "--user-password=\(password)", "--owner-password=\(password)", "--bits=256", "--", input.path, output.path]
        case .remove:
            return ["--password=\(password)", "--decrypt", input.path, output.path]
        }
    }

    /// Writes a new file next to the original ("Name protected.pdf" / "Name unlocked.pdf"); returns it.
    static func run(_ action: Action, on url: URL, password: String, in directory: URL, qpdf: String? = qpdfPath) async throws -> URL {
        guard let qpdf else { throw AppError.invalidInput(qpdfMissingHint) }
        let name = url.lastPathComponent
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        // A PDF that opens without a password but has restrictions (no printing, ...) needs no password to remove them.
        let needsPassword = action == .add || document.isLocked
        let password = needsPassword ? password : ""
        if needsPassword, let problem = passwordProblem(password) { throw AppError.invalidInput(problem) }
        switch action {
        case .add:
            guard !document.isEncrypted else { throw AppError.invalidInput(tr("\(name) already has a password. Remove it first.", "\(name) hat schon ein Passwort. Entferne es zuerst.")) }
        case .remove:
            guard document.isEncrypted else { throw AppError.invalidInput(tr("\(name) has no password.", "\(name) hat kein Passwort.")) }
            guard !document.isLocked || document.unlock(withPassword: password) else {
                throw AppError.invalidInput(tr("The password for \(name) is not correct.", "Das Passwort für \(name) ist nicht richtig."))
            }
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-password-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let staged = work.appendingPathComponent("result.pdf")
        let lines = arguments(action, password: password, input: url, output: staged)
        guard !lines.contains(where: { $0.contains(where: \.isNewline) }) else {
            throw AppError.invalidInput(tr("\(name) can't be handled because its path contains a line break.", "\(name) lässt sich nicht bearbeiten, weil sein Pfad einen Zeilenumbruch enthält."))
        }
        let result = try await Shell.run(qpdf, ["@-"], input: Data((lines.joined(separator: "\n") + "\n").utf8))
        try Task.checkCancellation()
        // qpdf: 0 = fine, 3 = fine with warnings (e.g. a slightly damaged file it repaired).
        guard result.status == 0 || result.status == 3, FileManager.default.fileExists(atPath: staged.path) else {
            let stderr = password.isEmpty ? result.stderr : result.stderr.replacingOccurrences(of: password, with: "•••")
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.toolFailed("qpdf", message.isEmpty ? tr("exit code \(result.status)", "Fehlercode \(result.status)") : message)
        }
        guard let check = PDFDocument(url: staged), check.isEncrypted == (action == .add) else {
            throw AppError.encodeFailed(name)
        }
        let destination = ConversionMatrix.uniqueURL(directory: directory, baseName: ConversionMatrix.strippedBaseName(name), suffix: action.suffix, ext: "pdf")
        try FileManager.default.moveItem(at: staged, to: destination)
        DiagnosticLog.log("pdf password: \(action.rawValue), qpdf exit \(result.status)")
        return destination
    }
}
