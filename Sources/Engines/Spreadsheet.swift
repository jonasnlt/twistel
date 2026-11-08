import Foundation

/// A table of text cells, and the app's own CSV, TSV and XLSX reading and writing (first sheet only). Numbers are written
/// to XLSX as numbers so that Excel and Numbers can calculate with them; everything else as text.
struct Spreadsheet: Equatable {
    var rows: [[String]]
    /// Amounts like "8.600 €" become numbers with a number format (`amount`). For tables read off a page; a table the user
    /// wrote as CSV stays as it was written.
    var readsAmounts = false

    // MARK: CSV and TSV

    /// How CSV is written. Excel takes the list separator and the decimal mark from the computer's region: in German
    /// (and every region with a decimal comma) a semicolon and "3,49", elsewhere a comma and "3.49".
    struct CSVStyle: Equatable {
        var separator: Character
        var decimalComma: Bool

        static let commaAndPoint = CSVStyle(separator: ",", decimalComma: false)
        static let semicolonAndComma = CSVStyle(separator: ";", decimalComma: true)
        static var forThisMac: CSVStyle { Locale.current.decimalSeparator == "," ? .semicolonAndComma : .commaAndPoint }
    }

    /// CSV as Excel opens it with a double click: UTF-8 with a byte order mark (without it Excel reads the file as
    /// Windows text and shows "KÃ¤se"), separator and decimal mark of `style`.
    func csv(style: CSVStyle = .forThisMac) -> String {
        var table = self
        if style.decimalComma {
            table.rows = rows.map { $0.map { Self.number($0) != nil ? $0.replacingOccurrences(of: ".", with: ",") : $0 } }
        }
        return "\u{FEFF}" + table.delimited(separator: style.separator)
    }

    /// Reads a CSV or TSV file as bytes: the text encoding is found (`TextFile.decode`), then the separator, then
    /// whether numbers are written with a decimal comma ("3,49" becomes the number 3.49).
    static func readDelimited(_ data: Data, separator: Character? = nil) -> Spreadsheet {
        let text = TextFile.decode(data) ?? ""
        let separator = separator ?? guessSeparator(text)
        var table = readDelimited(text, separator: separator)
        // With commas between the fields a decimal comma cannot occur (Excel never writes it so).
        if separator != "," { table.rows = table.withDecimalPoint() }
        return table
    }

    private static let commaNumber = #"^-?([0-9]{1,3}(\.[0-9]{3})+|[0-9]+),[0-9]+$"#
    private static let groupedNumber = #"^-?[0-9]{1,3}(\.[0-9]{3})+$"#
    private static let pointNumber = #"^-?[0-9]+\.[0-9]+$"#

    /// The cells with a decimal comma turned into plain numbers, when the table uses the decimal comma throughout:
    /// some "3,49" and no "3.49" (a "1.234" alone is read as thousands). Otherwise the cells as they are.
    func withDecimalPoint() -> [[String]] {
        func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        let cells = rows.joined()
        guard cells.contains(where: { matches($0, Self.commaNumber) }),
              !cells.contains(where: { matches($0, Self.pointNumber) && !matches($0, Self.groupedNumber) }) else { return rows }
        return rows.map { row in
            row.map { cell in
                guard matches(cell, Self.commaNumber) || matches(cell, Self.groupedNumber) else { return cell }
                return cell.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            }
        }
    }

    /// Reads comma-, semicolon- or tab-separated text: quoted fields may hold separators, quotes ("") and line breaks.
    /// Without `separator` it is guessed (`guessSeparator`; German Excel writes semicolons).
    static func readDelimited(_ text: String, separator: Character? = nil) -> Spreadsheet {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let separator = separator ?? guessSeparator(text)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, afterQuote = false
        var characters = text.makeIterator()
        var pending: Character?
        while let character = pending ?? characters.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = characters.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; afterQuote = true; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty && !afterQuote:
                quoted = true
            case separator:
                row.append(field); field = ""; afterQuote = false
            case "\n", "\r\n", "\r":
                row.append(field); rows.append(row); row = []; field = ""; afterQuote = false
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return Spreadsheet(rows: rows)
    }

