import Foundation

/// An installed LibreOffice, called as a separate program without any window (`--headless`); nothing of it is part of
/// the app. Each call gets its own temporary profile and font cache, removed afterwards, so nothing is left in the
/// user's folders (without `XDG_CACHE_HOME` it wrote a font cache to ~/.cache/fontconfig).
enum LibreOffice {
    static var missingHint: String {
        tr("This needs LibreOffice, which is free. Install it with Homebrew: brew install --cask libreoffice",
           "Dafür brauchst du LibreOffice, das kostenlos ist. Installiere es mit Homebrew: brew install --cask libreoffice")
    }

    static var path: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/LibreOffice.app/Contents/MacOS/soffice", "\(home)/Applications/LibreOffice.app/Contents/MacOS/soffice"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { path != nil }

    /// LibreOffice's name for writing each target, with its filter where the extension alone is ambiguous.
    static func filter(for target: FileFormat) -> String? {
        switch target {
        case .pdf: return "pdf"
        case .docx: return "docx:MS Word 2007 XML"
        case .odt: return "odt"
        case .rtf: return "rtf"
        case .html: return "html"
        case .txt: return "txt:Text (encoded):UTF8"
        case .xlsx: return "xlsx:Calc MS Excel 2007 XML"
        case .ods: return "ods"
        // Field separator, text delimiter ("), UTF-8 (76), first line as is.
        case .csv: return "csv:Text - txt - csv (StarCalc):44,34,76,1"
        case .tsv: return "csv:Text - txt - csv (StarCalc):9,34,76,1"
        case .pptx: return "pptx:Impress MS PowerPoint 2007 XML"
        case .odp: return "odp"
        case .epub: return "epub"
        default: return nil
        }
    }

    /// The throwaway profile's settings: LibreOffice is to load nothing from outside the document, also where the network lock
    /// (`Shell.withoutNetwork`) would stop it anyway. No macros, no embedded objects or DDE, no links from untrusted places, links
    /// never updated, and a proxy that leads nowhere for anything that still tries.
    static let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
        <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableActiveContent" oor:op="fuse"><value>true</value></prop></item>
        <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
        <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
        <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>0</value></prop></item>
        <item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>1</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetProxyType" oor:op="fuse"><value>1</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetHTTPProxyName" oor:op="fuse"><value>127.0.0.1</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetHTTPProxyPort" oor:op="fuse"><value>9</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetHTTPSProxyName" oor:op="fuse"><value>127.0.0.1</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetHTTPSProxyPort" oor:op="fuse"><value>9</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetFTPProxyName" oor:op="fuse"><value>127.0.0.1</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetFTPProxyPort" oor:op="fuse"><value>9</value></prop></item>
        <item oor:path="/org.openoffice.Inet/Settings"><prop oor:name="ooInetNoProxy" oor:op="fuse"><value></value></prop></item>
        </oor:items>

        """

    static func writeSettings(into profile: URL) throws {
        let user = profile.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data(settings.utf8).write(to: user.appendingPathComponent("registrymodifications.xcu"))
    }

    /// Longest time one conversion may take before LibreOffice is stopped (a hidden dialog would otherwise wait forever).
    nonisolated(unsafe) static var timeout: Double = 180

    static func convert(_ source: URL, to target: FileFormat, destination: URL) async throws {
        guard let filter = filter(for: target) else { throw AppError.unsupportedConversion(FileFormat.detect(source) ?? .docx, target) }
        try await convertWithFilter(source, filter: filter, destination: destination)
    }

    /// `filter` as LibreOffice's `--convert-to` takes it, e.g. "doc:MS Word 97".
    static func convertWithFilter(_ source: URL, filter: String, destination: URL) async throws {
        guard let soffice = path else { throw AppError.invalidInput(missingHint) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("twistel-libreoffice-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let input = work.appendingPathComponent("in"), output = work.appendingPathComponent("out")
        try fm.createDirectory(at: input, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        // A copy: LibreOffice puts a hidden lock file next to what it opens, which must never land next to the original.
        let copy = input.appendingPathComponent("document.\(source.pathExtension.lowercased())")
        try fm.copyItem(at: source, to: copy)
        try writeSettings(into: work.appendingPathComponent("profile"))

        let arguments = ["-env:UserInstallation=\(work.appendingPathComponent("profile").absoluteString)", "--headless", "--invisible",
                         "--norestore", "--nologo", "--nodefault", "--nolockcheck", "--nofirststartwizard",
                         "--convert-to", filter, "--outdir", output.path, copy.path]
        let environment = ["XDG_CACHE_HOME": work.appendingPathComponent("cache").path, "TMPDIR": work.path + "/"]
        DiagnosticLog.log("libreoffice \(filter) \(source.lastPathComponent)")
        let result: ShellResult
        do {
            result = try await Shell.run(soffice, arguments, currentDirectory: work, environment: environment, limit: ShellLimit(total: timeout))
        } catch is ShellTimeout {
            throw AppError.toolFailed("LibreOffice", tr("took longer than \(ShellTimeout.readable(timeout)) and was stopped. The file may be damaged or very large.",
                                                    "Es hat länger als \(ShellTimeout.readable(timeout)) gedauert und wurde beendet. Die Datei ist vielleicht beschädigt oder sehr groß."))
        }
        try Task.checkCancellation()
        // LibreOffice ends with 0 even when it could not read the file; only the result counts.
        // The document itself: an HTML export puts its pictures next to it as files of their own.
        let made = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.deletingPathExtension().lastPathComponent == "document" }
            .min { $0.pathExtension.count < $1.pathExtension.count }
        guard let made else {
            DiagnosticLog.log("libreoffice failed: \(result.stderr) \(result.stdout)")
            throw AppError.toolFailed("LibreOffice", tr("could not convert \(source.lastPathComponent). It may be damaged.", "\(source.lastPathComponent) konnte nicht umgewandelt werden. Die Datei ist vielleicht beschädigt."))
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: made, to: destination)
    }
}
