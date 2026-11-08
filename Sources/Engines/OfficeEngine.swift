import Foundation
import PDFKit

/// Office documents. Which way each conversion goes:
/// - CSV, TSV and XLSX among each other: the app's own code (`Spreadsheet`).
/// - With LibreOffice installed: everything with spreadsheets or presentations, DOC, and Word/ODT/RTF/HTML to PDF, DOCX
///   or ODT, because LibreOffice lays out real pages (headers, footers, tables, pictures). Markdown and plain text go to
///   DOCX/ODT through HTML, so their tables survive.
/// - Otherwise Apple's text system (`TextDocuments`), where it can; else a hint how to install LibreOffice.
/// - JPG and PNG: through a PDF (made as above), one picture per page.
/// - EPUB: with LibreOffice from Word, ODT and RTF (pictures included); otherwise from HTML with the app's own e-book
///   writer (`EPUB`). An EPUB is read into one HTML page, which then goes the HTML way.
/// PDF → DOCX is not here: it goes through `PDFToWord` (LibreOffice would make text boxes instead of flowing text).
struct OfficeEngine: ConversionEngine {
    static let ownSpreadsheet: Set<FileFormat> = [.csv, .tsv, .xlsx]
    static let appleReadable: Set<FileFormat> = [.docx, .doc, .odt, .rtf, .rtfd, .textClipping, .html, .md, .txt]
    static let appleWritable: Set<FileFormat> = [.docx, .odt, .rtf, .html, .md, .txt, .pdf]

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from.category == .document, from != .pdf, ConversionMatrix.targets(for: from).contains(to) else { return false }
        // Plain text to PDF, pictures and subtitles stays with DocumentEngine.
        return !(from == .txt && [.pdf, .jpg, .png, .srt, .vtt].contains(to))
    }

    enum Route: Equatable {
        case spreadsheet, libreOffice, libreOfficeThroughHTML, apple, missingLibreOffice
        case throughPDF, ownEPUB, fromEPUB
    }

    static func route(from source: FileFormat, to target: FileFormat, libreOffice: Bool = LibreOffice.isAvailable) -> Route {
        if ownSpreadsheet.contains(source), ownSpreadsheet.contains(target) { return .spreadsheet }
        if source == .epub { return .fromEPUB }
        if target == .jpg || target == .png { return .throughPDF }
        if target == .epub { return libreOffice && [.docx, .doc, .odt, .rtf].contains(source) ? .libreOffice : .ownEPUB }
        let officeOnly = !appleReadable.contains(source) || !appleWritable.contains(target)
        if officeOnly { return libreOffice ? .libreOffice : .missingLibreOffice }
        if libreOffice {
            if source == .doc { return .libreOffice }
            if [.pdf, .docx, .odt].contains(target), [.docx, .odt, .rtf, .html].contains(source) { return .libreOffice }
            // Through HTML: Markdown and text keep their tables; RTFD and clippings their pictures (Apple's DOCX writer
            // leaves out both).
            if [.docx, .odt].contains(target), [.md, .txt, .rtfd, .textClipping].contains(source) { return .libreOfficeThroughHTML }
        }
        return .apple
    }

    /// CSV for Excel on this Mac (`Spreadsheet.csv`); TSV as data for other programs: UTF-8 without byte order mark,
    /// decimal point.
    static func writeDelimited(_ table: Spreadsheet, as target: FileFormat, to destination: URL) throws {
        let text = target == .tsv ? table.delimited(separator: "\t") : table.csv()
        try text.write(to: destination, atomically: false, encoding: .utf8)
    }

    func convert(_ request: ConversionRequest) async throws {
        let source = request.sourceFormat, target = request.target
        let route = Self.route(from: source, to: target)
        DiagnosticLog.log("office \(source.rawValue) -> \(target.rawValue) via \(route)")
        request.progress(0.1)
        switch route {
        case .spreadsheet:
            let table = source == .xlsx ? try await Spreadsheet.readXLSX(request.source)
                : Spreadsheet.readDelimited(try Data(contentsOf: request.source), separator: source == .tsv ? "\t" : nil)
            if target == .xlsx { try await table.writeXLSX(to: request.destination) } else { try Self.writeDelimited(table, as: target, to: request.destination) }
        case .libreOffice where [.csv, .tsv].contains(source):
            // LibreOffice guesses encoding and separator on its own (and reads "3,49" as text); the app's reading is surer,
            // so it gets the table as XLSX.
            let xlsx = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-\(UUID().uuidString).xlsx")
            defer { try? FileManager.default.removeItem(at: xlsx) }
            try await Spreadsheet.readDelimited(try Data(contentsOf: request.source), separator: source == .tsv ? "\t" : nil).writeXLSX(to: xlsx)
            try await LibreOffice.convert(xlsx, to: target, destination: request.destination)
        case .libreOffice where [.csv, .tsv].contains(target):
            // LibreOffice writes the cells as shown (dates stay dates) with semicolons; the app then writes the file as
            // for its own tables, so BOM, separator and decimal mark are the same on every way.
            let csv = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-\(UUID().uuidString).csv")
            defer { try? FileManager.default.removeItem(at: csv) }
            try await LibreOffice.convertWithFilter(request.source, filter: "csv:Text - txt - csv (StarCalc):59,34,76,1", destination: csv)
            try Self.writeDelimited(Spreadsheet.readDelimited(try Data(contentsOf: csv), separator: ";"), as: target, to: request.destination)
        case .libreOffice:
            try await LibreOffice.convert(request.source, to: target, destination: request.destination)
        case .libreOfficeThroughHTML:
            let html = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-\(UUID().uuidString).html")
            defer { try? FileManager.default.removeItem(at: html) }
            try TextDocuments.write(try await TextDocuments.read(request.source, format: source), as: .html, to: html)
            try await LibreOffice.convert(html, to: target, destination: request.destination)
        case .apple:
            let text = try await TextDocuments.read(request.source, format: source)
            try Task.checkCancellation()
            try TextDocuments.write(text, as: target, to: request.destination)
        case .throughPDF:
            let fm = FileManager.default
            let pdf = fm.temporaryDirectory.appendingPathComponent("twistel-\(UUID().uuidString).pdf")
            defer { try? fm.removeItem(at: pdf) }
            try await convert(ConversionRequest(source: request.source, sourceFormat: source, target: .pdf, destination: pdf,
                                                progress: { request.progress(0.1 + $0 * 0.6) }))
            guard let document = PDFDocument(url: pdf) else { throw AppError.unreadable(pdf) }
            try DocumentEngine.writePageImages(document, baseName: ConversionMatrix.strippedBaseName(request.source.lastPathComponent),
                                               format: target, to: request.destination, progress: { request.progress(0.7 + $0 * 0.3) })
        case .ownEPUB:
            try await EPUB.write(try await Self.book(of: request.source, format: source), to: request.destination)
        case .fromEPUB:
            let book = try await EPUB.read(request.source)
            if target == .html {
                try book.html().write(to: request.destination, atomically: false, encoding: .utf8)
            } else {
                // One HTML page with the pictures inside: LibreOffice only links picture files beside a page, and the Word
                // file then had none.
                let page = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-book-\(UUID().uuidString).html")
                defer { try? FileManager.default.removeItem(at: page) }
                try book.html().write(to: page, atomically: false, encoding: .utf8)
                try await convert(ConversionRequest(source: page, sourceFormat: .html, target: target, destination: request.destination, progress: request.progress))
            }
        case .missingLibreOffice:
            throw AppError.invalidInput("\(source.displayName) → \(target.displayName): \(LibreOffice.missingHint)")
        }
        request.progress(1)
    }

    /// The e-book of a text document: HTML as it is (with pictures beside it), plain text paragraph by paragraph,
    /// everything else through Apple's text system (pictures included).
    static func book(of url: URL, format: FileFormat) async throws -> EPUB.Book {
        let title = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        switch format {
        case .html:
            return try EPUB.book(html: try Data(contentsOf: url), base: url.deletingLastPathComponent(), title: title)
        case .txt:
            return try EPUB.book(html: Data(TextDocuments.html(plainText: try TextFile.read(url), title: title).utf8), base: nil, title: title)
        default:
            let text = try await TextDocuments.read(url, format: format)
            return try EPUB.book(html: Data(try TextDocuments.html(text).utf8), base: nil, title: title)
        }
    }
}
