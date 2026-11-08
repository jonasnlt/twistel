import Foundation
import ImageIO

/// A Word document as flowing text — headings, paragraphs, lists, tables and pictures, no text boxes — and how it is
/// saved as .docx. Apple's own writer (`NSAttributedString` with `.officeOpenXML`) was checked first: it
/// writes headings only as big bold text, lists as text with tabs, tables as loose paragraphs and leaves pictures out.
struct WordDocument: Equatable {
    enum Alignment: String, Equatable {
        case left, center, right, both
    }

    struct Cell: Equatable {
        var text: String
        var row: Int
        var column: Int
        var rowSpan = 1
        var columnSpan = 1
        var bold = false
    }

    /// A bold, italic and/or highlighted stretch of a heading, paragraph or list item, counted in characters of its text.
    struct Emphasis: Equatable {
        var range: Range<Int>
        var bold = false
        var italic = false
        var highlight: Highlighter.Color?
    }

    struct Picture: Equatable {
        var data: Data
        var isJPEG: Bool
        /// The size on the page in points; shrunk to the text width when saved.
        var size: CGSize
    }

    enum Block: Equatable {
        case heading(level: Int, text: String, emphasis: [Emphasis] = [])
        case paragraph(text: String, alignment: Alignment, emphasis: [Emphasis] = [])
        /// `emphasis` has one entry per item, or is empty.
        case list(ordered: Bool, items: [String], emphasis: [[Emphasis]] = [])
        case table(rows: Int, columns: Int, cells: [Cell])
        case picture(Picture)
        /// From here on the text runs in this many columns (a new section on the same page, as Word's "continuous" break).
        case columns(Int)
        /// What follows starts at the top of the next column.
        case columnBreak
    }

    var blocks: [Block]
    /// In points; A4 unless the PDF's first page says otherwise.
    var pageSize = CGSize(width: 595.3, height: 841.9)
    /// About 2.5 cm.
    var margin: CGFloat = 70.9

    var textWidth: CGFloat { pageSize.width - 2 * margin }
    /// Space between two columns: about 0.75 cm.
    static let columnGap: CGFloat = 21.25

    /// The width of one column when the text runs in `columns` columns.
    func columnWidth(_ columns: Int) -> CGFloat { (textWidth - Self.columnGap * CGFloat(columns - 1)) / CGFloat(max(1, columns)) }

    // MARK: Saving

    func write(to destination: URL) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("twistel-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        for folder in ["_rels", "word/_rels", "word/media", "docProps"] {
            try fm.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let parts = xmlParts()
        var entries: [String] = []
        for (name, content) in parts {
            try content.write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
            entries.append(name)
        }
        for (index, picture) in pictures.enumerated() {
            let name = "word/media/\(Self.mediaName(index, picture))"
            try picture.data.write(to: staging.appendingPathComponent(name))
            entries.append(name)
        }
        try await ZipTool.zipOrdered(directory: staging, entries: entries, to: destination)
    }

    private var pictures: [Picture] {
        blocks.compactMap { if case .picture(let picture) = $0 { return picture } else { return nil } }
    }

    private static func mediaName(_ index: Int, _ picture: Picture) -> String { "image\(index + 1).\(picture.isJPEG ? "jpg" : "png")" }

    /// The XML parts of the package, `[Content_Types].xml` first (Word wants it there).
    func xmlParts() -> [(String, String)] {
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        var relationships = [
            "<Relationship Id=\"rId1\" Type=\"\(Self.relType)/styles\" Target=\"styles.xml\"/>",
            "<Relationship Id=\"rId2\" Type=\"\(Self.relType)/numbering\" Target=\"numbering.xml\"/>",
            "<Relationship Id=\"rId3\" Type=\"\(Self.relType)/settings\" Target=\"settings.xml\"/>",
        ]
        for (index, picture) in pictures.enumerated() {
            relationships.append("<Relationship Id=\"rIdImage\(index + 1)\" Type=\"\(Self.relType)/image\" Target=\"media/\(Self.mediaName(index, picture))\"/>")
        }
        let (body, numbering) = bodyXML()
        let contentTypes = header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """
        let rootRels = header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(Self.relType)/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="\(Self.relType)/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """
        let documentRels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + relationships.joined() + "</Relationships>"
        let document = header + """
        <w:document xmlns:w="\(Self.w)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """
        let core = header + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title></dc:title></cp:coreProperties>
        """
        let app = header + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>\(AppIdentity.name)</Application></Properties>
        """
        let settings = header + "<w:settings xmlns:w=\"\(Self.w)\"><w:defaultTabStop w:val=\"709\"/><w:compat/></w:settings>"
        return [
            ("[Content_Types].xml", contentTypes), ("_rels/.rels", rootRels), ("docProps/core.xml", core), ("docProps/app.xml", app),
            ("word/document.xml", document), ("word/styles.xml", header + Self.styles), ("word/numbering.xml", header + numbering),
            ("word/settings.xml", settings), ("word/_rels/document.xml.rels", documentRels),
        ]
    }

