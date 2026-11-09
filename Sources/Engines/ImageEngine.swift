import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageIOBridge {
    static let nativeEncoders: Set<String> = {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return Set(ids)
    }()

    static func canEncodeNatively(_ format: FileFormat) -> Bool {
        guard let type = format.utType else { return false }
        return nativeEncoders.contains(type.identifier)
    }

    static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if FileFormat.detect(url) == .svg {
            return try rasterizeSVG(url, maxPixelSize: maxPixelSize)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw AppError.unreadable(url) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        DiagnosticLog.log("image load \(url.lastPathComponent) type=\((CGImageSourceGetType(source) as String?) ?? "?") \(width)x\(height) max=\(maxPixelSize.map(String.init) ?? "none")")
        var longest = max(width, height, 1)
        // A small file can say it has 100,000 × 100,000 pixels (40 GB in memory): such a picture is read smaller, and the card says so.
        let pixels = Double(width) * Double(height)
        if pixels > Double(largestPixels) {
            let fitting = max(1, Int(Double(longest) * (Double(largestPixels) / pixels).squareRoot()))
            if maxPixelSize.map({ $0 > fitting }) ?? true { noteShrunk(url, from: (width, height), longest: fitting) }
            longest = fitting
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize.map { min($0, longest) } ?? longest,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            DiagnosticLog.log("thumbnail decoded \(image.width)x\(image.height) alpha=\(image.alphaInfo.rawValue)")
            return image
        }
        DiagnosticLog.log("thumbnail failed, falling back to full decode")
        guard pixels <= Double(largestPixels) else { throw AppError.unreadable(url) }
        // Decoded as stored: the turn of the photo is applied here, as the thumbnail would have done.
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return upright(image, orientation: (properties[kCGImagePropertyOrientation] as? Int) ?? 1)
        }
        if let ns = NSImage(contentsOf: url), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        throw AppError.unreadable(url)
    }

    /// The colour space to draw a picture into without changing its colours: its own (Display P3 of an iPhone photo, Adobe RGB),
    /// sRGB only for what can't be drawn into (grey, CMYK, indexed, HDR spaces).
    static func outputSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput, !CGColorSpaceUsesExtendedRange(space) { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// The picture as it is shown: the stored pixels turned (and mirrored) by an EXIF orientation 1 to 8.
    static func upright(_ image: CGImage, orientation: Int) -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let swaps = orientation >= 5
        let width = swaps ? image.height : image.width, height = swaps ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: outputSpace(of: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        // In CoreGraphics' coordinates (origin bottom left): where the stored picture goes for each orientation.
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        default: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }

    /// The most pixels a picture is read with: 250 megapixels take 1 GB of memory, on a Mac with 16 GB.
    static let largestPixels = 250_000_000
    /// A drawing (SVG) is drawn at most this large: its size is only a number in the file, "width=12000" costs 116 bytes and 576 MB.
    static let largestDrawingPixels = 64_000_000
    static let largestDrawingSide = 16_384

    private static func noteShrunk(_ url: URL, from size: (Int, Int), longest: Int) {
        JobNotes.add(tr("\(url.lastPathComponent) says it is \(size.0) × \(size.1) pixels, more than can be worked with; it was used at \(longest) pixels on its longer side.",
                        "\(url.lastPathComponent) gibt eine Größe von \(size.0) × \(size.1) Pixeln an, mehr als sich verarbeiten lässt; es wurde mit \(longest) Pixeln an der längeren Seite verwendet."))
    }

    /// Pixel size for drawing an SVG of `size` points: at least `target` on the longer side (a small icon becomes sharp), at most
    /// `largestDrawingPixels` and `largestDrawingSide`. `shrunk` when the drawing's own size was larger than that.
    static func drawingPixels(for size: CGSize, target: CGFloat) -> (size: CGSize, shrunk: Bool) {
        var size = size
        if !(size.width.isFinite && size.height.isFinite) || size.width <= 0 || size.height <= 0 { size = CGSize(width: 1024, height: 1024) }
        var scale = max(target / max(size.width, size.height), 1)
        let limit = min((CGFloat(largestDrawingPixels) / (size.width * size.height)).squareRoot(), CGFloat(largestDrawingSide) / max(size.width, size.height))
        let shrunk = scale > limit
        scale = min(scale, limit)
        return (CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded())), shrunk)
    }

    static func rasterizeSVG(_ url: URL, maxPixelSize: Int?) throws -> CGImage {
        guard let image = NSImage(contentsOf: url) else { throw AppError.unreadable(url) }
        let drawing = drawingPixels(for: image.size, target: CGFloat(maxPixelSize ?? 2048))
        let pixelSize = drawing.size
        if drawing.shrunk {
            noteShrunk(url, from: (SafeNumber.int(image.size.width, in: 0...Int.max / 2), SafeNumber.int(image.size.height, in: 0...Int.max / 2)),
                       longest: Int(max(pixelSize.width, pixelSize.height)))
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw AppError.unreadable(url) }
        rep.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: pixelSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { throw AppError.unreadable(url) }
        return cg
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func pixelSize(_ url: URL) -> CGSize {
        let props = properties(url)
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if orientation >= 5 { return CGSize(width: height, height: width) }
        return CGSize(width: width, height: height)
    }

    static func write(_ image: CGImage, to url: URL, format: FileFormat, quality: Double = 0.9, metadata: [CFString: Any]? = nil) throws {
        guard let type = format.utType, nativeEncoders.contains(type.identifier) else {
            throw AppError.encodeFailed(tr("\(format.displayName) natively", "\(format.displayName) mit den Mitteln von macOS"))
        }
        DiagnosticLog.log("image write \(url.lastPathComponent) as \(type.identifier) quality=\(quality) metadata=\(metadata?.count ?? 0)")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw AppError.encodeFailed(url.lastPathComponent)
        }
        // Settings › Privacy: no place, or no metadata at all.
        var options: [CFString: Any] = Privacy.clean(metadata) ?? [:]
        // Every picture written here is upright already (loaded with its turn applied, `load`): a turn from the original's metadata
        // would turn it a second time.
        options[kCGImagePropertyOrientation] = 1
        if var tiff = options[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            options[kCGImagePropertyTIFFDictionary] = tiff
        }
        if format == .jpg || format == .heic || format == .webp || format == .avif {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        var output = image
        if format == .jpg || format == .bmp, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
            output = flatten(image, background: .white)
            DiagnosticLog.log("flattened alpha \(output.width)x\(output.height)")
        }
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        DiagnosticLog.log("image added, finalizing")
        guard CGImageDestinationFinalize(destination) else { throw AppError.encodeFailed(url.lastPathComponent) }
        DiagnosticLog.log("image finalized \(url.lastPathComponent)")
    }

    /// The largest side a format can store: WebP holds at most 16,383 pixels per side.
    static func maxPixelsPerSide(_ format: FileFormat) -> Int? {
        format == .webp ? 16_383 : nil
    }

    /// Throws a clear message instead of letting the encoder fail with "Conversion failed!". Nothing is shrunk automatically.
    static func checkFits(width: Int, height: Int, format: FileFormat) throws {
        guard let limit = maxPixelsPerSide(format), max(width, height) > limit else { return }
        throw AppError.invalidInput(tr("\(format.displayName) images can be at most \(limit) pixels on each side, but this one is \(width) × \(height). "
            + "Choose another format such as JPG or PNG, or make the image smaller first with Resize.",
                                       "\(format.displayName)-Bilder dürfen auf jeder Seite höchstens \(limit) Pixel haben, dieses hat \(width) × \(height). "
            + "Wähle ein anderes Format wie JPG oder PNG oder verkleinere das Bild zuerst mit \u{201E}Größe ändern\u{201C}."))
    }

    /// Seconds ffmpeg needs per megapixel; WebP is slow (about 30 to 45 s for 100 MP on an Apple silicon Mac).
    static func expectedSecondsPerMegapixel(_ format: FileFormat) -> Double {
        format == .webp ? 0.45 : 0.05
    }

    /// A progress estimate from the elapsed time while an encoder reports nothing: rises steadily, never reaches the end.
    static func estimatedProgress(elapsed: TimeInterval, expected: TimeInterval) -> Double {
        guard expected > 0 else { return 0 }
        return min(0.95, 1 - exp(-1.5 * elapsed / expected))
    }

    static func writeAnyFormat(_ image: CGImage, to url: URL, format: FileFormat, quality: Double = 0.9, progress: ((Double) -> Void)? = nil) async throws {
        try checkFits(width: image.width, height: image.height, format: format)
        if canEncodeNatively(format) {
            try write(image, to: url, format: format, quality: quality)
            return
        }
        DiagnosticLog.log("no native encoder for \(format.rawValue), using ffmpeg")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(image, to: temp, format: .png)
        progress?(0.1)
        // ffmpeg reports no progress for a single image, so the bar moves on an estimate meanwhile.
        let expected = Double(image.width * image.height) / 1_000_000 * expectedSecondsPerMegapixel(format)
        let ticker = Task {
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { break }
                progress?(0.1 + 0.9 * estimatedProgress(elapsed: Date().timeIntervalSince(start), expected: expected))
            }
        }
        defer { ticker.cancel() }
        try await encodeWithFFmpeg(png: temp, to: url, format: format, quality: quality)
    }

    static func encodeWithFFmpeg(png: URL, to url: URL, format: FileFormat, quality: Double) async throws {
        var args = ["-i", png.path, "-frames:v", "1"]
        switch format {
        case .webp:
            args += ["-c:v", "libwebp", "-quality", String(Int(quality * 100)), "-f", "webp"]
        case .avif:
            let crf = Int((1 - quality) * 50 + 10)
            args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", String(crf), "-b:v", "0", "-pix_fmt", "yuv420p", "-f", "avif"]
        case .heic:
            args += ["-c:v", "libx265", "-tag:v", "hvc1", "-pix_fmt", "yuv420p", "-f", "hevc"]
        case .bmp:
            args += ["-f", "image2", "-c:v", "bmp"]
        case .tiff:
            args += ["-f", "image2", "-c:v", "tiff"]
        case .jpg:
            args += ["-f", "image2", "-c:v", "mjpeg", "-q:v", String(Int((1 - quality) * 30 + 2))]
        default:
            throw AppError.unsupportedConversion(.png, format)
        }
        args.append(url.path)
        try await FFmpeg.run(args, purpose: tr("Encoding \(format.displayName)", "\(format.displayName) erstellen"))
    }

    static func flatten(_ image: CGImage, background: NSColor) -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: outputSpace(of: image), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func resized(_ image: CGImage, longEdge: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longEdge > 0, longest > longEdge else { return image }
        let scale = CGFloat(longEdge) / CGFloat(longest)
        return scaled(image, to: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
    }

    static func scaled(_ image: CGImage, to size: CGSize) -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: outputSpace(of: image), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func cropped(_ image: CGImage, to rect: CGRect) -> CGImage {
        let bounded = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: bounded) ?? image
    }
}