    /// The separator that splits the first lines into the same number of fields (outside quotes); among those the one
    /// with the most fields. "Name;Ort, Land" is two fields split by the semicolon, not by the comma.
    static func guessSeparator(_ text: String) -> Character {
        var lines: [[Character: Int]] = [], counts: [Character: Int] = [:], quoted = false
        for character in text {
            if lines.count == 10 { break }
            if character == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if character == "\n" || character == "\r\n" || character == "\r" {
                if !counts.isEmpty || lines.isEmpty { lines.append(counts) }
                counts = [:]
            } else if character == "\t" || character == ";" || character == "," {
                counts[character, default: 0] += 1
            }
        }
        if !counts.isEmpty { lines.append(counts) }
        // Same count in every line wins over more fields; on a tie tabs, then semicolons, then commas.
        var best: (separator: Character, even: Bool, fields: Int) = (",", false, 0)
        for candidate: Character in ["\t", ";", ","] {
            let perLine = lines.map { $0[candidate] ?? 0 }
            let first = perLine.first ?? 0
            let even = first > 0 && perLine.allSatisfy { $0 == first }
            if (even ? 1 : 0, first) > (best.even ? 1 : 0, best.fields) { best = (candidate, even, first) }
        }
        return best.fields > 0 ? best.separator : ","
    }

