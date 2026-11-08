import AppKit
import Foundation
import PDFKit

struct PDFPageRef: Identifiable, Equatable {
    let id = UUID()
    let sourceIndex: Int
    var rotation: Int
    var sourceURL: URL

    static func == (lhs: PDFPageRef, rhs: PDFPageRef) -> Bool {
        lhs.id == rhs.id && lhs.rotation == rhs.rotation
    }
}

enum PDFOps {
    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
        if document.isLocked { throw AppError.invalidInput(tr("\(url.lastPathComponent) is password protected.", "\(url.lastPathComponent) ist mit einem Passwort geschützt.")) }
        return document
    }

    static func merge(_ urls: [URL], to destination: URL) throws {
        let output = PDFDocument()
        for url in urls {
            let source = try document(url)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else { continue }
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.write(to: destination) else { throw AppError.encodeFailed(destination.lastPathComponent) }
    }

    /// The selected pages in their current order in the list (not in the order they were clicked).
    static func selection(of pages: [PDFPageRef], selected: Set<UUID>) -> [PDFPageRef] {
        pages.filter { selected.contains($0.id) }
    }

    static func assemble(pages: [PDFPageRef], to destination: URL) throws {
        var cache: [URL: PDFDocument] = [:]
        let output = PDFDocument()
        for ref in pages {
            let source: PDFDocument
            if let cached = cache[ref.sourceURL] {
                source = cached
            } else {
                source = try document(ref.sourceURL)
                cache[ref.sourceURL] = source
            }
            guard let page = source.page(at: ref.sourceIndex), let copy = page.copy() as? PDFPage else { continue }
            copy.rotation = ref.rotation
            output.insert(copy, at: output.pageCount)
        }
        guard output.pageCount > 0 else { throw AppError.invalidInput(tr("The document would have no pages.", "Das Dokument hätte keine Seiten.")) }
        guard output.write(to: destination) else { throw AppError.encodeFailed(destination.lastPathComponent) }
    }

    enum SplitMode: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everyPage: return tr("One file per page", "Eine Datei pro Seite")
            case .everyN: return tr("Every N pages", "Alle N Seiten")
            case .ranges: return tr("Custom page ranges", "Eigene Seitenbereiche")
            }
        }
    }

    static func parseRanges(_ text: String, pageCount: Int) -> [ClosedRange<Int>] {
        text.split(separator: ",").compactMap { token in
            let part = token.trimmingCharacters(in: .whitespaces)
            if let dash = part.range(of: "-") {
                let a = Int(part[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 1
                let b = Int(part[dash.upperBound...].trimmingCharacters(in: .whitespaces)) ?? pageCount
                let lower = max(1, min(a, b)), upper = min(pageCount, max(a, b))
                return lower <= upper ? lower...upper : nil
            }
            if let single = Int(part), single >= 1, single <= pageCount { return single...single }
            return nil
        }
    }

    static func split(_ url: URL, mode: SplitMode, every: Int, ranges: String, into folder: URL) throws -> [URL] {
        let source = try document(url)
        let count = source.pageCount
        let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
        var groups: [ClosedRange<Int>] = []
        switch mode {
        case .everyPage:
            groups = (1...max(1, count)).map { $0...$0 }
        case .everyN:
            let n = max(1, every)
            var start = 1
            while start <= count {
                groups.append(start...min(count, start + n - 1))
                start += n
            }
        case .ranges:
            groups = parseRanges(ranges, pageCount: count)
        }
        guard !groups.isEmpty else { throw AppError.invalidInput(tr("No valid page ranges.", "Keine gültigen Seitenbereiche.")) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (index, group) in groups.enumerated() {
            let part = PDFDocument()
            for pageNumber in group {
                guard let page = source.page(at: pageNumber - 1) else { continue }
                part.insert(page, at: part.pageCount)
            }
            let name = group.count == 1 ? "\(base) \(tr("page", "Seite")) \(group.lowerBound).pdf" : "\(base) \(tr("pages", "Seiten")) \(group.lowerBound)-\(group.upperBound).pdf"
            let output = folder.appendingPathComponent(name.isEmpty ? "\(base) \(tr("part", "Teil")) \(index + 1).pdf" : name)
            guard part.write(to: output) else { throw AppError.encodeFailed(output.lastPathComponent) }
            outputs.append(output)
        }
        return outputs
    }

    static func compress(_ url: URL, strong: Bool, to destination: URL) throws {
        let source = try document(url)
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        if strong {
            let rendered = PDFDocument()
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index), let image = PDFRenderer.render(page: page, dpi: 110) else { continue }
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-pdfpage-\(UUID().uuidString).jpg")
                try ImageIOBridge.write(image, to: temp, format: .jpg, quality: 0.6)
                defer { try? FileManager.default.removeItem(at: temp) }
                if let nsImage = NSImage(contentsOf: temp), let newPage = PDFPage(image: nsImage) {
                    rendered.insert(newPage, at: rendered.pageCount)
                }
            }
            guard rendered.write(to: destination, withOptions: options) else { throw AppError.encodeFailed(destination.lastPathComponent) }
            return
        }
        guard source.write(to: destination, withOptions: options) else { throw AppError.encodeFailed(destination.lastPathComponent) }
    }

    static func fromImages(_ urls: [URL], to destination: URL, progress: @escaping (Double) -> Void) throws {
        let output = PDFDocument()
        for (index, url) in urls.enumerated() {
            let image = try ImageIOBridge.load(url)
            let nsImage = ImageOps.nsImage(image)
            if let page = PDFPage(image: nsImage) {
                output.insert(page, at: output.pageCount)
            }
            progress(Double(index + 1) / Double(urls.count))
        }
        guard output.pageCount > 0 else { throw AppError.invalidInput(tr("No images could be read.", "Es konnten keine Bilder gelesen werden.")) }
        guard output.write(to: destination) else { throw AppError.encodeFailed(destination.lastPathComponent) }
    }
}
