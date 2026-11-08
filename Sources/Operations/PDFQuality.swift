import Accelerate
import CoreGraphics
import Foundation
import PDFKit

/// Measures how much a PDF changed for the eye: pages are drawn as they appear when a whole page fills a screen
/// (long edge `screenLongEdge` pixels, whatever the page size) and compared pixel by pixel (PSNR in dB).
/// From about 40 dB on, no difference is visible; identical pages give `identical`.
enum PDFQuality {
    static let identical = 99.0
    static let screenLongEdge: CGFloat = 1600
    /// Long PDFs are checked on this many pages, spread evenly from first to last.
    static let maxCheckedPages = 30

    /// The lowest PSNR over the checked pages, or nil if the files can't be compared.
    /// Throws `CancellationError` as soon as the surrounding task is cancelled.
    static func worstPagePSNR(_ original: URL, _ changed: URL, longEdge: CGFloat = screenLongEdge, maxPages: Int = maxCheckedPages,
                              progress: ((Double) -> Void)? = nil) throws -> Double? {
        try pagePSNRs(original, changed, longEdge: longEdge, maxPages: maxPages, progress: progress).map { $0.values.min() ?? identical }
    }

    /// PSNR of each checked page, keyed by page number (1-based).
    static func pagePSNRs(_ original: URL, _ changed: URL, longEdge: CGFloat = screenLongEdge, maxPages: Int = maxCheckedPages,
                          progress: ((Double) -> Void)? = nil) throws -> [Int: Double]? {
        guard let first = PDFDocument(url: original), let second = PDFDocument(url: changed), first.pageCount == second.pageCount else { return nil }
        let pages = sampledPages(count: first.pageCount, limit: maxPages)
        var results: [Int: Double] = [:]
        for (done, index) in pages.enumerated() {
            try Task.checkCancellation()
            guard let pageA = first.page(at: index), let pageB = second.page(at: index),
                  let a = pixels(pageA, longEdge: longEdge), let b = pixels(pageB, longEdge: longEdge), a.count == b.count else { return nil }
            var difference = [Float](repeating: 0, count: a.count)
            vDSP_vsub(b, 1, a, 1, &difference, 1, vDSP_Length(a.count))
            var sum: Float = 0
            vDSP_svesq(difference, 1, &sum, vDSP_Length(difference.count))
            // The alpha channel is opaque in both, so it adds nothing to the sum.
            let mse = Double(sum) / Double(a.count / 4 * 3)
            results[index + 1] = mse > 0 ? min(identical, 10 * log10(255 * 255 / mse)) : identical
            progress?(Double(done + 1) / Double(pages.count))
        }
        return results
    }

    /// All pages up to `limit`, otherwise `limit` pages spread evenly, always including the first and the last.
    static func sampledPages(count: Int, limit: Int) -> [Int] {
        guard count > limit, limit > 1 else { return Array(0..<count) }
        return (0..<limit).map { Int((Double($0) * Double(count - 1) / Double(limit - 1)).rounded()) }
    }

    private static func pixels(_ page: PDFPage, longEdge: CGFloat) -> [Float]? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = longEdge / max(bounds.width, bounds.height, 1)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard drawn else { return nil }
        var values = [Float](repeating: 0, count: bytes.count)
        vDSP_vfltu8(bytes, 1, &values, 1, vDSP_Length(bytes.count))
        return values
    }
}
