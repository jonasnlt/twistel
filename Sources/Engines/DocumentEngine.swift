import AppKit
import CoreText
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum TextRenderer {
    static let pageSize = PDFRenderer.a4
    static let margin: CGFloat = 54

    static func attributed(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
    }

    /// Lays the text out page by page, all in one go. One layout for the whole text: making a new one for each page took hours with a 200 MB file.
    private static func forEachPage(of text: String, _ page: (CTFrame) throws -> Void) rethrows {
        let attributed = attributed(text)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let box = CGRect(x: margin, y: margin, width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)
        let path = CGPath(rect: box, transform: nil)
        var start = 0
        repeat {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            try page(frame)
            if visible.length == 0 { break }
            start = visible.location + visible.length
        } while start < attributed.length
    }

    static func paginate(_ text: String) -> [CFRange] {
        var ranges: [CFRange] = []
        forEachPage(of: text) { ranges.append(CTFrameGetVisibleStringRange($0)) }
        return ranges
    }

    static func writePDF(_ text: String, to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw AppError.encodeFailed(url.lastPathComponent) }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw AppError.encodeFailed(url.lastPathComponent) }
        defer { context.closePDF() }
        try forEachPage(of: text) { frame in
            try Task.checkCancellation()
            JobNotes.beat()
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
    }
}

enum PDFRenderer {
    static let a4 = CGSize(width: 595, height: 842)
    static let usLetter = CGSize(width: 612, height: 792)
    /// About 10 mm.
    static let smallMargin: CGFloat = 28

    /// How images are put on PDF pages: on paper with a small margin, or on pages the shape of the image.
    enum ImagePageLayout: String, CaseIterable, Identifiable {
        case a4
        case letter
        case sameAsImage

        static let standard = ImagePageLayout.a4
        var id: String { rawValue }
        var title: String {
            switch self {
            case .a4: return tr("A4 with margin", "A4 mit Rand")
            case .letter: return tr("US Letter with margin", "US Letter mit Rand")
            case .sameAsImage: return tr("Same as image (no margin)", "Wie das Bild (ohne Rand)")
            }
        }
    }

    /// One page per image. With paper, the page turns to the image (landscape images get a landscape page) and the
    /// image is fitted inside a small margin; with `sameAsImage` the page has the image's shape and no white at all.
    static func writeImagesPDF(_ urls: [URL], layout pageLayout: ImagePageLayout, to destination: URL, progress: @escaping (Double) -> Void) throws {
        guard !urls.isEmpty else { throw AppError.invalidInput(tr("No images to place in the PDF.", "Keine Bilder für das PDF.")) }
        guard let consumer = CGDataConsumer(url: destination as CFURL) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        var mediaBox = CGRect(origin: .zero, size: a4)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        for (index, url) in urls.enumerated() {
            let image = try pdfImage(for: url)
            var placement = layout(imageSize: CGSize(width: image.width, height: image.height), pageLayout: pageLayout)
            let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &placement.page, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.interpolationQuality = .high
            context.draw(image, in: placement.image)
            context.endPDFPage()
            progress(Double(index + 1) / Double(urls.count))
        }
        context.closePDF()
    }

