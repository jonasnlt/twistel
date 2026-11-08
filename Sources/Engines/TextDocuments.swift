import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Text documents with Apple's own text system: RTF, HTML, TXT, DOCX, ODT and DOC are read by `NSAttributedString`;
/// Markdown is translated here. Written are RTF, HTML, TXT, DOCX, ODT (Apple's writers), Markdown (here) and PDF (TextKit).
/// Apple's DOCX writer leaves out tables and pictures; with LibreOffice, `OfficeEngine` uses that.
enum TextDocuments {
    static let bodyFont = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)

    // MARK: Reading

    static func read(_ url: URL, format: FileFormat) async throws -> NSAttributedString {
        switch format {
        case .txt:
            return NSAttributedString(string: try TextFile.read(url), attributes: [.font: bodyFont])
        case .md:
            return Markdown.attributedString(try TextFile.read(url))
        case .html:
            // Apple's HTML reader uses WebKit and must run on the main thread.
            let data = try Data(contentsOf: url)
            return try await MainActor.run { UncheckedBox(try readHTML(data)) }.value
        case .rtfd:
            // An RTFD is a folder: the text (RTF) and its pictures as files.
            return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        case .textClipping:
            return try TextClipping.read(url)
        default:
            guard let type = documentType(format) else { throw AppError.unsupportedConversion(format, .pdf) }
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        }
    }

    @MainActor
    static func readHTML(_ data: Data) throws -> NSAttributedString {
        try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                     .characterEncoding: String.Encoding.utf8.rawValue,
                                                     // It runs on the main thread: a page that waits for something must not freeze the app.
                                                     .timeout: 30], documentAttributes: nil)
    }

    static func documentType(_ format: FileFormat) -> NSAttributedString.DocumentType? {
        switch format {
        case .rtf: return .rtf
        case .docx: return .officeOpenXML
        case .odt: return .openDocument
        case .doc: return .docFormat
        case .html: return .html
        case .txt: return .plain
        default: return nil
        }
    }

    // MARK: Writing

    static func write(_ text: NSAttributedString, as format: FileFormat, to destination: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .txt:
            try text.string.write(to: destination, atomically: false, encoding: .utf8)
        case .md:
            try Markdown.markdown(from: text).write(to: destination, atomically: false, encoding: .utf8)
        case .pdf:
            try AttributedPDF.write(text, to: destination)
        case .html:
            try html(text).write(to: destination, atomically: false, encoding: .utf8)
        case .rtf, .docx, .odt:
            guard let type = documentType(format) else { throw AppError.unsupportedConversion(.rtf, format) }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if format == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
            try text.data(from: range, documentAttributes: attributes).write(to: destination)
        default:
            throw AppError.unsupportedConversion(.rtf, format)
        }
    }
}

extension TextDocuments {
    /// HTML of styled text with its pictures inside, as data: addresses: Apple's writer only names them
    /// ("<img src=\"file:///rot.tiff\">"), so a page made from an RTFD would lose them. Pictures browsers
    /// cannot show (TIFF) become PNG.
    static func html(_ text: NSAttributedString) throws -> String {
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue])
        // Apple's writer keeps the typed list mark as text inside <li>, which shows it twice.
        var html = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #"(<li[^>]*>)(?:•|\d+\.)<span class="Apple-tab-span">\s*</span>"#, with: "$1", options: .regularExpression)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, let wrapper = attachment.fileWrapper,
                  let name = wrapper.preferredFilename ?? wrapper.filename, let contents = wrapper.regularFileContents else { return }
            var picture = contents, type = EPUB.mediaType((name as NSString).pathExtension)
            if !["image/jpeg", "image/png", "image/gif"].contains(type) {
                guard let source = CGImageSourceCreateWithData(contents as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
                let png = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { return }
                (picture, type) = (png as Data, "image/png")
            }
            let address = "data:\(type);base64,\(picture.base64EncodedString())"
            for written in Set([name, name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name]) {
                html = html.replacingOccurrences(of: "src=\"file:///\(written)\"", with: "src=\"\(address)\"")
            }
        }
        return html
    }

    /// HTML of plain text: paragraphs at empty lines, line breaks kept.
    static func html(plainText text: String, title: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>\(EPUB.escape(title))</title></head><body>\n"
            + paragraphs.map { "<p>" + EPUB.escape($0.trimmingCharacters(in: .newlines)).replacingOccurrences(of: "\n", with: "<br/>") + "</p>" }.joined(separator: "\n")
            + "\n</body></html>\n"
    }
}

/// Paginated PDF of styled text with TextKit 1, which draws tables (`NSTextTable`) and pictures; Core Text alone would
/// not. Runs without any view, so it can work in the background. A4 with 2.5 cm margins.
enum AttributedPDF {
    static let pageSize = CGSize(width: 595.3, height: 841.9)
    static let margin: CGFloat = 70.9

