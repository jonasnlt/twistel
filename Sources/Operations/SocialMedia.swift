import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Pictures for social media and for sending. All sizes are in this one table, so they are easy to change.
enum SocialPreset: String, CaseIterable, Identifiable {
    case linkedInSquare, linkedInPortrait, linkedInLandscape
    case instagramSquare, instagramPortrait, instagramGrid, instagramStory
    case linkedInPost, email, whatsApp

    var id: String { rawValue }

    /// What the preset does: cut to an exact size, or make smaller for sending.
    enum Kind: Equatable {
        /// Cut to this aspect and size in pixels (never enlarged).
        case crop(width: Int, height: Int)
        /// Longest edge in pixels and the largest file size in bytes; nothing is cut off.
        case send(longEdge: Int, maxBytes: Int)
    }

    // MARK: The sizes (checked by hand; change them here)

    var kind: Kind {
        switch self {
        case .linkedInSquare: return .crop(width: 1080, height: 1080)
        case .linkedInPortrait: return .crop(width: 1080, height: 1350)
        case .linkedInLandscape: return .crop(width: 1200, height: 627)
        case .instagramSquare: return .crop(width: 1080, height: 1080)
        case .instagramPortrait: return .crop(width: 1080, height: 1350)
        // The profile grid shows posts in 3:4.
        case .instagramGrid: return .crop(width: 1080, height: 1440)
        case .instagramStory: return .crop(width: 1080, height: 1920)
        // LinkedIn shows a post picture about 1200 px wide and takes up to about 5 MB: 2400 px stays sharp on Retina
        // screens and well below the limit.
        case .linkedInPost: return .send(longEdge: 2400, maxBytes: 3_000_000)
        // Ten pictures in one mail stay near 5 MB (mail servers often allow 10 to 25 MB); 1600 px fills a screen and
        // prints well up to about 13 × 9 cm.
        case .email: return .send(longEdge: 1600, maxBytes: 500_000)
        // WhatsApp makes pictures 1600 px on the long edge anyway (standard quality); anything larger only takes longer.
        case .whatsApp: return .send(longEdge: 1600, maxBytes: 400_000)
        }
    }

    // MARK: Names

    var title: String {
        switch self {
        case .linkedInSquare: return tr("LinkedIn square", "LinkedIn quadratisch")
        case .linkedInPortrait: return tr("LinkedIn portrait", "LinkedIn hoch")
        case .linkedInLandscape: return tr("LinkedIn landscape", "LinkedIn quer")
        case .instagramSquare: return tr("Instagram square", "Instagram quadratisch")
        case .instagramPortrait: return tr("Instagram portrait", "Instagram hoch")
        case .instagramGrid: return "Instagram 3:4"
        case .instagramStory: return tr("Instagram story", "Instagram Story")
        case .linkedInPost: return tr("LinkedIn post", "LinkedIn Beitrag")
        case .email: return tr("E-mail", "E-Mail")
        case .whatsApp: return "WhatsApp"
        }
    }

    var detail: String {
        switch kind {
        case let .crop(width, height): return "\(width) × \(height)"
        case let .send(longEdge, maxBytes): return "\(longEdge) px, \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file))"
        }
    }

    /// For file names: a colon shows up as a slash in Finder.
    var fileSuffix: String { title.replacingOccurrences(of: ":", with: "x") }

    var isCrop: Bool { if case .crop = kind { return true } else { return false } }

    static var crops: [SocialPreset] { allCases.filter(\.isCrop) }
    static var sends: [SocialPreset] { allCases.filter { !$0.isCrop } }
}

/// Where to cut a picture so that faces and the main subject stay in it, with Apple Vision.
enum SmartCrop {
    enum Found: String {
        case faces, people, subject, nothing
        /// The cut was placed by hand.
        case chosen
    }

    private enum SaliencyKind {
        case objects, attention

        func salientObjects(in image: CGImage) async throws -> [RectangleObservation] {
            switch self {
            case .objects: return try await VisionLimit.call(on: image) { try await GenerateObjectnessBasedSaliencyImageRequest().perform(on: image).salientObjects }
            case .attention: return try await VisionLimit.call(on: image) { try await GenerateAttentionBasedSaliencyImageRequest().perform(on: image).salientObjects }
            }
        }
    }