    static func layout(imageSize: CGSize, pageLayout: ImagePageLayout) -> (page: CGRect, image: CGRect) {
        switch pageLayout {
        case .a4: return layout(imageSize: imageSize, paper: a4, margin: smallMargin)
        case .letter: return layout(imageSize: imageSize, paper: usLetter, margin: smallMargin)
        case .sameAsImage:
            // The image's shape at a normal size: the long edge as long as A4's, instead of one point per pixel.
            let long = max(a4.width, a4.height)
            guard imageSize.width > 0, imageSize.height > 0 else { return (CGRect(origin: .zero, size: a4), CGRect(origin: .zero, size: a4)) }
            let scale = long / max(imageSize.width, imageSize.height)
            let page = CGRect(x: 0, y: 0, width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
            return (page, page)
        }
    }

    /// The page (paper turned to the image's orientation; square images stay portrait) and the image's place on it.
    static func layout(imageSize: CGSize, paper: CGSize, margin: CGFloat) -> (page: CGRect, image: CGRect) {
        let short = min(paper.width, paper.height), long = max(paper.width, paper.height)
        let landscape = imageSize.width > imageSize.height
        let page = CGRect(x: 0, y: 0, width: landscape ? long : short, height: landscape ? short : long)
        let available = page.insetBy(dx: margin, dy: margin)
        guard imageSize.width > 0, imageSize.height > 0 else { return (page, available) }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let drawn = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return (page, CGRect(x: available.midX - drawn.width / 2, y: available.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
    }

    /// How an image goes into a PDF or Word file. A decoded image would be stored uncompressed-lossless (13 MB of photos
    /// became a 99 MB PDF), so: JPEG files are passed through untouched, other lossy photo formats (HEIC, WebP, AVIF) and
    /// rotated JPEGs become one high-quality JPEG, and lossless formats (PNG, screenshots) stay lossless.
    enum EmbeddedImage {
        case original(URL, isJPEG: Bool)
        case jpeg(Data)
        case lossless(CGImage)
    }

    static func embeddedImage(for url: URL) throws -> EmbeddedImage {
        guard FileFormat.detect(url) != .svg, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .lossless(try ImageIOBridge.load(url)) }
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if orientation == 1, type == UTType.jpeg.identifier { return .original(url, isJPEG: true) }
        if orientation == 1, type == UTType.png.identifier { return .original(url, isJPEG: false) }
        let decoded = try ImageIOBridge.load(url)
        if [UTType.png, .tiff, .bmp, .gif].map(\.identifier).contains(type) { return .lossless(decoded) }
        let opaque = decoded.alphaInfo == .none || decoded.alphaInfo == .noneSkipLast || decoded.alphaInfo == .noneSkipFirst
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return .lossless(decoded) }
        CGImageDestinationAddImage(destination, opaque ? decoded : ImageIOBridge.flatten(decoded, background: .white),
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? .jpeg(data as Data) : .lossless(decoded)
    }

    /// The image to draw into a PDF; a JPEG-backed image makes Core Graphics store the JPEG data as it is.
    static func pdfImage(for url: URL) throws -> CGImage {
        switch try embeddedImage(for: url) {
        case let .original(file, isJPEG: true):
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AppError.unreadable(file)
            }
            return image
        case let .original(file, isJPEG: false):
            // An image read straight from a PNG file would be stored as JPEG by Core Graphics; decoded, it stays lossless.
            return try ImageIOBridge.load(file)
        case let .jpeg(data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AppError.unreadable(url)
            }
            return image
        case let .lossless(image):
            return image
        }
    }

    /// A file to put into a Word document: the original JPEG or PNG, or a JPEG / PNG written into `folder`.
    static func embeddableFile(for url: URL, in folder: URL) throws -> URL {
        switch try embeddedImage(for: url) {
        case let .original(file, _):
            return file
        case let .jpeg(data):
            let file = folder.appendingPathComponent("image.jpg")
            try data.write(to: file)
            return file
        case let .lossless(image):
            let file = folder.appendingPathComponent("image.png")
            try ImageIOBridge.write(image, to: file, format: .png)
            return file
        }
    }

    /// More pixels than this are not drawn: a page of 5 × 4 metres at 300 dpi would take 13 GB of memory, on a Mac with 16.
    static let largestPicture: CGFloat = 250_000_000

    /// Nor more than this on one side: a page of 10^76 × 1 points (a damaged or made-up file) still has a small area.
    static let largestPictureSide: CGFloat = 50_000

    static func render(page: PDFPage, dpi: CGFloat = 300) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let area = max(bounds.width * bounds.height, 1)
        let scale = min(dpi / 72, (largestPicture / area).squareRoot(), largestPictureSide / max(bounds.width, bounds.height))
        let rotation = page.rotation
        let rotated = rotation % 180 != 0
        let side = 0...Int(largestPictureSide)
        let width = SafeNumber.int(((rotated ? bounds.height : bounds.width) * scale).rounded(), in: side)
        let height = SafeNumber.int(((rotated ? bounds.width : bounds.height) * scale).rounded(), in: side)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return context.makeImage()
    }

