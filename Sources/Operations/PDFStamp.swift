import AppKit
import CoreText
import PDFKit

/// Puts a text watermark or page numbers on every page of a PDF. Each page is drawn as it is into a new PDF (its text
/// stays text, so it can still be searched and copied) and the stamp is drawn on top; links, jumps, the table of
/// contents, the document info and comments are carried over.
enum PDFStamp {
    // MARK: Watermark

    struct Watermark: Equatable {
        enum Direction: String, CaseIterable, Identifiable {
            case diagonal, horizontal
            var id: String { rawValue }
            var title: String { self == .diagonal ? tr("Diagonal", "Diagonal") : tr("Horizontal", "Waagerecht") }
        }

        enum Position: String, CaseIterable, Identifiable {
            case top, center, bottom
            var id: String { rawValue }
            var title: String {
                switch self {
                case .top: return tr("Top", "Oben")
                case .center: return tr("Center", "Mitte")
                case .bottom: return tr("Bottom", "Unten")
                }
            }
        }

        var text = tr("CONFIDENTIAL", "VERTRAULICH")
        /// Points; made smaller when the text would not fit on the page.
        var fontSize: CGFloat = 72
        /// 0 to 1.
        var opacity: CGFloat = 0.25
        var direction = Direction.diagonal
        var position = Position.center
    }

    // MARK: Page numbers

    struct PageNumbers: Equatable {
        enum Position: String, CaseIterable, Identifiable {
            case bottomCenter, bottomRight, bottomLeft, topCenter, topRight, topLeft
            var id: String { rawValue }
            var title: String {
                switch self {
                case .bottomCenter: return tr("Bottom center", "Unten Mitte")
                case .bottomRight: return tr("Bottom right", "Unten rechts")
                case .bottomLeft: return tr("Bottom left", "Unten links")
                case .topCenter: return tr("Top center", "Oben Mitte")
                case .topRight: return tr("Top right", "Oben rechts")
                case .topLeft: return tr("Top left", "Oben links")
                }
            }
            var isTop: Bool { [.topCenter, .topRight, .topLeft].contains(self) }
        }

        enum Format: String, CaseIterable, Identifiable {
            /// "1"
            case number
            /// "Page 1 of 9" or "Seite 1 von 9", in the app's language.
            case pageOfTotal
            var id: String { rawValue }
        }

        var position = Position.bottomCenter
        var format = Format.number
        /// The number on the first numbered page.
        var start = 1
        /// The first page (a cover) gets no number; the next one gets `start`.
        var skipFirstPage = false
        var fontSize: CGFloat = 10
        /// About 10 mm from the page edge.
        static let margin: CGFloat = 28

        /// The text on page `index` (0-based) of `count` pages, nil for a page without a number.
        func label(page index: Int, of count: Int, language: AppLanguage = .current) -> String? {
            let first = skipFirstPage ? 1 : 0
            guard index >= first else { return nil }
            let number = start + index - first
            let last = start + count - 1 - first
            switch format {
            case .number: return "\(number)"
            case .pageOfTotal: return language == .german ? "Seite \(number) von \(last)" : "Page \(number) of \(last)"
            }
        }
    }

    // MARK: Writing

    static func addWatermark(_ watermark: Watermark, to source: URL, destination: URL, progress: @escaping (Double) -> Void = { _ in }) throws {
        try stamp(source, to: destination, progress: progress) { context, page, _, _ in draw(watermark, in: context, page: page) }
    }

    static func addPageNumbers(_ numbers: PageNumbers, to source: URL, destination: URL, language: AppLanguage = .current,
                               progress: @escaping (Double) -> Void = { _ in }) throws {
        try stamp(source, to: destination, progress: progress) { context, page, index, count in
            guard let label = numbers.label(page: index, of: count, language: language) else { return }
            draw(label, numbers: numbers, in: context, page: page)
        }
    }