    /// What must stay in the picture, as fractions with the origin at the top left: faces (with hair and chin), else
    /// people, else the main object (Vision's saliency), else nothing.
    static func importantRegion(in image: CGImage) async -> (rect: CGRect?, found: Found) {
        let small = ImageIOBridge.resized(image, longEdge: 1600)
        if let faces = try? await VisionLimit.call(on: small, { try await DetectFaceRectanglesRequest().perform(on: small) }), !faces.isEmpty {
            var union = CGRect.null
            for observation in faces {
                let face = PDFToWord.topLeft(observation.boundingBox.cgRect)
                let x = face.minX - face.width * 0.25, y = face.minY - face.height * 0.45
                union = union.union(CGRect(x: x, y: y, width: face.width * 1.5, height: face.height * 1.75))
            }
            return (union.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), .faces)
        }
        if let people = try? await VisionLimit.call(on: small, { try await DetectHumanRectanglesRequest().perform(on: small) }), !people.isEmpty {
            return (people.map { PDFToWord.topLeft($0.boundingBox.cgRect) }.reduce(CGRect.null) { $0.union($1) }, .people)
        }
        // Objects first: the attention box of a picture with one red ball at the edge spanned 77 % of its width, the object
        // box only the ball. Both are coarse, so a margin of 5 % is added.
        for request in [SaliencyKind.objects, .attention] {
            guard let objects = try? await request.salientObjects(in: small), let best = objects.map(\.confidence).max() else { continue }
            let union = objects.filter { $0.confidence >= best * 0.5 }.map { PDFToWord.topLeft($0.boundingBox.cgRect) }.reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull else { continue }
            return (union.insetBy(dx: -0.05, dy: -0.05).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)), .subject)
        }
        return (nil, .nothing)
    }

    /// The largest window of the wanted aspect inside the picture, placed around the important region: centered on it,
    /// with all of it inside when it fits, moved to stay inside the picture. A region taller than the window keeps its top (heads), a wider one its middle.
    /// All in pixels, origin top left.
    static func window(imageSize: CGSize, aspect: CGSize, important: CGRect?) -> CGRect {
        let scale = min(imageSize.width / aspect.width, imageSize.height / aspect.height)
        let size = CGSize(width: (aspect.width * scale).rounded(.down), height: (aspect.height * scale).rounded(.down))
        guard let important, !important.isNull, !important.isEmpty else {
            return CGRect(x: ((imageSize.width - size.width) / 2).rounded(), y: ((imageSize.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        let region = CGRect(x: important.minX * imageSize.width, y: important.minY * imageSize.height,
                            width: important.width * imageSize.width, height: important.height * imageSize.height)
        var x = region.midX - size.width / 2
        var y = region.height > size.height ? region.minY : region.midY - size.height / 2
        // When the region fits, all of it goes in (centering alone can cut its edge when the picture's border is near).
        if region.width <= size.width { x = min(max(x, region.maxX - size.width), region.minX) }
        if region.height <= size.height { y = min(max(y, region.maxY - size.height), region.minY) }
        x = min(max(0, x), imageSize.width - size.width)
        y = min(max(0, y), imageSize.height - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Placing the cut by hand (all in pixels, origin top left)

    /// The cut chosen by hand, given as fractions of the picture, in pixels of a picture of `imageSize`: in the exact
    /// shape, around the same center, inside the picture. Works for the small preview and the full picture alike.
    static func window(fraction: CGRect, imageSize: CGSize, aspect: CGSize) -> CGRect {
        let largest = window(imageSize: imageSize, aspect: aspect, important: nil).size
        var width = min(max(fraction.width * imageSize.width, 1), largest.width)
        var height = width * aspect.height / aspect.width
        if height > largest.height {
            height = largest.height
            width = height * aspect.width / aspect.height
        }
        let x = min(max(0, fraction.midX * imageSize.width - width / 2), imageSize.width - width)
        let y = min(max(0, fraction.midY * imageSize.height - height / 2), imageSize.height - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(.down), height: height.rounded(.down))
    }

    /// The cut moved by `delta`, stopping at the picture's edges.
    static func moved(_ window: CGRect, by delta: CGSize, imageSize: CGSize) -> CGRect {
        CGRect(x: min(max(0, window.minX + delta.width), imageSize.width - window.width),
               y: min(max(0, window.minY + delta.height), imageSize.height - window.height),
               width: window.width, height: window.height)
    }

    /// The four corners: top left, top right, bottom right, bottom left.
    static func corner(_ index: Int, of rect: CGRect) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: rect.minX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.minY)
        case 2: return CGPoint(x: rect.maxX, y: rect.maxY)
        default: return CGPoint(x: rect.minX, y: rect.maxY)
        }
    }

    /// The cut with corner `index` dragged to `point`: the opposite corner stays, the shape stays, the cut stays inside
    /// the picture and is at least `minimumWidth` wide.
    static func resized(_ window: CGRect, corner index: Int, to point: CGPoint, aspect: CGSize, imageSize: CGSize, minimumWidth: CGFloat) -> CGRect {
        let ratio = aspect.width / aspect.height
        let anchor = corner((index + 2) % 4, of: window)
        let right = index == 1 || index == 2, down = index == 2 || index == 3
        let room = min(right ? imageSize.width - anchor.x : anchor.x, (down ? imageSize.height - anchor.y : anchor.y) * ratio)
        // The farther of the two directions wins, so the frame follows the mouse both ways.
        var width = max(right ? point.x - anchor.x : anchor.x - point.x, (down ? point.y - anchor.y : anchor.y - point.y) * ratio)
        width = min(max(width, minimumWidth), room)
        let height = width / ratio
        return CGRect(x: right ? anchor.x : anchor.x - width, y: down ? anchor.y : anchor.y - height, width: width, height: height)
    }
}

enum SocialMedia {
    /// The picture as it will look: cut and scaled, or only scaled; on white (no transparency in JPEG), in the colours of the original.
    /// `chosen` is a cut placed by hand (fractions of the picture, origin top left); without it the cut is found.
    static func render(_ url: URL, preset: SocialPreset, chosen: CGRect? = nil) async throws -> (image: CGImage, found: SmartCrop.Found) {
        let original = try ImageIOBridge.load(url)
        switch preset.kind {
        case let .crop(width, height):
            let size = CGSize(width: original.width, height: original.height), aspect = CGSize(width: width, height: height)
            let window: CGRect, found: SmartCrop.Found
            if let chosen {
                (window, found) = (SmartCrop.window(fraction: chosen, imageSize: size, aspect: aspect), .chosen)
            } else {
                let (region, detected) = await SmartCrop.importantRegion(in: original)
                try Task.checkCancellation()
                (window, found) = (SmartCrop.window(imageSize: size, aspect: aspect, important: region), detected)
            }
            let cut = ImageIOBridge.cropped(original, to: window)
            // Never enlarged: a smaller picture keeps its pixels, in the right shape.
            let target = cut.width >= width ? CGSize(width: width, height: height) : CGSize(width: cut.width, height: cut.height)
            return (ImageIOBridge.flatten(ImageIOBridge.scaled(cut, to: target), background: .white), found)
        case let .send(longEdge, _):
            return (ImageIOBridge.flatten(ImageIOBridge.resized(original, longEdge: longEdge), background: .white), .nothing)
        }
    }

    /// Saves the JPEG. Pictures for sending are made to fit the size limit: lower quality first (not below 0.5), then
    /// smaller. No metadata is written, so no location travels along with a picture sent by mail.
    static func save(_ url: URL, preset: SocialPreset, chosen: CGRect? = nil, to destination: URL) async throws {
        var (image, _) = try await render(url, preset: preset, chosen: chosen)
        guard case let .send(_, maxBytes) = preset.kind else {
            try write(jpeg(image, quality: 0.9), to: destination)
            return
        }
        while true {
            try Task.checkCancellation()
            if let data = bestJPEG(image, maxBytes: maxBytes) { return try write(data, to: destination) }
            guard image.width > 200 else { return try write(jpeg(image, quality: 0.5), to: destination) }
            image = ImageIOBridge.scaled(image, to: CGSize(width: Double(image.width) * 0.85, height: Double(image.height) * 0.85))
        }
    }

    /// The best quality between 0.5 and 0.9 that fits, or nil when even 0.5 is too large.
    static func bestJPEG(_ image: CGImage, maxBytes: Int) -> Data? {
        if let data = jpeg(image, quality: 0.9), data.count <= maxBytes { return data }
        guard var best = jpeg(image, quality: 0.5), best.count <= maxBytes else { return nil }
        var low = 0.5, high = 0.9
        for _ in 0..<6 {
            let quality = (low + high) / 2
            if let data = jpeg(image, quality: quality), data.count <= maxBytes { best = data; low = quality } else { high = quality }
        }
        return best
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func write(_ data: Data?, to destination: URL) throws {
        guard let data else { throw AppError.encodeFailed(destination.lastPathComponent) }
        // Not `.atomic`: that writes a hidden temporary file next to the original, which iCloud may hide for good.
        try data.write(to: destination)
    }

    static func outputURL(for url: URL, preset: SocialPreset) -> URL {
        ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                   baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: preset.fileSuffix, ext: "jpg")
    }
}
