import Foundation
import ImageIO
import UniformTypeIdentifiers

/// E-books (EPUB 3, with the older table of contents for EPUB 2 readers), written and read with the app's own code.
/// Written from an HTML page: its body becomes the book's text, its headings the table of contents, its pictures files of
/// the book. Read as one HTML page in reading order, from which the other formats are made.
enum EPUB {
    struct Picture: Equatable {
        var name: String
        var data: Data
        var mediaType: String
    }

    /// A book's text as XHTML (the contents of `<body>`), with pictures referenced as "images/<name>".
    struct Book: Equatable {
        var title: String
        var body: String
        var pictures: [Picture] = []
        var style = ""

        /// One HTML page; pictures as data: addresses so the page stands alone.
        func html() -> String {
            var page = body
            for picture in pictures {
                page = page.replacingOccurrences(of: "src=\"images/\(picture.name)\"",
                                                 with: "src=\"data:\(picture.mediaType);base64,\(picture.data.base64EncodedString())\"")
            }
            return "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>\(EPUB.escape(title))</title><style>\(EPUB.defaultStyle)</style></head>"
                + "<body>\(page)</body></html>\n"
        }
    }

    // MARK: Writing

    static let defaultStyle = """
    body { font-family: serif; line-height: 1.45; margin: 0 4%; }
    h1, h2, h3 { font-family: sans-serif; line-height: 1.2; }
    table { border-collapse: collapse; margin: 0.8em 0; }
    td, th { border: 1px solid #888; padding: 0.2em 0.5em; vertical-align: top; }
    img { max-width: 100%; height: auto; }
    """

    /// The book of an HTML page. `base` is the folder relative picture addresses start from; pictures on the internet are
    /// left out (nothing is downloaded).
    /// Apple's HTML reader goes down one level of its own stack for each level of the page, and thousands of nested <div> end the app.
    static let deepestNesting = 256

    /// Tags that close themselves, or that HTML lets one leave open.
    private static let notNesting: Set<String> = ["br", "hr", "img", "input", "meta", "link", "col", "area", "base", "embed", "param", "source", "track", "wbr",
                                                  "p", "li", "td", "th", "tr", "dt", "dd", "option", "thead", "tbody", "tfoot"]