struct ImageEngine: ConversionEngine {
    /// A picture with fewer characters than this is not taken for a page of text when it becomes a Word document.
    static let textPageCharacters = 200

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from.category == .image else { return false }
        return to.category == .image || to == .pdf || to == .docx
    }

    func convert(_ request: ConversionRequest) async throws {
        switch request.target {
        case .pdf:
            // Page as chosen in Settings; JPEGs go in as they are (see PDFRenderer.embeddedImage).
            try PDFRenderer.writeImagesPDF([request.source], layout: AppSettings.shared.imagesToPDFLayout, to: request.destination) {
                request.progress($0)
            }
        case .docx:
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-docx-image-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The same way as a scan: the picture on a PDF page, text recognized, highlighter kept (`PDFToWord`).
            let pdf = folder.appendingPathComponent("picture.pdf")
            try PDFRenderer.writeImagesPDF([request.source], layout: AppSettings.shared.imagesToPDFLayout, to: pdf) { _ in }
            request.progress(0.05)
            var document = try await PDFToWord.analyze(pdf, progress: { request.progress(0.05 + 0.9 * $0) })
            // A photo with a sign in it is not a page of text, and only the sign would be left: little text, no picture
            // found, then the picture itself comes first. A short note on paper gets both, which loses nothing.
            if document.plainText.count < Self.textPageCharacters, !document.blocks.contains(where: \.isPicture) {
                document.blocks.insert(.picture(try DocxWriter.picture(try PDFRenderer.embeddableFile(for: request.source, in: folder))), at: 0)
            }
            try await document.write(to: request.destination)
        default:
            let size = ImageIOBridge.pixelSize(request.source)
            try ImageIOBridge.checkFits(width: Int(size.width), height: Int(size.height), format: request.target)
            let image = try ImageIOBridge.load(request.source)
            request.progress(0.3)
            if FileFormat.iconTargets.contains(request.target) {
                try IconWriter.write(image, to: request.destination, format: request.target)
                request.progress(1)
                return
            }
            let quality = AppSettings.shared.jpegQuality
            try await ImageIOBridge.writeAnyFormat(image, to: request.destination, format: request.target, quality: quality) {
                request.progress(0.3 + 0.7 * $0)
            }
        }
        request.progress(1)
    }
}