    private static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A section's page and columns. Every section after the first starts on the same page ("continuous").
    private func sectionXML(columns: Int, continuous: Bool) -> String {
        let twips = { (points: CGFloat) in Int((points * 20).rounded()) }
        return "<w:sectPr>" + (continuous ? "<w:type w:val=\"continuous\"/>" : "")
            + "<w:pgSz w:w=\"\(twips(pageSize.width))\" w:h=\"\(twips(pageSize.height))\"/>"
            + "<w:pgMar w:top=\"\(twips(margin))\" w:right=\"\(twips(margin))\" w:bottom=\"\(twips(margin))\" w:left=\"\(twips(margin))\" "
            + "w:header=\"709\" w:footer=\"709\" w:gutter=\"0\"/>"
            + (columns > 1 ? "<w:cols w:num=\"\(columns)\" w:space=\"\(twips(Self.columnGap))\"/>" : "<w:cols w:space=\"709\"/>") + "</w:sectPr>"
    }

    /// The body (its sections' properties included), and the numbering part: one bullet definition, and one numbering per
    /// numbered list so each starts at 1. A section ends with an empty paragraph that carries its properties; the last
    /// section's properties close the body.
    private func bodyXML() -> (String, String) {
        var body = ""
        var numberedLists = 0
        var pictureIndex = 0
        var columns = 1, sections = 0, sectionHasContent = false
        // A column break goes at the start of the next paragraph: on a paragraph of its own, that empty paragraph would
        // stand at the top of the next column.
        var columnBreak = false
        func lead() -> String {
            defer { columnBreak = false }
            return columnBreak ? "<w:r><w:br w:type=\"column\"/></w:r>" : ""
        }
        for block in blocks {
            if case .columnBreak = block {
                columnBreak = true
                continue
            }
            if case .columns(let count) = block {
                guard count != columns else { continue }
                if sectionHasContent {
                    body += "<w:p><w:pPr>\(sectionXML(columns: columns, continuous: sections > 0))</w:pPr></w:p>"
                    sections += 1
                    sectionHasContent = false
                }
                columns = max(1, count)
                continue
            }
            sectionHasContent = true
            switch block {
            case .heading(let level, let text, let emphasis):
                body += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(min(3, max(1, level)))\"/></w:pPr>\(lead())\(Self.runs(text, emphasis: emphasis))</w:p>"
            case .paragraph(let text, let alignment, let emphasis):
                let jc = alignment == .left ? "" : "<w:jc w:val=\"\(alignment.rawValue)\"/>"
                body += "<w:p>\(jc.isEmpty ? "" : "<w:pPr>\(jc)</w:pPr>")\(lead())\(Self.runs(text, emphasis: emphasis))</w:p>"
            case .list(let ordered, let items, let emphasis):
                var numID = 1
                if ordered {
                    numberedLists += 1
                    numID = 1 + numberedLists
                }
                for (index, item) in items.enumerated() {
                    let marked = emphasis.indices.contains(index) ? emphasis[index] : []
                    body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numID)\"/></w:numPr></w:pPr>\(lead())\(Self.runs(item, emphasis: marked))</w:p>"
                }
            case .table(let rows, let tableColumns, let cells):
                // A table has no paragraph of its own to start with the break.
                if columnBreak { body += "<w:p>\(lead())</w:p>" }
                body += tableXML(rows: rows, columns: tableColumns, cells: cells, width: columnWidth(columns)) + "<w:p/>"
            case .picture(let picture):
                pictureIndex += 1
                body += pictureXML(picture, index: pictureIndex, width: columnWidth(columns), lead: lead())
            case .columns, .columnBreak:
                break
            }
        }
        body += sectionXML(columns: columns, continuous: sections > 0)
        var numbering = "<w:numbering xmlns:w=\"\(Self.w)\">"
        numbering += Self.abstractNumbering(id: 0, format: "bullet", text: "•")
        numbering += Self.abstractNumbering(id: 1, format: "decimal", text: "%1.")
        numbering += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for list in 0..<numberedLists {
            numbering += "<w:num w:numId=\"\(2 + list)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        numbering += "</w:numbering>"
        return (body, numbering)
    }

    /// The bullet is the plain "•" in the normal font (Word's own Symbol-font bullet needs a private code point).
    private static func abstractNumbering(id: Int, format: String, text: String) -> String {
        return "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"singleLevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/>"
            + "<w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/>"
            + "<w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
    }