    static func thumbnail(page: PDFPage, maxSize: CGFloat) -> NSImage {
        page.thumbnail(of: CGSize(width: maxSize, height: maxSize), for: .mediaBox)
    }
}

struct DocumentEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        switch (from, to) {
        case (.pdf, .docx), (.pdf, .jpg), (.pdf, .png), (.pdf, .txt), (.pdf, .pptx), (.pdf, .md), (.pdf, .epub), (.pdf, .xlsx): return true
        case (.txt, .pdf), (.txt, .jpg), (.txt, .png), (.txt, .srt), (.txt, .vtt): return true
        default: return false
        }
    }

    func convert(_ request: ConversionRequest) async throws {
        switch request.sourceFormat {
        case .pdf: try await convertPDF(request)
        case .txt: try await convertText(request)
        default: throw AppError.unsupportedConversion(request.sourceFormat, request.target)
        }
    }

    private func convertPDF(_ request: ConversionRequest) async throws {
        guard let document = PDFDocument(url: request.source) else { throw AppError.unreadable(request.source) }
        let pageCount = document.pageCount
        switch request.target {
        case .txt:
            // Pages without text (a scan) are read like in Recognize text; a PDF with no text at all gives a message, not an empty file.
            try await RecognitionCheck.shared.ensureWorking()
            try await TextRecognizer.process(pdf: request.source, searchablePDF: nil, text: request.destination, enoughText: 1) { request.progress($0.fraction) }
        case .jpg, .png:
            try Self.writePageImages(document, baseName: ConversionMatrix.strippedBaseName(request.source.lastPathComponent), format: request.target,
                                     to: request.destination, progress: request.progress)
        case .docx:
            // Flowing text with headings, lists, tables and pictures; scanned pages are recognized (see PDFToWord).
            try await PDFToWord.convert(request.source, to: request.destination, progress: request.progress)
        case .md, .epub, .xlsx:
            // The same structure as for Word: headings, lists, tables (scans recognized).
            let structure = try await PDFToWord.analyze(request.source, progress: { request.progress($0 * 0.9) })
            let title = ConversionMatrix.strippedBaseName(request.source.lastPathComponent)
            switch request.target {
            case .md:
                try structure.writeMarkdown(to: request.destination, final: request.finalDestination ?? request.destination,
                                            picturesIn: request.besideResult ?? request.destination.deletingLastPathComponent())
            case .epub:
                try await EPUB.write(try EPUB.book(html: Data(structure.html(title: title).utf8), base: nil, title: title), to: request.destination)
            default:
                let sheets = structure.tableSheets
                guard !sheets.isEmpty else { throw AppError.invalidInput(tr("No tables were found in \(request.source.lastPathComponent).", "In \(request.source.lastPathComponent) wurden keine Tabellen gefunden.")) }
                try await Spreadsheet.writeXLSX(sheets, to: request.destination)
            }
        case .pptx:
            // One slide per page, the page as a picture (JPEG at 200 dpi: sharp on a projector, small enough to send).
            var slides: [SlideDeck.Slide] = []
            for index in 0..<pageCount {
                try Task.checkCancellation()
                // As for pictures: without this, 400 pages took 6 GB of memory.
                autoreleasepool {
                    guard let page = document.page(at: index), let image = PDFRenderer.render(page: page, dpi: 200),
                          let jpeg = SocialMedia.jpeg(image, quality: 0.88) else { return }
                    slides.append(SlideDeck.Slide(picture: jpeg, isJPEG: true, size: PDFToWord.pageSize(page)))
                }
                request.progress(Double(index + 1) / Double(pageCount) * 0.9)
            }
            try await SlideDeck.write(slides, to: request.destination)
        default:
            throw AppError.unsupportedConversion(.pdf, request.target)
        }
        request.progress(1)
    }

    /// Each page as a picture at 300 dpi: one page as one file, several as a folder of pictures (the conversion names it
    /// without an image ending, see `Engines.convert`).
    static func writePageImages(_ document: PDFDocument, baseName: String, format: FileFormat, to destination: URL, progress: (Double) -> Void) throws {
        let pageCount = document.pageCount
        if pageCount == 1, let page = document.page(at: 0) {
            guard let image = PDFRenderer.render(page: page) else { throw AppError.encodeFailed(destination.lastPathComponent) }
            try ImageIOBridge.write(image, to: destination, format: format, quality: 0.92)
            return
        }
        let folder = destination.deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<pageCount {
            try Task.checkCancellation()
            // Each page's picture goes right away. Without this a 400-page PDF took 13.5 GB of memory.
            try autoreleasepool {
                guard let page = document.page(at: index), let image = PDFRenderer.render(page: page) else { return }
                let pageURL = folder.appendingPathComponent("\(baseName) - page \(index + 1).\(format.fileExtension)")
                try ImageIOBridge.write(image, to: pageURL, format: format, quality: 0.92)
            }
            progress(Double(index + 1) / Double(pageCount))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: folder, to: destination)
    }

    private func convertText(_ request: ConversionRequest) async throws {
        let text = try TextFile.read(request.source)
        switch request.target {
        case .pdf:
            try TextRenderer.writePDF(text, to: request.destination)
        case .jpg, .png:
            // One picture per page, as with every other document (a folder when there are several).
            let pdf = request.destination.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: pdf) }
            try TextRenderer.writePDF(text, to: pdf)
            guard let document = PDFDocument(url: pdf) else { throw AppError.encodeFailed(request.destination.lastPathComponent) }
            try Self.writePageImages(document, baseName: ConversionMatrix.strippedBaseName(request.source.lastPathComponent), format: request.target,
                                     to: request.destination, progress: request.progress)
        case .srt, .vtt:
            let cues = SubtitleParser.parse(text, hint: .txt)
            try SubtitleParser.serialize(cues, as: request.target).write(to: request.destination, atomically: true, encoding: .utf8)
        default:
            throw AppError.unsupportedConversion(.txt, request.target)
        }
        request.progress(1)
    }
}