    /// How deep the tags of a page go, roughly: enough to tell a page from an attack.
    static func nesting(of html: String) -> Int {
        var depth = 0, deepest = 0
        let bytes = Array(html.utf8)
        var index = 0
        let isName: (UInt8) -> Bool = { ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57) }
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<"), index + 1 < bytes.count else {
                index += 1
                continue
            }
            let closing = bytes[index + 1] == UInt8(ascii: "/")
            var end = index + (closing ? 2 : 1)
            let start = end
            while end < bytes.count, isName(bytes[end]) { end += 1 }
            let name = String(decoding: bytes[start..<end], as: UTF8.self).lowercased()
            index = end
            guard !name.isEmpty, !notNesting.contains(name) else { continue }
            if closing {
                depth = max(0, depth - 1)
                continue
            }
            var close = end
            while close < bytes.count, bytes[close] != UInt8(ascii: ">") { close += 1 }
            // On from the end of this tag: searching each "<a" to the end of the page made a long page take minutes.
            index = close
            if close > 0, close < bytes.count, bytes[close - 1] == UInt8(ascii: "/") { continue }
            depth += 1
            deepest = max(deepest, depth)
        }
        return deepest
    }

    static func book(html: Data, base: URL?, title fallback: String) throws -> Book {
        // Read as text first: given bytes, the HTML reader took UTF-8 for Latin-1 ("HÃ¶hepunkte").
        guard html.count <= largestPage else { throw tooLarge(fallback) }
        let source = TextFile.decode(html) ?? ""
        guard nesting(of: source) <= deepestNesting else { throw AppError.invalidInput(tr("This page is nested too deeply to be read.", "Diese Seite ist zu tief verschachtelt, um sie zu lesen.")) }
        let document = try XMLDocument(xmlString: source, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let title = (try document.nodes(forXPath: "//*[local-name()='title']").first?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let style = safeCSS(try document.nodes(forXPath: "//*[local-name()='style']").compactMap(\.stringValue).joined(separator: "\n"))
        guard let body = try document.nodes(forXPath: "//*[local-name()='body']").first else { throw AppError.invalidInput(tr("The page has no text.", "Die Seite enthält keinen Text.")) }
        var serializer = Serializer(resolve: { source in
            if source.hasPrefix("data:") { return dataPicture(source) }
            // Only pictures beside the page. A page from somewhere could otherwise ask for any file of this Mac by its path.
            guard let base, !source.contains("://"), !source.hasPrefix("/"), let url = URL(string: source, relativeTo: base), StagingArea.isInside(url, base),
                  let data = try? Data(contentsOf: url), CGImageSourceCreateWithData(data as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true else { return nil }
            return (data, mediaType(url.pathExtension))
        })
        let text = (body.children ?? []).map { serializer.xhtml($0) }.joined()
        return Book(title: title.isEmpty ? fallback : title, body: text, pictures: serializer.pictures, style: style)
    }

    /// The most a page (or a chapter of a book) may have: Apple's HTML reader cannot be stopped, and a page of 32 MB is a whole
    /// library already.
    static let largestPage = 32_000_000

    static func tooLarge(_ name: String) -> AppError {
        .invalidInput(tr("\(name) is too large to be read as a page (at most 32 MB of text per page or chapter).",
                         "\(name) ist zu groß, um als Seite gelesen zu werden (höchstens 32 MB Text je Seite oder Kapitel)."))
    }

    /// Style rules from a stranger's page, without anything that could load or run something: an e-book reader would otherwise fetch
    /// an address from the internet when the book is opened. Escapes are taken out first ("u\\rl(" is "url(" to a reader), then every
    /// declaration that names an address, a picture or a font source goes whole, and so do @import, @font-face and @namespace.
    static func safeCSS(_ css: String) -> String {
        var clean = css.replacingOccurrences(of: #"(?s)/\*.*?(\*/|$)"#, with: " ", options: .regularExpression)
        // A backslash and what it stands for: never put back, so no escape can spell a word the filter below looks for.
        clean = clean.replacingOccurrences(of: #"\\([0-9a-fA-F]{1,6}\s?|.?)"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?i)@font-face\s*\{[^}]*\}?"#, with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: #"(?i)@(import|namespace)[^;{}]*;?"#, with: "", options: .regularExpression)
        let loads = #"url|image|cross-fade|element\s*\(|expression|binding|behaviou?r|javascript|src\s*:|//|data:|@import"#
        clean = clean.replacingOccurrences(of: #"(?i)[^;{}]*(\#(loads))[^;{}]*"#, with: "", options: .regularExpression)
        return clean.replacingOccurrences(of: "<", with: "")
    }

    /// A link target in the book: a place in it, a relative address (another chapter, made a place by the serializer), or a web or
    /// mail address. Never "javascript:", "file:" or "data:".
    static func safeHref(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let colon = trimmed.firstIndex(of: ":") else { return true }
        // A colon after a slash, "?" or "#" is part of a relative address, not a scheme.
        if let other = trimmed.firstIndex(where: { "/?#".contains($0) }), other < colon { return true }
        return ["http", "https", "mailto"].contains(String(trimmed[..<colon]))
    }

    /// Writes the book. Its headings (h1 to h3) get anchors and make the table of contents.
    static func write(_ book: Book, to destination: URL) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("twistel-epub-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        for folder in ["META-INF", "OEBPS/images"] { try fm.createDirectory(at: staging.appendingPathComponent(folder), withIntermediateDirectories: true) }
        let (body, headings) = anchoringHeadings(book.body)
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        // The language of the Mac (the app itself speaks English, so not its own).
        let language = Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier } ?? "de"
        let title = escape(book.title)
        let modified = ISO8601DateFormatter().string(from: Date()).prefix(19) + "Z"
        let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        func page(_ content: String) -> String {
            xmlHeader + "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"\(language)\" xml:lang=\"\(language)\">"
                + "<head><meta charset=\"UTF-8\"/><title>\(title)</title><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head><body>\(content)</body></html>\n"
        }
        let entries = headings.isEmpty ? [(1, book.title, "")] : headings
        let nav = "<nav epub:type=\"toc\" id=\"toc\"><h1>\(title)</h1><ol>"
            + entries.map { "<li><a href=\"text.xhtml\($0.2.isEmpty ? "" : "#\($0.2)")\">\(escape($0.1))</a></li>" }.joined() + "</ol></nav>"
        let ncx = xmlHeader + "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\"><head><meta name=\"dtb:uid\" content=\"\(identifier)\"/></head>"
            + "<docTitle><text>\(title)</text></docTitle><navMap>"
            + entries.enumerated().map { index, entry in
                "<navPoint id=\"p\(index + 1)\" playOrder=\"\(index + 1)\"><navLabel><text>\(escape(entry.1))</text></navLabel>"
                    + "<content src=\"text.xhtml\(entry.2.isEmpty ? "" : "#\(entry.2)")\"/></navPoint>"
            }.joined() + "</navMap></ncx>\n"
        let manifest = ["<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
                        "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
                        "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
                        "<item id=\"text\" href=\"text.xhtml\" media-type=\"application/xhtml+xml\"/>"]
            + book.pictures.enumerated().map { "<item id=\"image\($0.offset + 1)\" href=\"images/\($0.element.name)\" media-type=\"\($0.element.mediaType)\"/>" }
        let opf = xmlHeader + "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\" xml:lang=\"\(language)\">"
            + "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">\(identifier)</dc:identifier>"
            + "<dc:title>\(title)</dc:title><dc:language>\(language)</dc:language><meta property=\"dcterms:modified\">\(modified)</meta></metadata>"
            + "<manifest>\(manifest.joined())</manifest><spine toc=\"ncx\"><itemref idref=\"text\"/></spine></package>\n"
        let container = xmlHeader + "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles>"
            + "<rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>\n"
        let files: [(String, String)] = [
            ("mimetype", "application/epub+zip"), ("META-INF/container.xml", container), ("OEBPS/content.opf", opf),
            ("OEBPS/nav.xhtml", page(nav)), ("OEBPS/toc.ncx", ncx), ("OEBPS/style.css", defaultStyle + "\n" + book.style), ("OEBPS/text.xhtml", page(body)),
        ]
        for (name, content) in files { try content.write(to: staging.appendingPathComponent(name), atomically: false, encoding: .utf8) }
        for picture in book.pictures { try picture.data.write(to: staging.appendingPathComponent("OEBPS/images/\(picture.name)")) }
        // The "mimetype" entry comes first and uncompressed, so readers can tell the file type from its first bytes.
        try? fm.removeItem(at: destination)
        let first = try await Shell.run("/usr/bin/zip", ["-X", "-0", "-q", destination.path, "mimetype"], currentDirectory: staging)
        guard first.succeeded else { throw AppError.toolFailed("zip", first.stderr) }
        let rest = try await Shell.run("/usr/bin/zip", ["-X", "-r", "-q", destination.path, "META-INF", "OEBPS"], currentDirectory: staging)
        guard rest.succeeded else { throw AppError.toolFailed("zip", rest.stderr) }
    }

    /// Gives every heading (h1 to h3) an anchor; returns the text and the headings (level, text, anchor).
    static func anchoringHeadings(_ body: String) -> (String, [(Int, String, String)]) {
        var headings: [(Int, String, String)] = []
        var result = ""
        var rest = Substring(body)
        while let range = rest.range(of: #"<h([1-3])(\s[^>]*)?>"#, options: .regularExpression) {
            result += rest[..<range.lowerBound]
            let tag = String(rest[range])
            let level = Int(String(tag[tag.index(tag.startIndex, offsetBy: 2)])) ?? 1
            guard let close = rest[range.upperBound...].range(of: "</h\(level)>") else { result += tag; rest = rest[range.upperBound...]; continue }
            let inner = String(rest[range.upperBound..<close.lowerBound])
            let text = inner.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let anchor = "h\(headings.count + 1)"
            result += tag.contains(" id=") ? tag : "<h\(level) id=\"\(anchor)\"" + tag.dropFirst(3)
            let id = tag.range(of: #"id="([^"]*)""#, options: .regularExpression).map { String(tag[$0].dropFirst(4).dropLast()) } ?? anchor
            if !text.isEmpty { headings.append((level, text, id)) }
            result += inner + "</h\(level)>"
            rest = rest[close.upperBound...]
        }
        return (result + rest, headings)
    }

    // MARK: Reading

    /// The book's text in reading order (the spine), its title and its pictures.
    /// A document may ask for "the file /etc/hosts" as part of its text (an external entity). Apple's reader would do it, unless told not to.
    static let safeXML: XMLNode.Options = [.nodeLoadExternalEntitiesNever]

    static func read(_ url: URL) async throws -> Book {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("twistel-epub-read-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        try await ZipTool.unzip(url, into: folder)
        let container = try XMLDocument(data: try Data(contentsOf: folder.appendingPathComponent("META-INF/container.xml")), options: EPUB.safeXML)
        guard let rootPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@*[local-name()='full-path']").first?.stringValue else {
            throw AppError.unreadable(url)
        }
        let opfURL = folder.appendingPathComponent(rootPath)
        // An e-book only ever reads its own files: its table of contents could name "../../../../etc/hosts" or a link to it, and that would end up in the result.
        guard StagingArea.isInside(opfURL, folder) else { throw AppError.unreadable(url) }
        let opf = try XMLDocument(data: try Data(contentsOf: opfURL), options: EPUB.safeXML)
        var total = 0
        var hrefs: [String: String] = [:]
        for item in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let element = item as? XMLElement, let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            hrefs[id] = href.removingPercentEncoding ?? href
        }
        let title = try opf.nodes(forXPath: "//*[local-name()='title']").first?.stringValue ?? url.deletingPathExtension().lastPathComponent
        var serializerPictures: [Picture] = []
        var body = ""
        for idref in try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@*[local-name()='idref']").compactMap(\.stringValue) {
            guard let href = hrefs[idref] else { continue }
            let chapter = opfURL.deletingLastPathComponent().appendingPathComponent(href)
            guard StagingArea.isInside(chapter, folder), let data = try? Data(contentsOf: chapter) else { continue }
            // Cancel in the card stops here, between chapters; a book of more than 200 MB of text is no book.
            try Task.checkCancellation()
            total += data.count
            guard data.count <= largestPage, total <= 200_000_000 else { throw tooLarge(url.lastPathComponent) }
            let page = TextFile.decode(data) ?? ""
            guard nesting(of: page) <= deepestNesting else { throw AppError.invalidInput(tr("\(url.lastPathComponent) is nested too deeply to be read.", "\(url.lastPathComponent) ist zu tief verschachtelt, um sie zu lesen.")) }
            let document = try (try? XMLDocument(data: data, options: EPUB.safeXML)) ?? XMLDocument(xmlString: page, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
            guard let chapterBody = try document.nodes(forXPath: "//*[local-name()='body']").first else { continue }
            var serializer = Serializer(resolve: { source in
                if source.hasPrefix("data:") { return dataPicture(source) }
                guard !source.contains("://"), let file = URL(string: source, relativeTo: chapter.deletingLastPathComponent()),
                      StagingArea.isInside(file, folder), let data = try? Data(contentsOf: file) else { return nil }
                return (data, mediaType(file.pathExtension))
            }, pictures: serializerPictures)
            body += (chapterBody.children ?? []).map { serializer.xhtml($0) }.joined()
            serializerPictures = serializer.pictures
        }
        guard !body.isEmpty else { throw AppError.invalidInput(tr("\(url.lastPathComponent) has no readable text.", "\(url.lastPathComponent) enthält keinen lesbaren Text.")) }
        return Book(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body, pictures: serializerPictures)
    }

    // MARK: XHTML

    /// Turns parsed HTML into XHTML: lower-case names without namespaces, empty elements closed, scripts, forms and
    /// event handlers left out, pictures collected as files of the book ("images/imageN.ext").
    struct Serializer {
        var resolve: (String) -> (Data, String)?
        var pictures: [Picture] = []

        private static let empty: Set<String> = ["br", "hr", "img", "col", "area", "wbr"]
        private static let dropped: Set<String> = ["script", "style", "meta", "link", "title", "head", "iframe", "object", "embed", "form",
                                                   "input", "button", "select", "textarea", "noscript", "base", "frame", "frameset", "applet",
                                                   "video", "audio", "source", "track", "portal", "template"]
        /// Attributes that load something or are of no use in a book.
        private static let droppedAttributes: Set<String> = ["src", "srcset", "background", "poster", "action", "formaction", "data", "codebase",
                                                            "lowsrc", "dynsrc", "ping", "xmlns", "manifest"]

        mutating func xhtml(_ node: XMLNode) -> String {
            switch node.kind {
            case .text:
                return EPUB.escape(node.stringValue ?? "")
            case .element:
                guard let element = node as? XMLElement, let name = (element.localName ?? element.name)?.lowercased(), !Self.dropped.contains(name) else { return "" }
                // An SVG wrapper around a picture (common for covers) becomes the picture itself.
                if name == "svg" { return (element.children ?? []).map { xhtml($0) }.joined() }
                if name == "img" || name == "image" {
                    let source = ["src", "href", "xlink:href"].lazy.compactMap { element.attribute(forName: $0)?.stringValue }.first ?? ""
                    guard let (data, type) = resolve(source), let file = pictureFile(data, type) else { return "" }
                    let alt = element.attribute(forName: "alt")?.stringValue ?? ""
                    return "<img src=\"images/\(file)\" alt=\"\(EPUB.escape(alt, attribute: true))\"/>"
                }
                var attributes = "", seen = Set<String>()
                for attribute in element.attributes ?? [] {
                    // The full name: "xml:lang" has the local name "lang", and both on one element made the XHTML invalid.
                    guard let full = attribute.name?.lowercased(), !full.contains(":"), !full.hasPrefix("on"), !Self.droppedAttributes.contains(full),
                          seen.insert(full).inserted else { continue }
                    var value = attribute.stringValue ?? ""
                    if full == "href" {
                        guard EPUB.safeHref(value) else { continue }
                        // A link to another chapter of the same book is a link inside the one page now.
                        if !value.contains("://"), let hash = value.firstIndex(of: "#") { value = String(value[hash...]) }
                    }
                    if full == "style" { value = EPUB.safeCSS(value) }
                    attributes += " \(full)=\"\(EPUB.escape(value, attribute: true))\""
                }
                if Self.empty.contains(name) { return "<\(name)\(attributes)/>" }
                return "<\(name)\(attributes)>" + (element.children ?? []).map { xhtml($0) }.joined() + "</\(name)>"
            default:
                return ""
            }
        }

        /// The picture as a file of the book; pictures browsers and readers cannot show (TIFF, HEIC) become PNG.
        private mutating func pictureFile(_ data: Data, _ type: String) -> String? {
            var data = data, type = type
            if !["image/jpeg", "image/png", "image/gif", "image/svg+xml", "image/webp"].contains(type) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                let png = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }
                (data, type) = (png as Data, "image/png")
            }
            if let same = pictures.first(where: { $0.data == data }) { return same.name }
            let ext = UTType(mimeType: type)?.preferredFilenameExtension ?? "png"
            let name = "image\(pictures.count + 1).\(ext == "jpeg" ? "jpg" : ext)"
            pictures.append(Picture(name: name, data: data, mediaType: type))
            return name
        }
    }

    static func dataPicture(_ address: String) -> (Data, String)? {
        guard let comma = address.firstIndex(of: ","), address[..<comma].hasSuffix(";base64") else { return nil }
        let type = String(address.dropFirst(5).prefix { $0 != ";" && $0 != "," })
        return Data(base64Encoded: String(address[address.index(after: comma)...]), options: .ignoreUnknownCharacters).map { ($0, type) }
    }

    static func mediaType(_ ext: String) -> String {
        UTType(filenameExtension: ext.lowercased())?.preferredMIMEType ?? "application/octet-stream"
    }

    static func escape(_ text: String, attribute: Bool = false, lineBreaks: Bool = true) -> String {
        // Control characters other than tab and line breaks are not allowed in XML (Word refuses the whole file); Word also wants no line breaks in its text.
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || (lineBreaks && ($0 == "\n" || $0 == "\r")) }))
        let escaped = clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return attribute ? escaped.replacingOccurrences(of: "\"", with: "&quot;") : escaped
    }
}
