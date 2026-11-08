import CoreImage
import Foundation
import ImageIO

/// Saves a picture with parts covered, and checks it before it is saved. No metadata comes along: a photo's thumbnail would still show what is covered, and its place and camera say more than the picture.
enum ImageRedactor {
    /// `terms`, `parts`: what must no longer be readable (see `RedactionCheck.stillReadable`). Places in pixels, origin top left.
    static func save(_ original: CGImage, redactions: [Redaction], terms: [String] = [], parts: [String] = [], format: FileFormat, quality: Double, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-redact-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard let image = ImageToolSupport.cgImage(ImageOps.redact(CIImage(cgImage: original), redactions: redactions), like: original) else { throw AppError.encodeFailed(tr("Rendering failed", "Bild")) }
        progress(0.3)
        let file = work.appendingPathComponent("redacted.\(format.fileExtension)")
        if ImageIOBridge.canEncodeNatively(format) {
            try ImageIOBridge.write(image, to: file, format: format, quality: quality, metadata: nil)
        } else {
            try await ImageIOBridge.writeAnyFormat(image, to: file, format: format, quality: quality)
        }
        progress(0.5)
        try Task.checkCancellation()
        let found = await problems(in: file, redactions: redactions, terms: terms, parts: parts)
        guard found.isEmpty else {
            DiagnosticLog.log("picture redaction check failed: \(found)")
            throw AppError.invalidInput(tr("The check found that something could still be seen, so nothing was saved: \(found.joined(separator: "; ")).", "Die Prüfung hat gefunden, dass noch etwas zu sehen ist, deshalb wurde nichts gesichert: \(found.joined(separator: "; "))."))
        }
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        progress(1)
    }

    /// In the saved file, read back: solid places are solid, the words cannot be read, a pixelated face is no longer a face, nothing identifying is in the metadata.
    static func problems(in file: URL, redactions: [Redaction], terms: [String], parts: [String] = []) async -> [String] {
        guard let image = try? ImageIOBridge.load(file) else { return [tr("the result cannot be read", "das Ergebnis lässt sich nicht lesen")] }
        var problems: [String] = []
        if !metadataIsClean(file) { problems.append(tr("the file still has metadata", "die Datei enthält noch Metadaten")) }
        let solid = redactions.filter { $0.style == .solid }
        if !isSolid(image, places: solid) { problems.append(tr("a covered place is not solid", "eine abgedeckte Stelle ist nicht deckend")) }
        if !terms.isEmpty || !parts.isEmpty {
            let read = (try? await TextRecognizer.recognize(image, choosingWords: false)).map(TextRecognizer.plainText) ?? ""
            if let what = RedactionCheck.stillReadable(terms: terms, parts: parts, in: read) { problems.append(tr("\(what) can still be read", "\(what) ist noch lesbar")) }
        }
        let pixelated = redactions.filter { $0.style != .solid && $0.isFace }
        if !pixelated.isEmpty, let faces = try? await RedactionFinder.faces(in: image) {
            let size = CGSize(width: image.width, height: image.height)
            let shown = faces.map { CGRect(x: $0.minX * size.width, y: $0.minY * size.height, width: $0.width * size.width, height: $0.height * size.height) }
            if pixelated.contains(where: { place in shown.contains { TextRecognizer.overlap($0, place.rect) > 0.5 } }) { problems.append(tr("a blurred or pixelated face can still be recognized; use Solid", "ein weichgezeichnetes oder verpixeltes Gesicht ist noch erkennbar; wähle \u{201E}Deckend\u{201C}")) }
        }
        return problems
    }

    private static func metadataIsClean(_ file: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil || properties[kCGImagePropertyIPTCDictionary] != nil { return false }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any], tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil { return false }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any], exif[kCGImagePropertyExifUserComment] != nil || exif[kCGImagePropertyExifDateTimeOriginal] != nil { return false }
        // A preview picture inside the file would show the place uncovered.
        return CGImageSourceGetCount(source) == 1 && (properties[kCGImagePropertyThumbnailImages] == nil)
    }

    /// Inside each solid place one colour, up to what saving as JPEG leaves.
    private static func isSolid(_ image: CGImage, places: [Redaction]) -> Bool {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        for place in places {
            let area = place.rect.insetBy(dx: 2, dy: 2).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard area.width >= 1, area.height >= 1 else { continue }
            let first = (Int(area.midY) * width + Int(area.midX)) * 4
            let colour = (Int(pixels[first]), Int(pixels[first + 1]), Int(pixels[first + 2]))
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in Int(area.minX)..<Int(area.maxX) {
                    let at = (y * width + x) * 4
                    if abs(Int(pixels[at]) - colour.0) > 40 || abs(Int(pixels[at + 1]) - colour.1) > 40 || abs(Int(pixels[at + 2]) - colour.2) > 40 { return false }
                }
            }
        }
        return true
    }
}
