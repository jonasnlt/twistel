import CoreGraphics
import Foundation

/// One log line per PDF compression, with numbers and decisions only: no file name, no text, no image content.
/// It explains why a PDF did or did not get smaller.
struct PDFDiagnosis {
    struct Image: Equatable {
        /// 1-based page number.
        let page: Int
        let width: Int
        let height: Int
        let filter: String
        /// Long edge of the page the image sits on, in points.
        let pageLongEdge: CGFloat

        /// Everything except JPEG counts as lossless (screenshots, graphics); JPEG is almost always a photo.
        var isLossless: Bool { filter != "DCTDecode" }

        /// The image's resolution if it spans the page's long edge (an upper bound when it is placed smaller).
        var dpiAtFullPage: Int { pageLongEdge >= 1 && pageLongEdge.isFinite ? SafeNumber.int((CGFloat(max(width, height)) / pageLongEdge * 72).rounded()) : 0 }
    }

    struct Pass {
        let name: String
        let bytes: Int64
        let seconds: Double
        var psnr: Double?
        var accepted = true
    }

    var purpose: String
    var preset: CompressionPreset
    var pageCount = 0
    var pageLongEdges: [CGFloat] = []
    var segments: [PDFCompression.Segment] = []
    var hasDocumentStructure = false
    var images: [Image] = []
    /// Images after the gentle photo pass and the sharpness of each checked page, for the per-page line.
    var imagesAfterPhotoPass: [Image] = []
    var pagePSNR: [Int: Double] = [:]
    /// Pages the photo pass left lossless because a lossless image on them would have changed.
    var protectedPages: Set<Int> = []
    var originalBytes: Int64 = 0
    var passes: [Pass] = []
    var decision = ""

    init(purpose: String, preset: CompressionPreset) {
        self.purpose = purpose
        self.preset = preset
    }

    var line: String {
        var parts = ["pdf diagnosis (\(purpose), \(preset.rawValue)): pages \(pageCount)"]
        let edges = pageLongEdges.sorted()
        if let first = edges.first, let last = edges.last {
            parts.append("page long edge median \(SafeNumber.int(edges[edges.count / 2])) pt (min \(SafeNumber.int(first)), max \(SafeNumber.int(last)))")
        }
        let scales = segments.map(\.scale)
        if let low = scales.min(), let high = scales.max() {
            let how = segments.count > 1 ? "run per segment" : (hasDocumentStructure ? "one run: bookmarks, links or forms" : "one run")
            parts.append(String(format: "page scale min %.2f / max %.2f, %d segment(s), %@", low, high, segments.count, how))
        }
        if images.isEmpty {
            parts.append("images 0")
        } else {
            let filters = Dictionary(grouping: images, by: \.filter).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
            let largest = images.max { $0.width * $0.height < $1.width * $1.height }!
            let dpis = images.map(\.dpiAtFullPage).sorted()
            parts.append("images \(images.count) (\(filters)), largest \(largest.width)x\(largest.height) px, "
                + "dpi if spanning the page min \(dpis.first!) / median \(dpis[dpis.count / 2]) / max \(dpis.last!)")
        }
        parts.append("original \(originalBytes) B")
        for pass in passes {
            var text = pass.bytes > 0 ? "pass \(pass.name) \(pass.bytes) B" : pass.name
            if let psnr = pass.psnr { text += String(format: " %.1f dB", psnr) }
            text += String(format: " %.1f s", pass.seconds)
            if !pass.accepted { text += " rejected" }
            parts.append(text)
        }
        parts.append("result: \(decision)")
        return parts.joined(separator: "; ")
    }

    /// One entry per page (the first `limit` pages): size, scale, largest image before and after the photo pass, sharpness.
    func pagesLine(limit: Int = 60) -> String {
        let shown = min(pageCount, limit)
        guard shown > 0 else { return "pdf diagnosis pages (\(purpose), \(preset.rawValue)): none" }
        func largest(_ list: [Image], page: Int) -> Image? {
            list.filter { $0.page == page }.max { $0.width * $0.height < $1.width * $1.height }
        }
        let entries = (1...shown).map { page -> String in
            var text = "p\(page)"
            if page <= pageLongEdges.count { text += " \(SafeNumber.int(pageLongEdges[page - 1])) pt" }
            if let segment = segments.first(where: { $0.first...$0.last ~= page }) { text += String(format: " scale %.2f", segment.scale) }
            if let before = largest(images, page: page) {
                text += " image \(before.width)x\(before.height)"
                if let after = largest(imagesAfterPhotoPass, page: page) { text += "->\(after.width)x\(after.height)" }
                text += " px \(before.filter)"
            }
            if protectedPages.contains(page) { text += " kept lossless" }
            if let psnr = pagePSNR[page] { text += String(format: " %.1f dB", psnr) }
            return text
        }
        let more = pageCount > shown ? "; … \(pageCount - shown) more pages" : ""
        return "pdf diagnosis pages (\(purpose), \(preset.rawValue)): " + entries.joined(separator: "; ") + more
    }

    /// The images on each page (also inside form objects), read from the PDF's structure without decoding them.
    static func images(in url: URL) -> [Image] {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return [] }
        let found = ImageCollector()
        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number), let dictionary = page.dictionary else { continue }
            let box = page.getBoxRect(.mediaBox)
            found.newPage()
            found.collect(from: dictionary, page: number, pageLongEdge: max(box.width, box.height), depth: 0)
        }
        return found.images
    }
}

private final class ImageCollector {
    var images: [PDFDiagnosis.Image] = []
    /// Forms looked into on the current page: each once, however often it is used (`newPage` starts over).
    private var forms = Set<Int>()

    func newPage() { forms.removeAll() }

    func collect(from owner: CGPDFDictionaryRef, page: Int, pageLongEdge: CGFloat, depth: Int) {
        var resources: CGPDFDictionaryRef?
        var xObjects: CGPDFDictionaryRef?
        guard depth < 4, images.count < 100_000,
              CGPDFDictionaryGetDictionary(owner, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return }
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image":
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(dictionary, "Width", &width)
                CGPDFDictionaryGetInteger(dictionary, "Height", &height)
                self.images.append(.init(page: page, width: PDFImageExtractor.dimension(width), height: PDFImageExtractor.dimension(height),
                                         filter: Self.filter(of: dictionary), pageLongEdge: pageLongEdge))
            case "Form":
                guard self.forms.insert(unsafeBitCast(stream, to: Int.self)).inserted else { return true }
                self.collect(from: dictionary, page: page, pageLongEdge: pageLongEdge, depth: depth + 1)
            default:
                break
            }
            return true
        }, nil)
    }

    /// The first compression filter of an image stream, e.g. DCTDecode (JPEG) or FlateDecode (lossless); "none" if unset.
    private static func filter(of dictionary: CGPDFDictionaryRef) -> String {
        var name: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(dictionary, "Filter", &name), let name { return String(cString: name) }
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Filter", &array), let array, CGPDFArrayGetName(array, 0, &name), let name {
            return String(cString: name)
        }
        return "none"
    }
}
