import AppKit
import PDFKit
import Vision

/// Reads QR codes in images and PDF pages with Apple Vision, on this Mac. The content is only shown and copied;
/// links are never opened.
enum QRReader {
    /// PDF pages are looked at with this resolution, enough for small codes.
    static let pageDPI: CGFloat = 200

    struct Code: Equatable, Identifiable {
        let id = UUID()
        /// 1-based page for PDFs, nil for images.
        let page: Int?
        let text: String
        /// Not a code: a message that this page could not be looked at.
        var isNote = false

        static func == (lhs: Code, rhs: Code) -> Bool { lhs.page == rhs.page && lhs.text == rhs.text }
    }

    static func codes(in image: CGImage) throws -> [String] {
        // Only these two facts leave the closure: what Vision found is not safe to hand over otherwise.
        struct Found: @unchecked Sendable { let results: [VNBarcodeObservation] }
        let found = try VisionLimit.blocking(on: image) { () throws -> Found in
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return Found(results: request.results ?? [])
        }
        var seen = Set<String>()
        // Top to bottom, then left to right, each content once.
        let sorted = found.results.sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.05 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
        return sorted.compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }

    /// All codes of an image file or of every page of a PDF.
    static func codes(in url: URL) throws -> [Code] {
        if FileFormat.detect(url) == .pdf {
            guard let document = PDFDocument(url: url) else { throw AppError.unreadable(url) }
            guard !document.isLocked else { throw AppError.invalidInput(tr("\(url.lastPathComponent) is password protected.", "\(url.lastPathComponent) ist mit einem Passwort geschützt.")) }
            var found: [Code] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index), let image = PDFRenderer.render(page: page, dpi: pageDPI) else { continue }
                do {
                    found += try codes(in: image).map { Code(page: index + 1, text: $0) }
                } catch is VisionLimit.NoAnswer {
                    found.append(Code(page: index + 1, text: tr("This page could not be read: Apple's recognition did not answer.", "Diese Seite konnte nicht gelesen werden: Apples Erkennung hat nicht geantwortet."), isNote: true))
                }
            }
            return found
        }
        return try codes(in: try ImageIOBridge.load(url)).map { Code(page: nil, text: $0) }
    }

    /// Puts the texts on the clipboard, one per line.
    static func copy(_ texts: [String], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(texts.joined(separator: "\n"), forType: .string)
    }
}