    /// The new PDF is written to a temporary file first, so a cancelled or failed run leaves nothing next to the original.
    static func stamp(_ source: URL, to destination: URL, progress: @escaping (Double) -> Void,
                      draw stampPage: (CGContext, CGRect, Int, Int) -> Void) throws {
        guard let original = PDFDocument(url: source), let pages = CGPDFDocument(source as CFURL) else { throw AppError.unreadable(source) }
        guard !original.isLocked, !pages.isEncrypted || pages.unlockWithPassword("") else {
            throw AppError.invalidInput(tr("\(source.lastPathComponent) is protected by a password. Remove it first with PDF password.", "\(source.lastPathComponent) ist mit einem Passwort geschützt. Entferne es zuerst mit \u{201E}PDF-Passwort\u{201C}."))
        }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("twistel-stamp-\(UUID().uuidString).pdf")
        let drawn = fm.temporaryDirectory.appendingPathComponent("twistel-stamp-\(UUID().uuidString)-pages.pdf")
        defer { try? fm.removeItem(at: temporary); try? fm.removeItem(at: drawn) }

        var info: [CFString: Any] = [kCGPDFContextCreator: AppIdentity.name]
        let attributes = original.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] { info[kCGPDFContextTitle] = title }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] { info[kCGPDFContextAuthor] = author }
        if let subject = attributes[PDFDocumentAttribute.subjectAttribute] { info[kCGPDFContextSubject] = subject }
        guard let context = CGContext(drawn as CFURL, mediaBox: nil, info as CFDictionary) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        let count = pages.numberOfPages
        let transforms = (0..<count).map { index -> CGAffineTransform in
            guard let page = pages.page(at: index + 1) else { return .identity }
            return page.getDrawingTransform(.cropBox, rect: shownBox(page), rotate: 0, preserveAspectRatio: true)
        }
        let links = Links(original, transforms: transforms)
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = pages.page(at: index + 1) else { continue }
            var box = shownBox(page)
            context.beginPage(mediaBox: &box)
            drawUpright(page, in: context, box: box)
            stampPage(context, box, index, count)
            links.write(page: index, in: context)
            context.endPage()
            progress(Double(index + 1) / Double(count) * 0.9)
        }
        if let outline = links.outline { CGPDFContextSetOutline(context, outline as CFDictionary) }
        context.closePDF()

        var finished = drawn
        if links.hasOtherAnnotations {
            // Comments, highlights and the like are added with PDFKit. It keeps the web links and the table of contents
            // written above, but breaks jumps to other pages; those are lost in such files.
            guard let result = PDFDocument(url: drawn) else { throw AppError.encodeFailed(destination.lastPathComponent) }
            links.copyOtherAnnotations(to: result)
            guard result.write(to: temporary) else { throw AppError.encodeFailed(destination.lastPathComponent) }
            finished = temporary
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: finished, to: destination)
        progress(1)
    }

    /// The links, jump targets and table of contents of the original, placed like its pages on the new, upright pages.
    /// Written with Quartz: PDFKit does not save a table of contents set in code and writes jumps with a broken page
    /// reference ("/Dest [/#23232 …]"); Quartz writes both correctly.
    private struct Links {
        enum Target { case web(URL), jump(String) }

        var links: [[(rect: CGRect, target: Target)]]
        /// Named places on each page that jumps and table-of-contents entries point to.
        var places: [[(name: String, point: CGPoint)]]
        var outline: [String: Any]?
        var others: [(page: Int, annotation: PDFAnnotation)] = []
        let transforms: [CGAffineTransform]
        var hasOtherAnnotations: Bool { !others.isEmpty }

        init(_ original: PDFDocument, transforms: [CGAffineTransform]) {
            self.transforms = transforms
            links = transforms.map { _ in [] }
            places = transforms.map { _ in [] }
            for index in 0..<min(original.pageCount, transforms.count) {
                guard let page = original.page(at: index) else { continue }
                for annotation in page.annotations {
                    // `type` is "Link", the subtype constant "/Link".
                    guard annotation.type == "Link" else {
                        others.append((index, annotation))
                        continue
                    }
                    let rect = annotation.bounds.applying(transforms[index]).standardized
                    if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                        links[index].append((rect, .web(url)))
                    } else if let target = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
                              let name = place(for: target, in: original) {
                        links[index].append((rect, .jump(name)))
                    }
                }
            }
            if let root = original.outlineRoot, root.numberOfChildren > 0 {
                outline = [kCGPDFOutlineChildren as String: children(of: root, in: original)]
            }
        }

        /// A named place for a destination in the original; nil when it points nowhere.
        private mutating func place(for destination: PDFDestination, in original: PDFDocument) -> String? {
            guard let page = destination.page else { return nil }
            let index = original.index(for: page)
            guard index >= 0, index < transforms.count else { return nil }
            let name = "twistel-place-\(places.joined().count + 1)"
            places[index].append((name, point(destination, page: page, index: index)))
            return name
        }

        /// The destination's point on the new page; "unspecified" (a very large number) means the top of the page.
        private func point(_ destination: PDFDestination, page: PDFPage, index: Int) -> CGPoint {
            let bounds = page.bounds(for: .cropBox)
            let x = destination.point.x > 1e6 ? bounds.minX : destination.point.x
            let y = destination.point.y > 1e6 ? bounds.maxY : destination.point.y
            return CGPoint(x: x, y: y).applying(transforms[index])
        }

        private mutating func children(of item: PDFOutline, in original: PDFDocument) -> [[String: Any]] {
            (0..<item.numberOfChildren).compactMap { index -> [String: Any]? in
                guard let child = item.child(at: index) else { return nil }
                var entry: [String: Any] = [kCGPDFOutlineTitle as String: child.label ?? ""]
                if let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination, let page = destination.page {
                    let pageIndex = original.index(for: page)
                    if pageIndex >= 0, pageIndex < transforms.count {
                        entry[kCGPDFOutlineDestination as String] = pageIndex + 1
                        entry[kCGPDFOutlineDestinationRect as String] = CGRect(origin: point(destination, page: page, index: pageIndex), size: .zero).dictionaryRepresentation
                    }
                } else if let url = (child.action as? PDFActionURL)?.url {
                    entry[kCGPDFOutlineDestination as String] = url
                }
                let grandchildren = children(of: child, in: original)
                if !grandchildren.isEmpty { entry[kCGPDFOutlineChildren as String] = grandchildren }
                return entry
            }
        }

        func write(page index: Int, in context: CGContext) {
            for place in places[index] { context.addDestination(place.name as CFString, at: place.point) }
            for link in links[index] {
                switch link.target {
                case .web(let url): context.setURL(url as CFURL, for: link.rect)
                case .jump(let name): context.setDestination(name as CFString, for: link.rect)
                }
            }
        }

        /// Comments, highlights and drawings, on pages that keep their place (not turned, crop box at 0): there their
        /// points stay valid. Each is made anew from its properties; a copy loses them when saved.
        func copyOtherAnnotations(to result: PDFDocument) {
            for (index, annotation) in others {
                guard let page = result.page(at: index), transforms[index].isIdentity, let type = annotation.type,
                      !["Widget", "Popup"].contains(type) else { continue }
                page.addAnnotation(PDFAnnotation(bounds: annotation.bounds, forType: PDFAnnotationSubtype(rawValue: "/" + type),
                                                 withProperties: annotation.annotationKeyValues))
            }
        }
    }

    /// Read in the background: a long PDF has many pages to look through.
    static func anyFormFields(_ urls: [URL]) async -> Bool {
        await Task.detached { urls.contains(where: hasFormFields) }.value
    }

    /// Form fields can't be carried over into the new pages; the tool windows say so.
    static func hasFormFields(_ url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        return (0..<document.pageCount).contains { document.page(at: $0)?.annotations.contains { $0.type == "Widget" } ?? false }
    }

    /// The page as shown: its crop box, turned when the page is turned, with the origin at 0.
    static func shownBox(_ page: CGPDFPage) -> CGRect {
        let crop = page.getBoxRect(.cropBox)
        let turned = (page.rotationAngle % 180 + 180) % 180 != 0
        return CGRect(x: 0, y: 0, width: turned ? crop.height : crop.width, height: turned ? crop.width : crop.height)
    }

    /// The visible part of the page, turned upright: the new page has no rotation of its own.
    static func drawUpright(_ page: CGPDFPage, in context: CGContext, box: CGRect) {
        context.saveGState()
        context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// A small picture of one page with the stamp, for the tool window.
    static func preview(_ url: URL, pageIndex: Int, width: CGFloat, stamp: (CGContext, CGRect, Int, Int) -> Void) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted || document.unlockWithPassword(""),
              let page = document.page(at: pageIndex + 1) else { return nil }
        let box = shownBox(page)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = width / box.width
        let side = 1...Int(PDFRenderer.largestPictureSide)
        guard let context = CGContext(data: nil, width: SafeNumber.int(width, in: side), height: SafeNumber.int(box.height * scale, in: side), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        drawUpright(page, in: context, box: box)
        stamp(context, box, pageIndex, document.numberOfPages)
        return context.makeImage()
    }

    // MARK: Drawing

    /// The watermark as letter outlines, not as text: the page's own text stays as it was for copying and searching.
    static func draw(_ watermark: Watermark, in context: CGContext, page: CGRect) {
        let text = watermark.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let angle = watermark.direction == .diagonal ? atan2(page.height, page.width) : 0
        // Room for the text: along the diagonal or across the page, with a margin.
        let room = (watermark.direction == .diagonal ? hypot(page.width, page.height) * 0.75 : page.width) - 2 * PageNumbers.margin
        var size = max(6, watermark.fontSize)
        var line = outlineLine(text, size: size)
        if line.width > room {
            size *= room / line.width
            line = outlineLine(text, size: size)
        }
        let center: CGPoint
        switch watermark.position {
        case .center: center = CGPoint(x: page.midX, y: page.midY)
        case .top: center = CGPoint(x: page.midX, y: page.maxY - page.height * 0.22)
        case .bottom: center = CGPoint(x: page.midX, y: page.minY + page.height * 0.22)
        }
        context.saveGState()
        context.setAlpha(min(1, max(0.02, watermark.opacity)))
        context.setFillColor(CGColor(gray: 0.45, alpha: 1))
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle)
        context.translateBy(x: -line.width / 2, y: -line.capHeight / 2)
        context.addPath(line.path)
        context.fillPath()
        context.restoreGState()
    }

    /// The text as one path at the origin (baseline at y = 0), its width and the font's capital height.
    static func outlineLine(_ text: String, size: CGFloat) -> (path: CGPath, width: CGFloat, capHeight: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            // A letter Helvetica lacks comes in a fallback font; each run has its own.
            let attributes = CTRunGetAttributes(run) as NSDictionary as? [String: Any] ?? [:]
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                if let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                    path.addPath(outline, transform: CGAffineTransform(translationX: position.x, y: position.y))
                }
            }
        }
        return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), CTFontGetCapHeight(font))
    }

    /// A page number as real text, so it can be found like the rest of the page.
    static func draw(_ label: String, numbers: PageNumbers, in context: CGContext, page: CGRect) {
        let font = CTFontCreateWithName("Helvetica" as CFString, numbers.fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: NSColor(white: 0.15, alpha: 1),
        ]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let margin = PageNumbers.margin
        let x: CGFloat
        switch numbers.position {
        case .bottomCenter, .topCenter: x = page.midX - width / 2
        case .bottomRight, .topRight: x = page.maxX - margin - width
        case .bottomLeft, .topLeft: x = page.minX + margin
        }
        let y = numbers.position.isTop ? page.maxY - margin - CTFontGetCapHeight(font) : page.minY + margin
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
