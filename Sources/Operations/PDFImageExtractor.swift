import CoreGraphics
import Foundation

/// Pulls the images out of a PDF. JPEG images are copied byte for byte, JPEG 2000 as .jp2; every other image is decoded
/// (any colour space, masks and transparency included) and saved as PNG. An image used on several pages is saved once.
enum PDFImageExtractor {
    struct Image {
        /// Page it first appears on (1-based).
        let page: Int
        let width: Int
        let height: Int
        fileprivate let stream: CGPDFStreamRef
        /// Keeps the document open: the stream is only valid as long as its document lives.
        fileprivate let document: CGPDFDocument
    }

    struct Result: Equatable {
        var saved: [URL] = []
        /// Images in a form this extractor cannot turn into a picture (e.g. special printing colours).
        var skipped = 0
    }

    /// The distinct images of `url`, in page order. Throws if the PDF can't be read or is password protected.
    static func images(in url: URL) throws -> [Image] {
        guard let document = CGPDFDocument(url as CFURL) else { throw AppError.unreadable(url) }
        guard !document.isEncrypted || document.isUnlocked else {
            throw AppError.invalidInput(tr("\(url.lastPathComponent) is password protected.", "\(url.lastPathComponent) ist mit einem Passwort geschützt."))
        }
        let collector = StreamCollector(document: document)
        if document.numberOfPages > 0 {
            for number in 1...document.numberOfPages {
                guard let dictionary = document.page(at: number)?.dictionary else { continue }
                collector.collect(from: dictionary, page: number, depth: 0)
            }
        }
        return collector.images
    }

    /// Saves the images of `url` into `folder` (which must exist) as "page N image M.ext".
    static func extract(from url: URL, into folder: URL, progress: (Double) -> Void = { _ in }) throws -> Result {
        let found = try images(in: url)
        var result = Result()
        var perPage: [Int: Int] = [:]
        for (index, image) in found.enumerated() {
            try Task.checkCancellation()
            perPage[image.page, default: 0] += 1
            let base = folder.appendingPathComponent(tr("page \(image.page) image \(perPage[image.page]!)", "Seite \(image.page) Bild \(perPage[image.page]!)"))
            if let file = try save(image, to: base) {
                result.saved.append(file)
            } else {
                result.skipped += 1
            }
            progress(Double(index + 1) / Double(found.count))
        }
        return result
    }

    /// The tool's job: extracts into a temporary folder and moves it next to the PDF as "Name (images)" at the end,
    /// so no half-filled folder shows up there. Throws a readable message if there is nothing to save.
    static func extractToFolder(from url: URL, in directory: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-images-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let result = try extract(from: url, into: work, progress: progress)
        DiagnosticLog.log("extract images: \(result.saved.count) saved, \(result.skipped) skipped")
        guard !result.saved.isEmpty else {
            throw AppError.invalidInput(result.skipped == 0
                ? tr("No images were found in \(url.lastPathComponent).", "In \(url.lastPathComponent) wurden keine Bilder gefunden.")
                : tr("\(url.lastPathComponent) has \(result.skipped) image\(result.skipped == 1 ? "" : "s") in a form that can't be saved as a picture.",
                     "\(url.lastPathComponent) hat \(result.skipped) \(result.skipped == 1 ? "Bild" : "Bilder") in einer Form, die sich nicht als Bild sichern lässt."))
        }
        let folder = ConversionMatrix.uniqueDirectory(directory: directory, name: "\(ConversionMatrix.strippedBaseName(url.lastPathComponent)) \(tr("images", "Bilder"))")
        try FileManager.default.moveItem(at: work, to: folder)
        return folder
    }

    /// Writes one image; nil if it can't be turned into a picture.
    private static func save(_ image: Image, to base: URL) throws -> URL? {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(image.stream, &format) as Data? else { return nil }
        switch format {
        case .jpegEncoded:
            let file = base.appendingPathExtension("jpg")
            try data.write(to: file)
            return file
        case .JPEG2000:
            let file = base.appendingPathExtension("jp2")
            try data.write(to: file)
            return file
        case .raw:
            guard let dictionary = CGPDFStreamGetDictionary(image.stream), let picture = decode(raw: data, dictionary: dictionary) else { return nil }
            let file = base.appendingPathExtension("png")
            try ImageIOBridge.write(picture, to: file, format: .png)
            return file
        @unknown default:
            return nil
        }
    }

    /// The largest image this extractor decodes, per side and in all; numbers in a PDF can say anything.
    static let largestSide = 100_000
    static let largestPixels = 250_000_000

    /// Width or height as written in a PDF, or 0 when it is no sensible size.
    static func dimension(_ value: CGPDFInteger) -> Int {
        (1...largestSide).contains(value) ? value : 0
    }