enum TextFile {
    static func read(_ url: URL) throws -> String {
        guard let text = decode(try Data(contentsOf: url)) else { throw AppError.unreadable(url) }
        return text
    }

    /// Text in an unknown encoding: UTF-8 (with or without byte order mark), UTF-16 with byte order mark, else one byte
    /// per character from Windows (Excel on Windows, Windows-1252) or an old Mac (MacRoman), whichever reads as more
    /// plausible Western European text. The byte order mark is not part of the text.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16).map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let readings = [String.Encoding.windowsCP1252, .macOSRoman].compactMap { String(data: data, encoding: $0) }
        return readings.max { plausibility($0) < plausibility($1) } ?? String(data: data, encoding: .isoLatin1)
    }

    /// How much a text looks like Western European writing: common accented letters count most, other Latin letters
    /// and typographic marks a little, other symbols (what the wrong code page makes of "ä", e.g. "‰" or "ˆ") against.
    static func plausibility(_ text: String) -> Int {
        let common = Set("äöüÄÖÜßéèêëàâáçîïíôóòûúùñÉÈÀÇœŒæÆøØåÅ".unicodeScalars)
        let marks = Set("€„“”‚‘’–—…°§«»·£¥©®".unicodeScalars)
        var score = 0
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            if common.contains(scalar) { score += 3 }
            else if marks.contains(scalar) || (scalar.value < 0x250 && CharacterSet.letters.contains(scalar)) { score += 1 }
            else { score -= 3 }
        }
        return score
    }
}
