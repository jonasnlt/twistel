import CoreGraphics
import Foundation
import PDFKit

/// PDF/A-2b, the format for keeping documents for decades, made by Ghostscript as a separate program, with Apple's sRGB colour profile.
enum PDFArchive {
    static var missingHint: String { tr("PDF/A needs Ghostscript. To install it, run \u{201C}brew install ghostscript\u{201D} in Terminal.", "Für PDF/A brauchst du Ghostscript. Zum Installieren gib im Terminal \u{201E}brew install ghostscript\u{201C} ein.") }
    static let profile = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")
    static var ghostscriptPath: String? { PDFCompression.ghostscriptPath }

    /// What PDF/A wants in the file besides the fonts: the colour profile the document means, as an output intent. Written after Adobe's description of pdfmark.
    static func definition(profile: URL) -> String {
        """
    %!
    [ /_objdef {twistel_profile} /type /stream /OBJ pdfmark
    [ {twistel_profile} << /N 3 >> /PUT pdfmark
    [ {twistel_profile} (\(profile.path)) (r) file /PUT pdfmark
    [ /_objdef {twistel_intent} /type /dict /OBJ pdfmark
    [ {twistel_intent} << /Type /OutputIntent /S /GTS_PDFA1 /DestOutputProfile {twistel_profile} /OutputConditionIdentifier (sRGB) /Info (sRGB) >> /PUT pdfmark
    [ {Catalog} << /OutputIntents [ {twistel_intent} ] >> /PUT pdfmark

    """
    }

    /// Photos stay in their size and nearly as they were: Ghostscript has to convert their colours to sRGB, which means saving them anew, by default much worse
    /// (a 5.5 MB photo became 1.4 MB). It does not accept keeping the colours as they are for PDF/A ("cannot guarantee").
    static let photoQuality = "<< /ColorImageDict << /QFactor 0.15 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> /GrayImageDict << /QFactor 0.15 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >> >> setdistillerparams"

    /// `removesWhatIsNotAllowed`: otherwise Ghostscript stops at anything PDF/A does not allow.
    static func arguments(source: URL, output: URL, work: URL, removesWhatIsNotAllowed: Bool) -> [String] {
        let colours = work.appendingPathComponent("srgb.icc").path
        return ["-dSAFER", "-dPDFA=2", "-dBATCH", "-dNOPAUSE", "-dPDFACompatibilityPolicy=\(removesWhatIsNotAllowed ? 1 : 2)", "-sDEVICE=pdfwrite", "-sColorConversionStrategy=RGB",
         "--permit-file-read=\(colours)", "-sOutputICCProfile=\(colours)", "-dDownsampleColorImages=false", "-dDownsampleGrayImages=false", "-dDownsampleMonoImages=false",
         "-dAutoFilterColorImages=false", "-dAutoFilterGrayImages=false", "-dColorImageFilter=/DCTEncode", "-dGrayImageFilter=/DCTEncode",
         // Otherwise the fonts lose what says which letter is which: the page looks right, but its text can no longer be searched or copied.
         "-dSubsetFonts=false",
         // Ghostscript reads % in the output name as a page-number pattern.
         "-sOutputFile=\(output.path.replacingOccurrences(of: "%", with: "%%"))", "-c", photoQuality, "-f", work.appendingPathComponent("definition.ps").path, source.path]
    }

    static func convert(_ url: URL, to destination: URL, ghostscript: String? = ghostscriptPath, progress: @escaping (Double) -> Void) async throws {
        guard let ghostscript else { throw AppError.invalidInput(missingHint) }
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        guard !document.isEncrypted, !document.isLocked else {
            throw AppError.invalidInput(tr("\(url.lastPathComponent) is protected by a password, which PDF/A does not allow. Remove it first with PDF password.", "\(url.lastPathComponent) ist mit einem Passwort geschützt, und das erlaubt PDF/A nicht. Entferne es zuerst mit \u{201E}PDF-Passwort\u{201C}."))
        }
        let pages = max(1, document.pageCount)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-pdfa-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: profile, to: work.appendingPathComponent("srgb.icc"))
        try definition(profile: work.appendingPathComponent("srgb.icc")).write(to: work.appendingPathComponent("definition.ps"), atomically: false, encoding: .utf8)
        let output = work.appendingPathComponent("archive.pdf")