    /// Text as runs: one per stretch of the same emphasis. A line break inside a paragraph (an address block) becomes a
    /// Word line break.
    private static func runs(_ text: String, bold: Bool = false, emphasis: [Emphasis] = []) -> String {
        guard !emphasis.isEmpty else { return run(text, bold: bold, italic: false, highlight: nil) }
        let characters = Array(text)
        var styles = [Emphasis](repeating: Emphasis(range: 0..<0, bold: bold), count: characters.count)
        for mark in emphasis {
            for index in mark.range.clamped(to: 0..<characters.count) {
                styles[index].bold = styles[index].bold || mark.bold
                styles[index].italic = styles[index].italic || mark.italic
                styles[index].highlight = mark.highlight ?? styles[index].highlight
            }
        }
        var xml = "", start = 0
        for index in 1...characters.count where index == characters.count || styles[index] != styles[start] {
            xml += run(String(characters[start..<index]), bold: styles[start].bold, italic: styles[start].italic, highlight: styles[start].highlight)
            start = index
        }
        return xml
    }

    /// The highlighter as Word's own (it has yellow, bright green, pink and turquoise and removes them with its highlighter
    /// button); it has no orange, so that is shaded instead.
    private static func highlightXML(_ color: Highlighter.Color) -> String {
        switch color {
        case .yellow: return "<w:highlight w:val=\"yellow\"/>"
        case .green: return "<w:highlight w:val=\"green\"/>"
        case .pink: return "<w:highlight w:val=\"magenta\"/>"
        case .blue: return "<w:highlight w:val=\"cyan\"/>"
        case .orange: return "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"FFC000\"/>"
        }
    }

    private static func run(_ text: String, bold: Bool, italic: Bool, highlight: Highlighter.Color?) -> String {
        let inner = (bold ? "<w:b/>" : "") + (italic ? "<w:i/>" : "") + (highlight.map(highlightXML) ?? "")
        let properties = inner.isEmpty ? "" : "<w:rPr>\(inner)</w:rPr>"
        let lines = text.components(separatedBy: "\n")
        return "<w:r>\(properties)" + lines.map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }.joined(separator: "<w:br/>") + "</w:r>"
    }

    /// A grid table. Cells spanning columns use gridSpan, cells spanning rows vMerge; a grid place without a cell stays empty.
    private func tableXML(rows: Int, columns: Int, cells: [Cell], width available: CGFloat) -> String {
        let columns = max(1, columns), rows = max(1, rows)
        let width = Int((available * 20).rounded()) / columns
        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(width * columns)\" w:type=\"dxa\"/>"
            + "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"1\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr><w:tblGrid>"
        xml += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
        for row in 0..<rows {
            xml += "<w:tr>"
            var column = 0
            while column < columns {
                if let cell = cells.first(where: { $0.row == row && $0.column == column }) {
                    let span = min(cell.columnSpan, columns - column)
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width * span)\" w:type=\"dxa\"/>" + (span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "")
                        + (cell.rowSpan > 1 ? "<w:vMerge w:val=\"restart\"/>" : "") + "</w:tcPr><w:p>\(Self.runs(cell.text, bold: cell.bold))</w:p></w:tc>"
                    column += span
                } else if let above = cells.first(where: { $0.column == column && $0.row < row && $0.row + $0.rowSpan > row }) {
                    let span = min(above.columnSpan, columns - column)
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width * span)\" w:type=\"dxa\"/>" + (span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "")
                        + "<w:vMerge/></w:tcPr><w:p/></w:tc>"
                    column += span
                } else if cells.contains(where: { $0.row == row && $0.column < column && $0.column + $0.columnSpan > column }) {
                    column += 1
                } else {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    column += 1
                }
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    private func pictureXML(_ picture: Picture, index: Int, width: CGFloat, lead: String) -> String {
        let scale = min(1, width / max(picture.size.width, 1), (pageSize.height - 2 * margin) / max(picture.size.height, 1))
        let cx = Int((picture.size.width * scale * 12_700).rounded()), cy = Int((picture.size.height * scale * 12_700).rounded())
        let name = "Picture \(index)"
        return "<w:p>\(lead)<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
            + "<wp:docPr id=\"\(index)\" name=\"\(name)\"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect=\"1\"/></wp:cNvGraphicFramePr>"
            + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
            + "<pic:nvPicPr><pic:cNvPr id=\"\(index)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
            + "<pic:blipFill><a:blip r:embed=\"rIdImage\(index)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
            + "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr>"
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    }

    /// Normal text, three heading levels (with outline levels, so Word's navigation and table of contents see them),
    /// list paragraphs and a table style with thin borders. Arial exists in Word, Pages and LibreOffice.
    private static let styles = """
    <w:styles xmlns:w="\(w)"><w:docDefaults><w:rPrDefault><w:rPr>\
    <w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="de-DE"/>\
    </w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="360" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:unhideWhenUsed/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:unhideWhenUsed/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>\
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/>\
    <w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>\
    <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/>\
    <w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/>\
    <w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/>\
    <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders>\
    <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
    <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
    <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
    </w:tblBorders></w:tblPr></w:style></w:styles>
    """

    static func escape(_ text: String) -> String {
        EPUB.escape(text, attribute: true, lineBreaks: false)
    }
}