    static func write(_ text: NSAttributedString, to destination: URL) throws {
        let storage = NSTextStorage(attributedString: text.length > 0 ? text : NSAttributedString(string: " "))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let size = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)
        var containers: [NSTextContainer] = []
        repeat {
            try Task.checkCancellation()
            JobNotes.beat()
            let container = NSTextContainer(size: size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            _ = layout.glyphRange(for: container)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 5_000

        guard let consumer = CGDataConsumer(url: destination as CFURL) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: AppIdentity.name] as CFDictionary) else {
            throw AppError.encodeFailed(destination.lastPathComponent)
        }
        for container in containers {
            try Task.checkCancellation()
            JobNotes.beat()
            let glyphs = layout.glyphRange(for: container)
            guard glyphs.length > 0 || containers.count == 1 else { continue }
            context.beginPDFPage(nil)
            // TextKit draws with the origin at the top left.
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.current = previous
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// Markdown to styled text and back. Covered: headings, paragraphs, bold, italic, code, links, lists, quotes and tables.
enum Markdown {
    /// A link target for Markdown: web and mail addresses and places in the same file only. "javascript:" or "file:" from a stranger's
    /// document would otherwise become a link that runs something or opens a file of this Mac when clicked.
    static func safeLink(_ url: URL) -> String? {
        let text = url.absoluteString
        if text.hasPrefix("#") { return text.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20") }
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return text.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
    }

    // MARK: Markdown → text

    static func attributedString(_ markdown: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) else {
            return NSAttributedString(string: markdown, attributes: [.font: TextDocuments.bodyFont])
        }
        let result = NSMutableAttributedString()
        var lastBlock: Int?
        var lastAttributes: [NSAttributedString.Key: Any] = [:]
        var tables: [Int: (table: NSTextTable, rows: [Int: Int])] = [:]
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity ?? -1
            // With the paragraph's own style: a line end without it ends a table, and Apple's HTML writer then puts each next cell in a table of its own.
            if let lastBlock, lastBlock != block, !result.string.hasSuffix("\n") { result.append(NSAttributedString(string: "\n", attributes: lastAttributes)) }
            let isNewBlock = lastBlock != block
            lastBlock = block

            var font = TextDocuments.bodyFont
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            var prefix = ""
            for component in components {
                switch component.kind {
                case .header(let level):
                    let sizes: [CGFloat] = [24, 18, 15, 13, 12, 12]
                    font = NSFontManager.shared.convert(NSFont(name: "Helvetica", size: sizes[min(level, 6) - 1]) ?? font, toHaveTrait: .boldFontMask)
                    style.paragraphSpacingBefore = 10
                case .codeBlock:
                    font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                case .blockQuote:
                    style.headIndent = 24
                    style.firstLineHeadIndent = 24
                case .listItem(let ordinal):
                    let ordered = components.contains { if case .orderedList = $0.kind { return true } else { return false } }
                    if isNewBlock || prefix.isEmpty { prefix = ordered ? "\(ordinal).\t" : "•\t" }
                    // A real list, so Markdown, RTF and Word writers know it is one.
                    style.textLists = [NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)]
                    style.headIndent = 24
                    style.firstLineHeadIndent = 6
                    style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
                case .tableCell(let column):
                    guard let tableComponent = components.first(where: { if case .table = $0.kind { return true } else { return false } }),
                          case let .table(columns) = tableComponent.kind else { break }
                    let rowComponent = components.first { component in
                        switch component.kind {
                        case .tableHeaderRow, .tableRow: return true
                        default: return false
                        }
                    }
                    var entry = tables[tableComponent.identity] ?? (NSTextTable(), [:])
                    entry.table.numberOfColumns = columns.count
                    let rowID = rowComponent?.identity ?? 0
                    let row = entry.rows[rowID] ?? entry.rows.count
                    entry.rows[rowID] = row
                    tables[tableComponent.identity] = entry
                    let cell = NSTextTableBlock(table: entry.table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setBorderColor(.gray)
                    cell.setWidth(4, type: .absoluteValueType, for: .padding)
                    style.textBlocks = [cell]
                    if case .tableHeaderRow = rowComponent?.kind { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                default:
                    break
                }
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if inline.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.black]
            if let link = run.link { attributes[.link] = link }
            if isNewBlock, !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: attributes)) }
            result.append(NSAttributedString(string: text, attributes: attributes))
            lastAttributes = attributes
        }
        return result
    }

    // MARK: Text → Markdown

    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { sizes[font.pointSize.rounded(), default: 0] += range.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12

        var blocks: [String] = []
        var table: (id: ObjectIdentifier, cells: [Int: [Int: String]])?
        func closeTable() {
            guard let current = table else { return }
            let rows = current.cells.keys.sorted()
            let columns = (current.cells.values.flatMap(\.keys).max() ?? 0) + 1
            var lines = rows.map { row in "| " + (0..<columns).map { current.cells[row]?[$0] ?? "" }.joined(separator: " | ") + " |" }
            lines.insert("|" + String(repeating: " --- |", count: columns), at: min(1, lines.count))
            blocks.append(lines.joined(separator: "\n"))
            table = nil
        }
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            let style = range.length > 0 ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                let id = ObjectIdentifier(cell.table)
                if table?.id != id { closeTable(); table = (id, [:]) }
                // The header row is bold by itself in Markdown.
                let cellText = text.attributedSubstring(from: range)
                let content = (cell.startingRow == 0 ? WordDocument.markdownText(cellText.string.trimmingCharacters(in: .whitespaces)) : inline(cellText))
                    .replacingOccurrences(of: "|", with: "\\|")
                table?.cells[cell.startingRow, default: [:]][cell.startingColumn] = content
                return
            }
            closeTable()
            var line = text.attributedSubstring(from: range)
            guard !line.string.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if let list = style?.textLists.last {
                // Apple's readers put the marker into the text ("\t•\tItem"); it is written anew.
                let marker = line.string.prefix { "\t •◦▪-–0123456789.)".contains($0) }
                line = line.attributedSubstring(from: NSRange(location: (marker as Substring).utf16.count, length: line.length - (marker as Substring).utf16.count))
                let ordered = [.decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseRoman, .uppercaseRoman].contains(list.markerFormat)
                let depth = max(0, (style?.textLists.count ?? 1) - 1)
                blocks.append(String(repeating: "  ", count: depth) + (ordered ? "1. " : "- ") + inline(line))
                return
            }
            let font = line.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let size = font?.pointSize ?? body
            let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
            // Text from the file is text: "<script>" or "# x" in it must not become HTML or a heading in the Markdown file.
            let plain = WordDocument.markdownText(line.string.trimmingCharacters(in: .whitespaces))
            // Markdown's own sizes are 2, 1.5 and 1.25 times the text; Word's headings 1.6, 1.3 and 1.1.
            if size >= body * 1.75 { blocks.append("# " + plain); return }
            if size >= body * 1.4 { blocks.append("## " + plain); return }
            if plain.hasPrefix("•") || plain.hasPrefix("◦") || plain.hasPrefix("▪") {
                blocks.append("- " + inline(line).drop { "•◦▪ \t".contains($0) })
                return
            }
            if size >= body * 1.15 || (bold && plain.count < 80 && !(plain.last.map { ".,;".contains($0) } ?? false) && isAllBold(line)) {
                blocks.append("### " + plain)
                return
            }
            blocks.append(WordDocument.markdownStart(inline(line)))
        }
        closeTable()
        // Lists stay together; everything else gets an empty line between blocks.
        var output = ""
        for (index, block) in blocks.enumerated() {
            let isItem = block.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || block.trimmingCharacters(in: .whitespaces).range(of: #"^\d+\. "#, options: .regularExpression) != nil
            let previousIsItem = index > 0 && (blocks[index - 1].trimmingCharacters(in: .whitespaces).hasPrefix("- ")
                || blocks[index - 1].trimmingCharacters(in: .whitespaces).range(of: #"^\d+\. "#, options: .regularExpression) != nil)
            if index > 0 { output += isItem && previousIsItem ? "\n" : "\n\n" }
            output += block
        }
        return output + "\n"
    }

    private static func isAllBold(_ text: NSAttributedString) -> Bool {
        var all = true
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let blank = (text.string as NSString).substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
            if !blank, let font = value as? NSFont, !NSFontManager.shared.traits(of: font).contains(.boldFontMask) { all = false }
        }
        return all
    }

    /// One line with **bold**, *italic*, `code` and [links](…).
    static func inline(_ text: NSAttributedString) -> String {
        var output = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = (text.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: " ")
            guard !piece.isEmpty else { return }
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let code = font?.isFixedPitch ?? false
            if !code { piece = WordDocument.markdownText(piece) }
            let core = piece.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { output += piece; return }
            let leading = String(piece.prefix { $0 == " " }), trailing = String(piece.reversed().prefix { $0 == " " })
            var marked = core
            if code { marked = "`\(core)`" } else {
                if traits.contains(.boldFontMask) { marked = "**\(marked)**" }
                if traits.contains(.italicFontMask) { marked = "*\(marked)*" }
            }
            if let link = attributes[.link] as? URL ?? (attributes[.link] as? String).flatMap(URL.init(string:)), let target = Markdown.safeLink(link) {
                marked = "[\(marked)](\(target))"
            }
            output += leading + marked + trailing
        }
        return output.trimmingCharacters(in: .whitespaces)
    }
}
