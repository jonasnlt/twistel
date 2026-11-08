import Foundation

/// The separate programs some conversions and tools call (never part of the app). The ring greys out what needs a missing one,
/// Settings › Helper programs lists them all.
enum HelperProgram: String, CaseIterable, Identifiable, Sendable {
    case ffmpeg
    case libreOffice
    case ghostscript
    case qpdf
    case whisper
    case pdftotext
    case unar

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ffmpeg: return "FFmpeg"
        case .libreOffice: return "LibreOffice"
        case .ghostscript: return "Ghostscript"
        case .qpdf: return "qpdf"
        case .whisper: return "whisper.cpp"
        case .pdftotext: return "Poppler (pdftotext)"
        case .unar: return "unar"
        }
    }

    /// What it is used for, in one line.
    var purpose: String {
        switch self {
        case .ffmpeg: return tr("Audio and video formats Apple can\u{2019}t write (MP3, FLAC, OGG, WebM, MKV, AVI, GIF …).",
                                "Audio- und Videoformate, die Apple nicht schreiben kann (MP3, FLAC, OGG, WebM, MKV, AVI, GIF …).")
        case .libreOffice: return tr("Word, Excel and PowerPoint files with real page layout; DOC, XLS, PPT, ODS, ODP.",
                                     "Word-, Excel- und PowerPoint-Dateien mit echtem Seitenaufbau; DOC, XLS, PPT, ODS, ODP.")
        case .ghostscript: return tr("Strong PDF compression with selectable text, and PDF/A.",
                                     "Starkes Verkleinern von PDFs mit markierbarem Text und PDF/A.")
        case .qpdf: return tr("PDF passwords (AES-256).", "PDF-Passwörter (AES-256).")
        case .whisper: return tr("Transcription and subtitles from speech.", "Transkription und Untertitel aus Sprache.")
        case .pdftotext: return tr("An extra check after redacting a PDF.", "Eine zusätzliche Prüfung nach dem Schwärzen einer PDF.")
        case .unar: return tr("Extracting RAR archives.", "Entpacken von RAR-Archiven.")
        }
    }

    /// What to type in Terminal (Homebrew).
    var installCommand: String {
        switch self {
        case .ffmpeg: return "brew install ffmpeg"
        case .libreOffice: return "brew install --cask libreoffice"
        case .ghostscript: return "brew install ghostscript"
        case .qpdf: return "brew install qpdf"
        case .whisper: return "brew install whisper-cpp"
        case .pdftotext: return "brew install poppler"
        case .unar: return "brew install unar"
        }
    }

    /// Where it was found, or nil. Looks at the disk; `HelperPrograms.isInstalled` keeps the answer for a moment.
    func locate() -> String? {
        switch self {
        case .ffmpeg: return FFmpeg.path
        case .libreOffice: return LibreOffice.path
        case .ghostscript: return PDFCompression.ghostscriptPath
        case .qpdf: return PDFPassword.qpdfPath
        case .whisper: return Transcriber.whisperPath
        case .pdftotext: return Shell.which("pdftotext")
        case .unar: return Shell.which("unar")
        }
    }
}

/// Which helper programs are installed, asked once and kept for a few seconds: the ring has to appear at once and must not look
/// at the disk while it opens.
enum HelperPrograms {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [HelperProgram: Bool] = [:]
    nonisolated(unsafe) private static var checked = Date.distantPast
    /// For tests: what counts as installed, instead of looking.
    nonisolated(unsafe) static var override: Set<HelperProgram>?

    static func isInstalled(_ program: HelperProgram) -> Bool {
        if let override { return override.contains(program) }
        return lock.withLock { known[program] } ?? refreshNow()[program] ?? false
    }

    /// Looks again in the background when the last look is older than a few seconds (called when the ring opens).
    static func refreshIfOld(maxAge: TimeInterval = 10) {
        let old = lock.withLock { Date().timeIntervalSince(checked) > maxAge }
        guard old else { return }
        DispatchQueue.global(qos: .utility).async { _ = refreshNow() }
    }

    @discardableResult
    static func refreshNow() -> [HelperProgram: Bool] {
        var found: [HelperProgram: Bool] = [:]
        for program in HelperProgram.allCases { found[program] = program.locate() != nil }
        lock.withLock {
            known = found
            checked = Date()
        }
        return found
    }

    /// The program a conversion cannot do without, if it is missing. Programs with a fallback (Ghostscript for compressing) are not
    /// named here: the work still runs.
    static func missing(forConverting sources: [FileFormat], to target: FileFormat) -> HelperProgram? {
        for source in sources {
            if let program = required(forConverting: source, to: target), !isInstalled(program) { return program }
        }
        return nil
    }

    static func required(forConverting source: FileFormat, to target: FileFormat) -> HelperProgram? {
        switch source.category {
        case .audio:
            // Apple reads MP3, M4A, WAV, AIFF and FLAC and writes M4A, WAV and AIFF.
            let appleReads: Set<FileFormat> = [.mp3, .m4a, .wav, .aiff, .flac]
            return AudioEngine.nativeTargets.contains(target) && appleReads.contains(source) ? nil : .ffmpeg
        case .video:
            if target == .mp3 { return .ffmpeg }
            let appleReads: Set<FileFormat> = [.mp4, .mov]
            return VideoEngine.nativeTargets.contains(target) && appleReads.contains(source) ? nil : .ffmpeg
        case .document:
            guard source != .pdf, OfficeEngine().supports(from: source, to: target) else { return nil }
            var route = OfficeEngine.route(from: source, to: target, libreOffice: false)
            // Pictures of a document are made from its PDF.
            if route == .throughPDF { route = OfficeEngine.route(from: source, to: .pdf, libreOffice: false) }
            return route == .missingLibreOffice ? .libreOffice : nil
        case .archive:
            return source == .rar ? .unar : nil
        case .image, .subtitle:
            return nil
        }
    }

    /// The program a tool cannot do without, if it is missing.
    static func missing(forTool tool: ToolID) -> HelperProgram? {
        let needed: HelperProgram?
        switch tool {
        case .transcribe: needed = .whisper
        case .pdfPassword: needed = .qpdf
        case .pdfArchive: needed = .ghostscript
        default: needed = nil
        }
        guard let needed, !isInstalled(needed) else { return nil }
        return needed
    }
}
