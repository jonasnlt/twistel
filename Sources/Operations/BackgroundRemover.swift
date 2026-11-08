import CoreImage
import CoreVideo
import Foundation
import Vision

/// Cuts the main subjects out of a picture with Apple Vision (the same model as "Copy Subject" in Photos), on this Mac. The result
/// has the picture's size and colours; everything else is transparent.
enum BackgroundRemover {
    struct Cutout {
        let image: CGImage
        /// How many subjects Vision told apart in the picture.
        let subjects: Int
    }

    /// `subject`: one of the subjects, counted from the left of the picture from 0; nil for all of them.
    static func cutout(_ image: CGImage, subject: Int? = nil) async throws -> Cutout {
        let found: InstanceMaskObservation?
        do {
            found = try await VisionLimit.call(on: image) { try await GenerateForegroundInstanceMaskRequest().perform(on: image) }
        } catch where Task.isCancelled {
            throw CancellationError()
        }
        guard let found, !found.allInstances.isEmpty else { throw AppError.invalidInput(tr("No clear subject was found in this picture.", "In diesem Bild wurde kein klares Motiv gefunden.")) }
        let order = found.allInstances.map { instance in (instance, (try? found.generateMask(for: [instance])).flatMap(leftEdge) ?? 1) }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }.map(\.0)
        var chosen = found.allInstances
        if let subject {
            guard order.indices.contains(subject) else { throw AppError.invalidInput(tr("This picture has only \(order.count) subject(s).", "Dieses Bild hat nur \(order.count) \(order.count == 1 ? "Motiv" : "Motive").")) }
            chosen = [order[subject]]
        }
        try Task.checkCancellation()
        let mask = try found.generateScaledMask(for: chosen, scaledToImageFrom: ImageRequestHandler(image))
        return Cutout(image: try cut(image, mask: mask), subjects: order.count)
    }

    /// The picture's own colours with the mask as transparency. In the picture's own colour space, so that the colours do not shift.
    private static func cut(_ image: CGImage, mask: CVPixelBuffer) throws -> CGImage {
        let picture = CIImage(cgImage: image)
        // A mask holds amounts, not colours: no colour conversion for it.
        let amounts = CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()])
        guard let filter = CIFilter(name: "CIBlendWithMask") else { throw AppError.encodeFailed(tr("cutout", "Freigestelltes Bild")) }
        filter.setValue(picture, forKey: kCIInputImageKey)
        filter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        filter.setValue(amounts, forKey: kCIInputMaskImageKey)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = filter.outputImage,
              let result = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: picture.extent, format: .RGBA8, colorSpace: space) else {
            throw AppError.encodeFailed(tr("cutout", "Freigestelltes Bild"))
        }
        return result
    }

    /// Where a subject begins, as a fraction of the mask's width.
    private static func leftEdge(_ mask: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
        let isFloat = CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float
        var edge = width
        for y in 0..<height {
            let line = base.advanced(by: y * row)
            for x in 0..<min(edge, width) where isFloat ? line.assumingMemoryBound(to: Float.self)[x] > 0.5 : line.assumingMemoryBound(to: UInt8.self)[x] > 127 {
                edge = x
                break
            }
        }
        return Double(edge) / Double(max(width, 1))
    }

    static func outputURL(for url: URL) -> URL {
        ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: url),
                                   baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: tr("cutout", "freigestellt"), ext: "png")
    }

    static func save(_ url: URL, subject: Int? = nil, to destination: URL) async throws {
        let image = try ImageIOBridge.load(url)
        try ImageIOBridge.write(try await cutout(image, subject: subject).image, to: destination, format: .png)
    }
}
