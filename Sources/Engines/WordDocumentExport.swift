import Foundation

extension WordDocument.Block {
    var plainText: String {
        switch self {
        case .heading(_, let text, _), .paragraph(let text, _, _): return text
        case .list(_, let items, _): return items.joined(separator: "\n")
        case .table(let rows, _, let cells):
            return (0..<rows).map { row in cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        case .picture, .columns, .columnBreak: return ""
        }
    }

    var isPicture: Bool { if case .picture = self { return true } else { return false } }
}

/// The structure found in a PDF (`PDFToWord`) in other formats than Word: Markdown, HTML (for e-books) and tables.
extension WordDocument {
    var plainText: String { blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n") }

    // MARK: Markdown

    /// Headings (#), paragraphs with **bold**, *italic* and ==highlighted== text, lists, tables (pipe tables, the first row as
    /// header). A Markdown file cannot hold pictures: with `pictureFolder` they are links into that folder (next to the file,
    /// see `writeMarkdown`), without it they are left out. Columns do not exist in Markdown.
    func markdown(pictureFolder: String? = nil) -> String {
        var parts: [String] = []
        var pictureNumber = 0
        for block in blocks {
            switch block {
            case .heading(let level, let text, let emphasis):
                parts.append(String(repeating: "#", count: min(6, max(1, level))) + " " + Self.markdownInline(text, emphasis).replacingOccurrences(of: "\n", with: " "))
            case .paragraph(let text, _, let emphasis):
                // A line break inside a paragraph (an address) is a backslash at the line's end.
                parts.append(Self.markdownStart(Self.markdownInline(text, emphasis)).replacingOccurrences(of: "\n", with: "\\\n"))
            case .list(let ordered, let items, let emphasis):
                parts.append(items.enumerated().map { index, item in
                    (ordered ? "\(index + 1). " : "- ") + Self.markdownInline(item, emphasis.indices.contains(index) ? emphasis[index] : []).replacingOccurrences(of: "\n", with: " ")
                }.joined(separator: "\n"))
            case .table(let rows, let columns, let cells):
                let grid = Self.grid(rows: rows, columns: columns, cells: cells)
                guard let header = grid.first else { continue }
                func row(_ values: [String]) -> String {
                    "| " + values.map { Self.markdownText($0).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
                }
                parts.append(([row(header), "|" + String(repeating: " --- |", count: header.count)] + grid.dropFirst().map(row)).joined(separator: "\n"))
            case .picture(let picture):
                pictureNumber += 1
                if let pictureFolder {
                    let path = Self.linkPath(pictureFolder) + "/" + Self.linkPath(Self.pictureFileName(pictureNumber, picture))
                    parts.append("![\(tr("Image", "Bild")) \(pictureNumber)](\(path))")
                }
            case .columns, .columnBreak:
                continue
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Writes the Markdown file; its pictures go in a folder "Name images" in `picturesIn`, and the file links to them. `final` is
    /// where the file will end up: the folder's name must be free there. No pictures, no folder. The folder has no brackets in
    /// its name, and only what a link cannot hold is encoded: some viewers stumble over more.
    func writeMarkdown(to destination: URL, final: URL, picturesIn folder: URL) throws {
        let pictures = blocks.compactMap { block -> Picture? in if case .picture(let picture) = block { return picture } else { return nil } }
        guard !pictures.isEmpty else {
            try markdown().write(to: destination, atomically: false, encoding: .utf8)
            return
        }
        let name = ConversionMatrix.uniqueDirectory(directory: final.deletingLastPathComponent(), name: "\(final.deletingPathExtension().lastPathComponent) \(tr("images", "Bilder"))").lastPathComponent
        let target = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (index, picture) in pictures.enumerated() {
            try picture.data.write(to: target.appendingPathComponent(Self.pictureFileName(index + 1, picture)))
        }
        try markdown(pictureFolder: name).write(to: destination, atomically: false, encoding: .utf8)
    }

    static func pictureFileName(_ number: Int, _ picture: Picture) -> String { "\(tr("image", "Bild")) \(number).\(picture.isJPEG ? "jpg" : "png")" }

    /// A file name as part of a link: spaces and the characters that mean something in a link are encoded, umlauts stay.
    static func linkPath(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if " %()<>[]#?\\".unicodeScalars.contains(scalar) {
                result += String(format: "%%%02X", scalar.value)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Characters that would start Markdown formatting are written as plain characters.
    static func markdownText(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A paragraph that starts like a heading, a list item or a quote is not one.
    static func markdownStart(_ text: String) -> String {
        if let first = text.first, "#>+-".contains(first) { return "\\" + text }
        if let range = text.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            let marker = text[range]
            return String(marker.dropLast(2)) + "\\" + String(marker.suffix(2)) + String(text[range.upperBound...])
        }
        return text
    }

    static func markdownInline(_ text: String, _ emphasis: [Emphasis]) -> String {
        let characters = Array(text)
        var result = "", index = 0
        for mark in emphasis.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where mark.range.lowerBound >= index && mark.range.upperBound <= characters.count {
            result += markdownText(String(characters[index..<mark.range.lowerBound]))
            let marker = mark.bold && mark.italic ? "***" : (mark.bold ? "**" : (mark.italic ? "*" : ""))
            let pen = mark.highlight == nil ? "" : "=="
            result += pen + marker + markdownText(String(characters[mark.range])) + marker + pen
            index = mark.range.upperBound
        }
        return result + markdownText(String(characters[index...]))
    }

    /// The table as rows of cells; a cell spanning several places is written in its first one.
    static func grid(rows: Int, columns: Int, cells: [Cell]) -> [[String]] {
        var grid = [[String]](repeating: [String](repeating: "", count: max(1, columns)), count: max(1, rows))
        for cell in cells where cell.row < grid.count && cell.column < grid[0].count { grid[cell.row][cell.column] = cell.text }
        return grid
    }

    // MARK: HTML

    /// The document as an HTML page: headings, paragraphs (aligned) with <strong>, <em> and <mark>, lists, tables, pictures (as
    /// data: addresses). Columns are left out: an e-book flows on any screen.
    func html(title: String) -> String {
        var body = ""
        for block in blocks {
            switch block {
            case .heading(let level, let text, let emphasis):
                let tag = "h\(min(3, max(1, level)))"
                body += "<\(tag)>\(Self.htmlInline(text, emphasis))</\(tag)>\n"
            case .paragraph(let text, let alignment, let emphasis):
                let style = alignment == .left ? "" : " style=\"text-align: \(alignment == .both ? "justify" : alignment.rawValue)\""
                body += "<p\(style)>\(Self.htmlInline(text, emphasis))</p>\n"
            case .list(let ordered, let items, let emphasis):
                let tag = ordered ? "ol" : "ul"
                body += "<\(tag)>" + items.enumerated().map { index, item in
                    "<li>\(Self.htmlInline(item, emphasis.indices.contains(index) ? emphasis[index] : []))</li>"
                }.joined() + "</\(tag)>\n"
            case .table(let rows, _, let cells):
                body += "<table>"
                for row in 0..<rows {
                    body += "<tr>" + cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell in
                        let spans = (cell.columnSpan > 1 ? " colspan=\"\(cell.columnSpan)\"" : "") + (cell.rowSpan > 1 ? " rowspan=\"\(cell.rowSpan)\"" : "")
                        let text = EPUB.escape(cell.text).replacingOccurrences(of: "\n", with: "<br/>")
                        return "<td\(spans)>\(cell.bold ? "<strong>\(text)</strong>" : text)</td>"
                    }.joined() + "</tr>"
                }
                body += "</table>\n"
            case .picture(let picture):
                let type = picture.isJPEG ? "image/jpeg" : "image/png"
                body += "<p><img src=\"data:\(type);base64,\(picture.data.base64EncodedString())\" alt=\"\" style=\"width: \(Int(picture.size.width))pt\"/></p>\n"
            case .columns, .columnBreak:
                continue
            }
        }
        return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>\(EPUB.escape(title))</title></head><body>\n\(body)</body></html>\n"
    }

    private static func htmlColor(_ color: Highlighter.Color) -> String {
        switch color {
        case .yellow: return "#FFF176"
        case .green: return "#A5E887"
        case .pink: return "#F48FC1"
        case .blue: return "#90CAF9"
        case .orange: return "#FFC266"
        }
    }

    static func htmlInline(_ text: String, _ emphasis: [Emphasis]) -> String {
        let characters = Array(text)
        func plain(_ part: ArraySlice<Character>) -> String { EPUB.escape(String(part)).replacingOccurrences(of: "\n", with: "<br/>") }
        var result = "", index = 0
        for mark in emphasis.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) where mark.range.lowerBound >= index && mark.range.upperBound <= characters.count {
            result += plain(characters[index..<mark.range.lowerBound])
            var inner = plain(characters[mark.range])
            if mark.italic { inner = "<em>\(inner)</em>" }
            if mark.bold { inner = "<strong>\(inner)</strong>" }
            if let color = mark.highlight { inner = "<mark class=\"\(color.rawValue)\" style=\"background-color: \(Self.htmlColor(color))\">\(inner)</mark>" }
            result += inner
            index = mark.range.upperBound
        }
        return result + plain(characters[index...])
    }

    // MARK: Tables

    /// Every table of the document as a sheet ("Table 1", "Table 2", …). Numbers with a decimal comma become numbers when
    /// the table writes them that way throughout (as in CSV), amounts ("8.600 €") numbers with their number format.
    var tableSheets: [(name: String, table: Spreadsheet)] {
        blocks.compactMap { block -> Spreadsheet? in
            guard case .table(let rows, let columns, let cells) = block else { return nil }
            let sheet = Spreadsheet(rows: Self.grid(rows: rows, columns: columns, cells: cells).map { $0.map { $0.replacingOccurrences(of: "\n", with: " ") } })
            return Spreadsheet(rows: sheet.withDecimalPoint(), readsAmounts: true)
        }.enumerated().map { (tr("Table \($0.offset + 1)", "Tabelle \($0.offset + 1)"), $0.element) }
    }
}