    /// RFC 4180: fields with the separator, quotes or line breaks are quoted; lines end with CRLF, as Excel expects.
    func delimited(separator: Character) -> String {
        rows.map { row in
            row.map { field in
                guard field.contains(where: { $0 == separator || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) else { return field }
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: String(separator))
        }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: XLSX

    /// A plain number ("12", "-3.5", "1e3"); "007", "1.234,56" or "12 €" stay text.
    static func number(_ text: String) -> Double? {
        guard !text.isEmpty, text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return Double(text)
    }

    func writeXLSX(to destination: URL) async throws {
        try await Self.writeXLSX([(tr("Sheet1", "Tabelle1"), self)], to: destination)
    }

    /// A number with its look, as read from a table on a page: amount and percent cells ("8.600 €", "$1,234.50", "12,5 %") and
    /// numbers with thousands marks ("8.600"). Which mark is the decimal mark: with both marks the last one; with one it depends on
    /// the writing habit, which an amount in euros or francs shows (German) and one in dollars or pounds too (English);
    /// otherwise `decimalComma`. A percent cell holds its value as a share: 12 % is 0.12, as Excel does.
    /// Everything else ("12 kg", "31.10.2026", "007", "1.2.3") is no amount.
    static func amount(_ text: String, decimalComma: Bool = CSVStyle.forThisMac.decimalComma) -> (value: Double, format: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(€|\$|£|CHF|EUR|USD|GBP)?\s*(-?[0-9][0-9.,]*)\s*(€|\$|£|CHF|EUR|USD|GBP|%)?$"#
        guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let digits = Range(match.range(at: 2), in: trimmed).map({ String(trimmed[$0]) }) else { return nil }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: trimmed).map { String(trimmed[$0]) } }
        let before = part(1), after = part(3)
        guard before == nil || after == nil else { return nil }
        let symbol = before ?? after
        var comma = decimalComma
        if let symbol { if ["€", "EUR", "CHF"].contains(symbol) { comma = true } else if ["$", "USD", "£", "GBP"].contains(symbol) { comma = false } }
        let hasPoint = digits.contains("."), hasComma = digits.contains(",")
        var plain = digits, decimals = 0
        func matches(_ regex: String) -> Bool { digits.range(of: regex, options: .regularExpression) != nil }
        if hasPoint && hasComma {
            let last = digits.lastIndex { $0 == "." || $0 == "," }!
            guard matches(digits[last] == "," ? #"^-?[0-9]{1,3}(\.[0-9]{3})+,[0-9]+$"# : #"^-?[0-9]{1,3}(,[0-9]{3})+\.[0-9]+$"#) else { return nil }
            decimals = digits.distance(from: last, to: digits.endIndex) - 1
            plain = String(digits[..<last].filter { $0.isNumber || $0 == "-" }) + "." + String(digits[digits.index(after: last)...])
        } else if hasPoint || hasComma {
            let mark: Character = hasPoint ? "." : ","
            if (mark == ",") == comma {
                // The decimal mark, once.
                guard digits.filter({ $0 == mark }).count == 1, !digits.hasSuffix(String(mark)) else { return nil }
                decimals = digits.count - digits.distance(from: digits.startIndex, to: digits.firstIndex(of: mark)!) - 1
                plain = digits.replacingOccurrences(of: String(mark), with: ".")
            } else {
                // The thousands mark, in its places.
                guard matches(mark == "." ? #"^-?[0-9]{1,3}(\.[0-9]{3})+$"# : #"^-?[0-9]{1,3}(,[0-9]{3})+$"#) else { return nil }
                plain = String(digits.filter { $0 != mark })
            }
        } else if symbol == nil {
            return nil // A plain number is written as a plain number ("2024" gets no thousands mark).
        }
        guard !plain.hasPrefix("0") || plain.hasPrefix("0.") || plain == "0", var value = Double(plain) else { return nil }
        let shape = decimals == 0 ? "" : "." + String(repeating: "0", count: decimals)
        if symbol == "%" {
            value /= 100
            return (value, "0\(shape)%")
        }
        let number = "#,##0\(shape)"
        guard let symbol else { return (value, number) }
        return (value, before != nil ? "\"\(symbol)\"\(symbol == "$" || symbol == "£" ? "" : " ")\(number)" : "\(number) \"\(symbol)\"")
    }

    /// The number formats of this table's amounts.
    var amountFormats: Set<String> {
        guard readsAmounts else { return [] }
        return Set(rows.joined().compactMap { Self.amount($0)?.format })
    }

    /// The table as one worksheet. `styles` gives the style number of each number format.
    func sheetXML(styles: [String: Int] = [:]) -> String {
        var sheet = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
            + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        func plain(_ number: Double) -> String { number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number) }
        for (r, row) in rows.enumerated() {
            sheet += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let reference = Self.columnName(c) + "\(r + 1)"
                if readsAmounts, let amount = Self.amount(value), let style = styles[amount.format] {
                    sheet += "<c r=\"\(reference)\" s=\"\(style)\"><v>\(plain(amount.value))</v></c>"
                } else if let number = Self.number(value) {
                    sheet += "<c r=\"\(reference)\"><v>\(plain(number))</v></c>"
                } else {
                    sheet += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(WordDocument.escape(value))</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        return sheet + "</sheetData></worksheet>"
    }

    /// The number formats as a styles part; a cell's style number is its format's place in `formats`, plus one (0 is normal).
    static func stylesXML(_ formats: [String]) -> String {
        let codes = formats.enumerated().map { "<numFmt numFmtId=\"\(164 + $0.offset)\" formatCode=\"\(WordDocument.escape($0.element))\"/>" }.joined()
        let styles = formats.indices.map { "<xf numFmtId=\"\(164 + $0)\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + "<numFmts count=\"\(formats.count)\">\(codes)</numFmts>"
            + "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Arial\"/></font></fonts>"
            + "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
            + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
            + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            + "<cellXfs count=\"\(formats.count + 1)\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>\(styles)</cellXfs></styleSheet>"
    }

    /// A workbook with these sheets, in this order. Sheet names are at most 31 characters (Excel's limit).
    static func writeXLSX(_ sheets: [(name: String, table: Spreadsheet)], to destination: URL) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("twistel-xlsx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        for folder in ["_rels", "xl/_rels", "xl/worksheets", "docProps"] {
            try fm.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let numbers = sheets.indices.map { $0 + 1 }
        let formats = sheets.reduce(Set<String>()) { $0.union($1.table.amountFormats) }.sorted()
        let styles = Dictionary(uniqueKeysWithValues: formats.enumerated().map { ($0.element, $0.offset + 1) })
        var parts: [(String, String)] = [
            ("[Content_Types].xml", header + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            """ + (formats.isEmpty ? "" : "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>") + numbers.map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
                + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/></Types>"),
            ("_rels/.rels", header + """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
            </Relationships>
            """),
            ("docProps/app.xml", header + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>\(AppIdentity.name)</Application></Properties>"),
            ("xl/workbook.xml", header + "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
                + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
                + zip(numbers, sheets).map { "<sheet name=\"\(WordDocument.escape(String($1.name.prefix(31))))\" sheetId=\"\($0)\" r:id=\"rId\($0)\"/>" }.joined()
                + "</sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + numbers.map { "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>" }.joined()
                + (formats.isEmpty ? "" : "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>")
                + "</Relationships>"),
        ]
        if !formats.isEmpty { parts.append(("xl/styles.xml", stylesXML(formats))) }
        parts += zip(numbers, sheets).map { ("xl/worksheets/sheet\($0).xml", $1.table.sheetXML(styles: styles)) }
        for (name, content) in parts { try content.write(to: staging.appendingPathComponent(name), atomically: false, encoding: .utf8) }
        try await ZipTool.zipOrdered(directory: staging, entries: parts.map(\.0), to: destination)
    }

    /// "A", "B", …, "Z", "AA", …
    static func columnName(_ index: Int) -> String {
        var index = index + 1, name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    /// Excel's own limits: a sheet has at most 1,048,576 rows and 16,384 columns (A to XFD).
    static let largestRow = 1_048_576
    static let largestColumn = 16_384
    /// Cells read from one sheet, empty places before a cell included: more is not a table but a trap for the memory.
    static let largestCellCount = 20_000_000

    /// The column of a cell reference ("B7" → 1); nil for anything that is no column of a real sheet ("ZZZZ1", "Ä1").
    static func columnIndex(_ reference: String) -> Int? {
        let letters = reference.prefix { $0.isLetter }.uppercased().unicodeScalars
        guard (1...3).contains(letters.count), letters.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
        let column = letters.reduce(0) { $0 * 26 + Int($1.value) - 64 }
        return column <= largestColumn ? column - 1 : nil
    }

    /// The first sheet of an .xlsx: shared and inline text, numbers, true/false. Formulas give their last result.
    static func readXLSX(_ url: URL) async throws -> Spreadsheet {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("twistel-xlsx-read-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        try await ZipTool.unzip(url, into: folder)
        var shared: [String] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent("xl/sharedStrings.xml")) {
            let document = try XMLDocument(data: data, options: EPUB.safeXML)
            shared = try document.nodes(forXPath: "//*[local-name()='si']").map { item in
                try item.nodes(forXPath: ".//*[local-name()='t']").map { $0.stringValue ?? "" }.joined()
            }
        }
        let sheetPath = try firstSheetPath(in: folder)
        // The workbook names the sheet: it must not name anything outside the file.
        guard StagingArea.isInside(folder.appendingPathComponent(sheetPath), folder) else { throw AppError.unreadable(url) }
        let document = try XMLDocument(data: try Data(contentsOf: folder.appendingPathComponent(sheetPath)), options: EPUB.safeXML)
        var rows: [[String]] = []
        var cells = 0
        // Row and cell numbers come from the file: one out of a sheet's range makes it a damaged file, not a crash or a hang.
        func tooLarge() -> AppError {
            .invalidInput(tr("\(url.lastPathComponent) is damaged or too large: its table goes beyond what a spreadsheet can hold.",
                             "\(url.lastPathComponent) ist beschädigt oder zu groß: Die Tabelle geht über das hinaus, was eine Tabellenkalkulation fassen kann."))
        }
        for row in try document.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']") {
            guard let element = row as? XMLElement else { continue }
            try Task.checkCancellation()
            let number: Int
            if let written = element.attribute(forName: "r")?.stringValue {
                guard let value = Int(written), (1...Self.largestRow).contains(value) else { throw tooLarge() }
                number = max(value, rows.count + 1)
            } else {
                number = rows.count + 1
            }
            guard number <= Self.largestRow else { throw tooLarge() }
            while rows.count < number - 1 { rows.append([]) }
            var values: [String] = []
            for cell in element.elements(forName: "c") {
                var column = values.count
                if let reference = cell.attribute(forName: "r")?.stringValue {
                    guard let index = columnIndex(reference) else { throw tooLarge() }
                    column = max(index, values.count)
                }
                guard column < Self.largestColumn else { throw tooLarge() }
                cells += column - values.count + 1
                guard cells <= Self.largestCellCount else { throw tooLarge() }
                let type = cell.attribute(forName: "t")?.stringValue
                let raw = cell.elements(forName: "v").first?.stringValue ?? ""
                let value: String
                switch type {
                case "s": value = Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                case "inlineStr": value = try cell.nodes(forXPath: ".//*[local-name()='t']").map { $0.stringValue ?? "" }.joined()
                case "b": value = raw == "1" ? "TRUE" : "FALSE"
                default: value = raw
                }
                while values.count < column { values.append("") }
                values.append(value)
            }
            rows.append(values)
        }
        return Spreadsheet(rows: rows)
    }

    private static func firstSheetPath(in folder: URL) throws -> String {
        let workbook = try XMLDocument(data: try Data(contentsOf: folder.appendingPathComponent("xl/workbook.xml")), options: EPUB.safeXML)
        let relationships = try XMLDocument(data: try Data(contentsOf: folder.appendingPathComponent("xl/_rels/workbook.xml.rels")), options: EPUB.safeXML)
        guard let id = try workbook.nodes(forXPath: "//*[local-name()='sheet']/@*[local-name()='id']").first?.stringValue, !id.contains("'"),
              let target = try relationships.nodes(forXPath: "//*[local-name()='Relationship'][@Id='\(id)']/@Target").first?.stringValue else {
            return "xl/worksheets/sheet1.xml"
        }
        return target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
    }
}