        func run(removing: Bool) async throws -> Bool {
            try? FileManager.default.removeItem(at: output)
            let result = try await Shell.run(ghostscript, arguments(source: PDFCompression.plainNamed(url, in: work), output: output, work: work, removesWhatIsNotAllowed: removing), environment: ["TMPDIR": work.path + "/"], limit: .work) { line in
                if let page = PDFCompression.pageNumber(inGhostscriptLine: line) { progress(min(0.95, Double(page) / Double(pages))) }
            }
            try Task.checkCancellation()
            return result.succeeded && FileManager.default.fileExists(atPath: output.path)
        }
        var removed = false
        if !(try await run(removing: false)) {
            removed = true
            guard try await run(removing: true) else {
                throw AppError.invalidInput(tr("Ghostscript could not make a PDF/A file from \(url.lastPathComponent).", "Ghostscript konnte aus \(url.lastPathComponent) keine PDF/A-Datei machen."))
            }
        }
        let found = problems(in: output)
        guard found.isEmpty else {
            DiagnosticLog.log("PDF/A check failed: \(found)")
            throw AppError.invalidInput(tr("The result did not pass the PDF/A check, so nothing was saved: \(found.joined(separator: "; ")).", "Das Ergebnis hat die PDF/A-Prüfung nicht bestanden, deshalb wurde nichts gesichert: \(found.joined(separator: "; "))."))
        }
        guard let result = PDFDocument(url: output), result.pageCount == document.pageCount else { throw AppError.invalidInput(tr("The result has a different number of pages, so nothing was saved.", "Das Ergebnis hat eine andere Seitenzahl, deshalb wurde nichts gesichert.")) }
        guard keepsText(of: document, in: result) else {
            throw AppError.invalidInput(tr("The text of \(url.lastPathComponent) could not be kept searchable in PDF/A, so nothing was saved.", "Der Text von \(url.lastPathComponent) wäre in PDF/A nicht durchsuchbar geblieben, deshalb wurde nichts gesichert."))
        }
        if removed { JobNotes.add(tr("PDF/A does not allow everything this PDF had: what is not allowed was removed (for example attachments or scripts). Please check the result.", "PDF/A erlaubt nicht alles, was in diesem PDF war: Nicht Erlaubtes wurde entfernt (zum Beispiel Anhänge oder Skripte). Bitte prüf das Ergebnis.")) }
        // Ghostscript keeps what a form shows, as plain text on the page.
        if PDFStamp.hasFormFields(url) { JobNotes.add(tr("The form fields of this PDF can no longer be filled in: their values are now plain text.", "Die Formularfelder dieses PDFs lassen sich nicht mehr ausfüllen: Ihre Inhalte sind jetzt einfacher Text.")) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: output, to: destination)
        progress(1)
    }

    /// Whether the words of the original can still be read out of the result, in the same order. Added text (a form's values) does no harm.
    static func keepsText(of original: PDFDocument, in result: PDFDocument) -> Bool {
        func letters(_ document: PDFDocument) -> [Character] { Array((document.string ?? "").filter { !$0.isWhitespace }) }
        let before = letters(original), after = letters(result)
        guard !before.isEmpty else { return true }
        var found = 0, place = 0
        for character in before {
            guard let next = after[place...].firstIndex(of: character) else { continue }
            found += 1
            place = next + 1
        }
        return Double(found) >= Double(before.count) * 0.98
    }

    // MARK: Checking the result

    /// What this app can check itself, without an official checker (veraPDF needs Java): the main things a PDF/A file must have, not all of its several hundred rules.
    /// Empty when all is well.
    static func problems(in url: URL) -> [String] {
        guard let document = CGPDFDocument(url as CFURL) else { return [tr("the file cannot be read", "die Datei lässt sich nicht lesen")] }
        var problems: [String] = []
        if document.isEncrypted { problems.append(tr("it is encrypted", "sie ist verschlüsselt")) }
        var major: Int32 = 0, minor: Int32 = 0
        document.getVersion(majorVersion: &major, minorVersion: &minor)
        if major != 1 || minor > 7 { problems.append(tr("PDF version \(major).\(minor) is too new", "die PDF-Version \(major).\(minor) ist zu neu")) }
        guard let catalog = document.catalog else { return problems + [tr("it has no catalog", "sie hat keinen Katalog")] }
        if !hasProfile(catalog) { problems.append(tr("the color profile (output intent) is missing", "das Farbprofil (Output Intent) fehlt")) }
        if !namesConformance(catalog) { problems.append(tr("it does not call itself PDF/A-2b", "sie bezeichnet sich nicht als PDF/A-2b")) }
        var seen = Set<CGPDFDictionaryRef>()
        var missing = Set<String>(), cmyk = false
        for number in 0..<document.numberOfPages {
            guard let page = document.page(at: number + 1)?.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources { look(at: resources, seen: &seen, missing: &missing, cmyk: &cmyk) }
        }
        if !missing.isEmpty { problems.append(tr("fonts not embedded: \(missing.sorted().joined(separator: ", "))", "Schriften nicht eingebettet: \(missing.sorted().joined(separator: ", "))")) }
        if cmyk { problems.append(tr("it has images in CMYK without a profile", "sie hat CMYK-Bilder ohne Farbprofil")) }
        return problems
    }

    private static func hasProfile(_ catalog: CGPDFDictionaryRef) -> Bool {
        var intents: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents), let intents else { return false }
        for index in 0..<CGPDFArrayGetCount(intents) {
            var intent: CGPDFDictionaryRef?, kind: UnsafePointer<CChar>?, stream: CGPDFStreamRef?
            guard CGPDFArrayGetDictionary(intents, index, &intent), let intent, CGPDFDictionaryGetName(intent, "S", &kind), let kind, String(cString: kind) == "GTS_PDFA1",
                  CGPDFDictionaryGetStream(intent, "DestOutputProfile", &stream), let stream else { continue }
            var format = CGPDFDataFormat.raw
            // A colour profile says "acsp" at this place.
            if let data = CGPDFStreamCopyData(stream, &format) as Data?, data.count > 40, data[36..<40].elementsEqual("acsp".utf8) { return true }
        }
        return false
    }

    private static func namesConformance(_ catalog: CGPDFDictionaryRef) -> Bool {
        var stream: CGPDFStreamRef?
        var format = CGPDFDataFormat.raw
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream, let data = CGPDFStreamCopyData(stream, &format) as Data? else { return false }
        let text = String(decoding: data, as: UTF8.self)
        func says(_ key: String, _ value: String) -> Bool {
            text.contains("pdfaid:\(key)='\(value)'") || text.contains("pdfaid:\(key)=\"\(value)\"") || text.contains("<pdfaid:\(key)>\(value)</pdfaid:\(key)>")
        }
        return says("part", "2") && says("conformance", "B")
    }

    /// Through a page's or form's resources: every font must carry its letters, directly or in its descendant.
    private static func look(at resources: CGPDFDictionaryRef, seen: inout Set<CGPDFDictionaryRef>, missing: inout Set<String>, cmyk: inout Bool) {
        guard seen.insert(resources).inserted else { return }
        var fonts: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts {
            let names = entries(of: fonts)
            for name in names {
                var font: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(fonts, name, &font), let font else { continue }
                if let bare = fontWithoutLetters(font) { missing.insert(bare) }
            }
        }
        var objects: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects {
            for name in entries(of: objects) {
                var stream: CGPDFStreamRef?
                guard CGPDFDictionaryGetStream(objects, name, &stream), let stream, let object = CGPDFStreamGetDictionary(stream) else { continue }
                var space: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(object, "ColorSpace", &space), let space, String(cString: space) == "DeviceCMYK" { cmyk = true }
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(object, "Resources", &inner), let inner { look(at: inner, seen: &seen, missing: &missing, cmyk: &cmyk) }
            }
        }
    }

    private static func entries(of dictionary: CGPDFDictionaryRef) -> [String] {
        final class Names { var list: [String] = [] }
        let names = Names()
        CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
            names.list.append(String(cString: key))
            return true
        }, nil)
        return names.list
    }

    /// The font's name if its letters are not in the file. Type 3 fonts are drawn in the file anyway.
    private static func fontWithoutLetters(_ font: CGPDFDictionaryRef) -> String? {
        func name(_ key: String, in dictionary: CGPDFDictionaryRef) -> String? {
            var value: UnsafePointer<CChar>?
            return CGPDFDictionaryGetName(dictionary, key, &value) ? value.map { String(cString: $0) } : nil
        }
        let label = name("BaseFont", in: font) ?? tr("unnamed", "ohne Namen")
        let subtype = name("Subtype", in: font)
        if subtype == "Type3" { return nil }
        if subtype == "Type0" {
            var descendants: CGPDFArrayRef?, first: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants, CGPDFArrayGetDictionary(descendants, 0, &first), let first else { return label }
            return fontWithoutLetters(first)
        }
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor else { return label }
        for key in ["FontFile", "FontFile2", "FontFile3"] {
            var file: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(descriptor, key, &file) { return nil }
        }
        return label
    }
}