    /// Builds a picture from decoded image samples, applies a soft mask as transparency, and draws it into sRGB.
    /// `withMask` false for the soft mask itself: a mask has no mask, and one that names itself would recurse for ever.
    static func decode(raw data: Data, dictionary: CGPDFDictionaryRef, withMask: Bool = true) -> CGImage? {
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              dimension(width) > 0, dimension(height) > 0, width * height <= largestPixels else { return nil }
        var isMask: CGPDFBoolean = 0
        CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask)
        if isMask != 0 { bits = 1 } else { CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits) }
        guard [1, 2, 4, 8, 16].contains(bits) else { return nil }

        let space: CGColorSpace
        if isMask != 0 {
            space = CGColorSpaceCreateDeviceGray()
        } else {
            var object: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object), let object, let resolved = colorSpace(object) else { return nil }
            space = resolved
        }
        let components = space.model == .indexed ? 1 : space.numberOfComponents
        guard (1...32).contains(components) else { return nil }
        let bytesPerRow = (width * components * bits + 7) / 8
        guard data.count >= bytesPerRow * height, let provider = CGDataProvider(data: data as CFData) else { return nil }
        // A stencil mask or a gray image with Decode [1 0] stores black as 1.
        var decodeArray: CGPDFArrayRef?
        var inverted = isMask != 0
        if CGPDFDictionaryGetArray(dictionary, "Decode", &decodeArray), let decodeArray, CGPDFArrayGetCount(decodeArray) >= 2 {
            var first: CGPDFReal = 0
            CGPDFArrayGetNumber(decodeArray, 0, &first)
            inverted = first == 1
        }
        let decodeValues: [CGFloat]? = inverted && components == 1 ? [1, 0] : nil
        guard let samples = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components, bytesPerRow: bytesPerRow,
                                    space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                    decode: decodeValues, shouldInterpolate: false, intent: .defaultIntent) else { return nil }

        var picture = samples
        var softMask: CGPDFStreamRef?
        if withMask, CGPDFDictionaryGetStream(dictionary, "SMask", &softMask), let softMask, let maskDictionary = CGPDFStreamGetDictionary(softMask),
           maskDictionary != dictionary {
            var maskFormat = CGPDFDataFormat.raw
            if let maskData = CGPDFStreamCopyData(softMask, &maskFormat) as Data?, maskFormat == .raw,
               let alpha = decode(raw: maskData, dictionary: maskDictionary, withMask: false).flatMap(grayscale), let masked = samples.masking(alpha) {
                picture = masked
            }
        }
        // Drawing into sRGB settles every colour space (CMYK, indexed, ICC, 16 bit) and keeps the transparency.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The soft mask as an 8-bit gray image without alpha, as `CGImage.masking` expects.
    private static func grayscale(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// The colour spaces found in practice: device spaces, ICC profiles, calibrated spaces and indexed palettes.
    /// `depth`: an indexed space names its base space, which may (in a damaged file) name the indexed one again.
    static func colorSpace(_ object: CGPDFObjectRef, depth: Int = 0) -> CGColorSpace? {
        guard depth < 4 else { return nil }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name {
            switch String(cString: name) {
            case "DeviceRGB", "CalRGB": return CGColorSpaceCreateDeviceRGB()
            case "DeviceGray", "CalGray": return CGColorSpaceCreateDeviceGray()
            case "DeviceCMYK": return CGColorSpaceCreateDeviceCMYK()
            default: return nil
            }
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) >= 1,
              CGPDFArrayGetName(array, 0, &name), let name else { return nil }
        switch String(cString: name) {
        case "ICCBased":
            var stream: CGPDFStreamRef?
            var count: CGPDFInteger = 3
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
            CGPDFDictionaryGetInteger(dictionary, "N", &count)
            var format = CGPDFDataFormat.raw
            if let profile = CGPDFStreamCopyData(stream, &format), let space = CGColorSpace(iccData: profile), space.numberOfComponents == count {
                return space
            }
            return count == 1 ? CGColorSpaceCreateDeviceGray() : count == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB()
        case "CalRGB", "Lab": return CGColorSpaceCreateDeviceRGB()
        case "CalGray": return CGColorSpaceCreateDeviceGray()
        case "Indexed", "I":
            var baseObject: CGPDFObjectRef?
            var highest: CGPDFInteger = 0
            guard CGPDFArrayGetCount(array) >= 4, CGPDFArrayGetObject(array, 1, &baseObject), let baseObject, let base = colorSpace(baseObject, depth: depth + 1),
                  CGPDFArrayGetInteger(array, 2, &highest), highest >= 0, highest < 256 else { return nil }
            var table: Data?
            var string: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                table = Data(bytes: bytes, count: CGPDFStringGetLength(string))
            } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
                var format = CGPDFDataFormat.raw
                table = CGPDFStreamCopyData(stream, &format) as Data?
            }
            let needed = (highest + 1) * base.numberOfComponents
            guard let table, table.count >= needed else { return nil }
            return table.withUnsafeBytes { CGColorSpace(indexedBaseSpace: base, last: highest, colorTable: $0.bindMemory(to: UInt8.self).baseAddress!) }
        default:
            // Separation, DeviceN and similar printing colour spaces are not converted.
            return nil
        }
    }
}

/// Finds image streams in page resources (also inside form objects); each stream is listed once.
private final class StreamCollector {
    var images: [PDFImageExtractor.Image] = []
    private var seen = Set<Int>()
    /// Forms already looked into: a form used a thousand times, or one inside itself, is looked into once.
    private var forms = Set<Int>()
    private let document: CGPDFDocument

    init(document: CGPDFDocument) { self.document = document }

    func collect(from owner: CGPDFDictionaryRef, page: Int, depth: Int) {
        var resources: CGPDFDictionaryRef?
        var xObjects: CGPDFDictionaryRef?
        guard depth < 4, forms.count < 100_000,
              CGPDFDictionaryGetDictionary(owner, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                guard self.seen.insert(unsafeBitCast(stream, to: Int.self)).inserted else { return true }
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                self.images.append(.init(page: page, width: PDFImageExtractor.dimension(width), height: PDFImageExtractor.dimension(height),
                                         stream: stream, document: self.document))
            case "Form":
                guard self.forms.insert(unsafeBitCast(stream, to: Int.self)).inserted else { return true }
                self.collect(from: dictionary, page: page, depth: depth + 1)
            default:
                break
            }
            return true
        }, nil)
    }
}