/// Icons with several sizes in one file, made by macOS (ImageIO). A picture that is not square is fitted in the middle, the rest
/// stays transparent. ICO: the six sizes Windows uses, up to 256 pixels (ImageIO takes no more than six pictures, none larger).
/// ICNS: all ten pictures of a Mac icon, 16 to 512 points, each also at twice the pixels; without the resolution of each, ImageIO
/// silently leaves two of them out.
enum IconWriter {
    static let icoSizes = [16, 24, 32, 48, 64, 256]
    static let icnsSizes: [(pixels: Int, retina: Bool)] = [(16, false), (32, true), (32, false), (64, true), (128, false), (256, true),
                                                           (256, false), (512, true), (512, false), (1024, true)]

    static func write(_ image: CGImage, to url: URL, format: FileFormat) throws {
        let pictures: [(image: CGImage, dpi: Int?)]
        switch format {
        case .ico: pictures = icoSizes.map { (square(image, side: $0), nil) }
        case .icns: pictures = icnsSizes.map { (square(image, side: $0.pixels), $0.retina ? 144 : 72) }
        default: throw AppError.unsupportedConversion(.png, format)
        }
        guard let type = format.utType,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, pictures.count, nil) else {
            throw AppError.encodeFailed(url.lastPathComponent)
        }
        for picture in pictures {
            let options: [CFString: Any] = picture.dpi.map { [kCGImagePropertyDPIWidth: $0, kCGImagePropertyDPIHeight: $0] } ?? [:]
            CGImageDestinationAddImage(destination, picture.image, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw AppError.encodeFailed(url.lastPathComponent) }
    }

    /// The picture fitted into a transparent square, scaled down in halves first so small sizes stay smooth.
    static func square(_ image: CGImage, side: Int) -> CGImage {
        var source = image
        while max(source.width, source.height) > side * 2 {
            source = ImageIOBridge.scaled(source, to: CGSize(width: max(1, source.width / 2), height: max(1, source.height / 2)))
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        context.interpolationQuality = .high
        let scale = Double(side) / Double(max(source.width, source.height))
        let width = Double(source.width) * scale, height = Double(source.height) * scale
        context.draw(source, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        return context.makeImage() ?? source
    }
}
