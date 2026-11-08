import Foundation

enum AppError: LocalizedError {
    case unsupportedConversion(FileFormat, FileFormat)
    case unreadable(URL)
    case encodeFailed(String)
    case ffmpegMissing(String)
    case toolFailed(String, String)
    case cancelled
    case invalidInput(String)
    case noAudioTrack(String)
    case ffmpegEncoderMissing(String, String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedConversion(from, to):
            return tr("Converting \(from.displayName) to \(to.displayName) is not supported.", "\(from.displayName) kann nicht in \(to.displayName) umgewandelt werden.")
        case let .unreadable(url):
            return tr("Could not read \(url.lastPathComponent). It may be damaged or not really this kind of file.", "\(url.lastPathComponent) konnte nicht gelesen werden. Die Datei ist vielleicht beschädigt oder keine echte Datei dieser Art.")
        case let .encodeFailed(what):
            return tr("Could not write \(what). The original may be damaged.", "Schreiben fehlgeschlagen: \(what). Das Original ist vielleicht beschädigt.")
        case let .ffmpegMissing(what):
            return tr("\(what) needs ffmpeg. Install it (for example with \u{201C}brew install ffmpeg\u{201D}) or set its path in Settings.",
                      "\(what): Dafür brauchst du ffmpeg. Installiere es (zum Beispiel mit \u{201E}brew install ffmpeg\u{201C}) oder gib seinen Pfad in den Einstellungen an.")
        case let .toolFailed(tool, output):
            return tr("\(tool) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))", "Fehler bei \(tool): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        case .cancelled:
            return tr("Canceled.", "Abgebrochen.")
        case let .invalidInput(reason):
            return reason
        case let .ffmpegEncoderMissing(purpose, encoder):
            return tr("\(purpose) needs the ffmpeg component \u{201C}\(encoder)\u{201D}, which the installed ffmpeg does not include. "
                + "To fix this, run \u{201C}brew install ffmpeg-full\u{201D} in Terminal.",
                      "\(purpose): Dafür brauchst du den ffmpeg-Baustein \u{201E}\(encoder)\u{201C}, der im installierten ffmpeg fehlt. "
                + "Führe dazu im Terminal \u{201E}brew install ffmpeg-full\u{201C} aus.")
        case let .noAudioTrack(file):
            return tr("\(file) has no sound, so there is nothing to save as audio.", "\(file) hat keinen Ton, es gibt also nichts als Audio zu sichern.")
        }
    }
}

/// What a failed job tells the person. Apple's and other programs' texts often say little ("Could not write Disk Full."), so the two
/// most common causes are looked for here, whatever step noticed them.
enum FailureMessage {
    /// Below this much free space, a failed write is put down to the disk.
    static let lowSpaceBytes: Int64 = 100_000_000

    static func text(for error: Error, folder: URL?) -> String {
        let plain = cleaned(error.localizedDescription)
        guard isAboutWriting(error) else { return plain }
        if let folder, !FileManager.default.isWritableFile(atPath: folder.path) {
            return tr("\u{201C}\(folder.lastPathComponent)\u{201D} is read-only, so the result can\u{2019}t be saved there. Copy the file to another folder and try again.",
                      "\u{201E}\(folder.lastPathComponent)\u{201C} ist schreibgeschützt, deshalb kann das Ergebnis dort nicht gesichert werden. Kopiere die Datei in einen anderen Ordner und versuche es erneut.")
        }
        if saysDiskFull(plain) || hasLittleSpace(at: folder) || hasLittleSpace(at: FileManager.default.temporaryDirectory) {
            return tr("There isn\u{2019}t enough free space on the disk to save the result. Free up some space and try again.",
                      "Auf der Festplatte ist nicht genug Platz frei, um das Ergebnis zu sichern. Gib etwas Speicherplatz frei und versuche es erneut.")
        }
        return plain
    }

    /// Only for errors of writing: "wrong password" or "no images found" are not about the disk.
    private static func isAboutWriting(_ error: Error) -> Bool {
        if case AppError.encodeFailed = error { return true }
        if case AppError.toolFailed = error { return true }
        return (error as NSError).domain == NSCocoaErrorDomain || (error as NSError).domain == NSPOSIXErrorDomain
    }

    private static func saysDiskFull(_ text: String) -> Bool {
        ["no space left", "disk full", "enough space", "enough free space", "festplatte voll"].contains { text.lowercased().contains($0) }
    }

    private static func hasLittleSpace(at folder: URL?) -> Bool {
        guard let folder, let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity else { return false }
        return Int64(free) < lowSpaceBytes
    }

    /// Names of the app's own temporary files mean nothing to anyone.
    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: #"twistel-[A-Za-z]*-?[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}[^\s”"]*"#, with: tr("the file", "die Datei"), options: .regularExpression)
    }
}

/// Looks at a file before any work starts: an empty one must not turn into an empty page, random bytes with an Office name not into a page of gibberish
/// (LibreOffice reads anything as text and ends "successfully").
enum InputCheck {
    static func check(_ url: URL) throws {
        var isFolder: ObjCBool = false
        // A missing file is for the work to report; a folder (RTFD) is what it is.
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return }
        guard FileSizeFormatter.size(of: url) > 0 else {
            throw AppError.invalidInput(tr("\(url.lastPathComponent) is empty, so there is nothing to work with.", "\(url.lastPathComponent) ist leer, es gibt also nichts zu bearbeiten."))
        }
        guard let format = FileFormat.detect(url), [.docx, .doc, .xlsx, .xls, .pptx, .ppt, .odt, .ods, .odp, .epub].contains(format),
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let start = (try? handle.read(upToCount: 4_096)) ?? Data()
        guard !looksLikeOfficeFile(start) else { return }
        throw AppError.invalidInput(tr("\(url.lastPathComponent) could not be read. It is damaged or not a real \(format.displayName) file.",
                                        "\(url.lastPathComponent) konnte nicht gelesen werden. Die Datei ist beschädigt oder keine echte \(format.displayName)-Datei."))
    }

    /// A ZIP (DOCX, ODT, EPUB, …), an old Office file, or text: a .doc can be RTF or HTML, and Word opens those too.
    static func looksLikeOfficeFile(_ start: Data) -> Bool {
        let bytes = [UInt8](start.prefix(4))
        if bytes == [0x50, 0x4B, 0x03, 0x04] || bytes == [0xD0, 0xCF, 0x11, 0xE0] { return true }
        return !start.contains(0)
    }
}
