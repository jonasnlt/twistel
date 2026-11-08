import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The comparison as a PDF of its own, with text one can search: first what differs in numbers, then each pair of pages with differences: old, new, both on top of each other, and the words.
enum PDFComparisonReport {
    static let added = MarkColor(red: 0.08, green: 0.6, blue: 0.2)
    static let removed = MarkColor(red: 0.85, green: 0.12, blue: 0.12)
    private static let ink = MarkColor(red: 0.1, green: 0.1, blue: 0.1)
    private static let grey = MarkColor(red: 0.45, green: 0.45, blue: 0.45)
    private static let page = CGRect(x: 0, y: 0, width: 842, height: 595)
    private static let margin: CGFloat = 30

    /// In words, for the report and the window.
    static func summary(_ result: PDFComparison) -> [String] {
        let added = result.changes.filter { $0.kind == .added }.count, removed = result.changes.filter { $0.kind == .removed }.count, changed = result.changes.filter { $0.kind == .changed }.count
        var lines = [tr("Text: \(added) added, \(removed) removed, \(changed) changed", "Text: \(added) hinzugefügt, \(removed) entfernt, \(changed) geändert")]
        func list(_ pages: [Int]) -> String { pages.map { "\($0 + 1)" }.joined(separator: ", ") }
        if !result.removedPages.isEmpty { lines.append(tr("Pages only in the old file: \(list(result.removedPages))", "Seiten nur in der alten Datei: \(list(result.removedPages))")) }
        if !result.addedPages.isEmpty { lines.append(tr("Pages only in the new file: \(list(result.addedPages))", "Seiten nur in der neuen Datei: \(list(result.addedPages))")) }
        let visual = result.pairs.filter { !$0.regions.isEmpty && $0.old != nil && $0.new != nil }
        lines.append(visual.isEmpty ? tr("Pictures: no differences on the pages they have in common", "Bilder: keine Unterschiede auf den gemeinsamen Seiten") : tr("Pictures: differences on \(visual.count) of \(result.pairs.filter { $0.old != nil && $0.new != nil }.count) pages in common", "Bilder: Unterschiede auf \(visual.count) von \(result.pairs.filter { $0.old != nil && $0.new != nil }.count) gemeinsamen Seiten"))
        if !result.oldScanned.isEmpty || !result.newScanned.isEmpty {
            lines.append(tr("Scans were read by text recognition. Small differences in reading are ignored, and the pictures are compared with more tolerance.", "Scans wurden mit der Texterkennung gelesen. Kleine Lesefehler werden übergangen, und die Bilder werden großzügiger verglichen."))
        }
        if !result.unreadable.isEmpty { lines.append(tr("Not read, please check by eye: \(result.unreadable.joined(separator: ", "))", "Nicht gelesen, bitte selbst ansehen: \(result.unreadable.joined(separator: ", "))")) }
        return lines
    }

    static func write(_ result: PDFComparison, to destination: URL, progress: (Double) -> Void = { _ in }) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("twistel-compare-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: work) }
        let info: [CFString: Any] = [kCGPDFContextTitle: tr("Comparison of \(result.oldURL.lastPathComponent) and \(result.newURL.lastPathComponent)", "Vergleich von \(result.oldURL.lastPathComponent) mit \(result.newURL.lastPathComponent)"), kCGPDFContextCreator: AppIdentity.name]
        guard let context = CGContext(work as CFURL, mediaBox: nil, info as CFDictionary) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        begin(context)
        var y = page.height - margin
        y = write(tr("Comparison", "Vergleich"), size: 22, bold: true, color: ink, at: y, in: context)
        y -= 8
        y = write(tr("Old: \(result.oldURL.lastPathComponent) (\(result.oldPageCount) page\(result.oldPageCount == 1 ? "" : "s"))", "Alt: \(result.oldURL.lastPathComponent) (\(result.oldPageCount) \(result.oldPageCount == 1 ? "Seite" : "Seiten"))"), size: 12, color: ink, at: y, in: context)
        y = write(tr("New: \(result.newURL.lastPathComponent) (\(result.newPageCount) page\(result.newPageCount == 1 ? "" : "s"))", "Neu: \(result.newURL.lastPathComponent) (\(result.newPageCount) \(result.newPageCount == 1 ? "Seite" : "Seiten"))"), size: 12, color: ink, at: y, in: context)
        y -= 12
        for line in summary(result) { y = write(line, size: 12, color: ink, at: y, in: context) }
        y -= 12
        let same = result.pairs.filter { !result.hasDifferences($0) }
        if result.changes.isEmpty, result.pairs.allSatisfy({ !result.hasDifferences($0) }) {
            _ = write(tr("The two files show no differences.", "Die beiden Dateien zeigen keine Unterschiede."), size: 14, bold: true, color: added, at: y, in: context)
        } else if !same.isEmpty {
            y = write(tr("Pages without differences (old file): \(same.compactMap(\.old).map { "\($0 + 1)" }.joined(separator: ", "))", "Seiten ohne Unterschiede (alte Datei): \(same.compactMap(\.old).map { "\($0 + 1)" }.joined(separator: ", "))"), size: 11, color: grey, at: y, in: context)
            y -= 4
            y = write(tr("Red: only in the old file. Green: only in the new file. Orange frame: the pictures differ here.", "Rot: nur in der alten Datei. Grün: nur in der neuen Datei. Orangefarbener Rahmen: Hier unterscheiden sich die Bilder."), size: 11, color: grey, at: y, in: context)
        } else {
            y = write(tr("Red: only in the old file. Green: only in the new file. Orange frame: the pictures differ here.", "Rot: nur in der alten Datei. Grün: nur in der neuen Datei. Orangefarbener Rahmen: Hier unterscheiden sich die Bilder."), size: 11, color: grey, at: y, in: context)
        }
        context.endPDFPage()
        let different = result.pairs.filter { result.hasDifferences($0) }
        for (index, pair) in different.enumerated() {
            try Task.checkCancellation()
            try writePair(pair, of: result, in: context)
            progress(Double(index + 1) / Double(max(different.count, 1)) * 0.95)
        }
        context.closePDF()
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: work, to: destination)
        progress(1)
    }

    private static func begin(_ context: CGContext) {
        var box = page
        context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
    }

    static func title(of pair: PDFComparison.PagePair) -> String {
        switch (pair.old, pair.new) {
        case let (old?, new?): return tr("Old page \(old + 1), new page \(new + 1)", "Alte Seite \(old + 1), neue Seite \(new + 1)")
        case let (old?, nil): return tr("Old page \(old + 1): not in the new file", "Alte Seite \(old + 1): nicht in der neuen Datei")
        case let (nil, new?): return tr("New page \(new + 1): not in the old file", "Neue Seite \(new + 1): nicht in der alten Datei")
        default: return ""
        }
    }

    private static func writePair(_ pair: PDFComparison.PagePair, of result: PDFComparison, in context: CGContext) throws {
        let pictures = try result.pictures(of: pair, dpi: 130)
        let changes = result.changes(on: pair)
        begin(context)
        var y = page.height - margin
        y = write(title(of: pair), size: 14, bold: true, color: ink, at: y, in: context)
        y -= 4
        let gap: CGFloat = 12, width = (page.width - margin * 2 - gap * 2) / 3
        let oldBoxes = changes.flatMap(\.oldPlaces).filter { $0.page == pair.old }.map(\.box)
        let newBoxes = changes.flatMap(\.newPlaces).filter { $0.page == pair.new }.map(\.box)
        var x = margin
        let panelTop = y - 12
        var lowest = panelTop
        func panel(_ caption: String, _ image: CGImage?, boxes: [CGRect], color: MarkColor, frames: [CGRect] = []) {
            drawText(caption, size: 9, color: grey, at: CGPoint(x: x, y: y - 10), in: context)
            if let image {
                let height = min(width * CGFloat(image.height) / CGFloat(image.width), panelTop - margin - 95)
                let shownWidth = height * CGFloat(image.width) / CGFloat(image.height)
                let rect = CGRect(x: x, y: panelTop - height, width: shownWidth, height: height)
                if let jpeg = jpeg(image) { context.draw(jpeg, in: rect) }
                context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
                context.setLineWidth(0.5)
                context.stroke(rect)
                func onPanel(_ box: CGRect) -> CGRect {
                    CGRect(x: rect.minX + box.minX * rect.width, y: rect.maxY - box.maxY * rect.height, width: box.width * rect.width, height: box.height * rect.height)
                }
                context.setFillColor(color.cgColor(alpha: 0.35))
                for box in boxes { context.fill(onPanel(box).insetBy(dx: -1, dy: -1)) }
                context.setStrokeColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
                context.setLineWidth(1)
                for frame in frames { context.stroke(onPanel(frame).insetBy(dx: -2, dy: -2)) }
                lowest = min(lowest, rect.minY)
            }
            x += width + gap
        }
        panel(tr("Old", "Alt"), pictures.old, boxes: oldBoxes, color: removed)
        panel(tr("New", "Neu"), pictures.new, boxes: newBoxes, color: added)
        if pictures.overlay != nil { panel(tr("Both on top of each other", "Beide übereinander"), pictures.overlay, boxes: [], color: added, frames: pair.regions) }
        var below = lowest - 8
        func line(_ change: PDFComparison.Change) {
            if below < margin {
                context.endPDFPage()
                begin(context)
                below = write(tr("\(title(of: pair)), continued", "\(title(of: pair)), Fortsetzung"), size: 12, bold: true, color: ink, at: page.height - margin, in: context) - 6
            }
            if !change.oldText.isEmpty { below = write("− \(change.oldText)", size: 10, color: removed, at: below, in: context) }
            if below < margin {
                context.endPDFPage()
                begin(context)
                below = write(tr("\(title(of: pair)), continued", "\(title(of: pair)), Fortsetzung"), size: 12, bold: true, color: ink, at: page.height - margin, in: context) - 6
            }
            if !change.newText.isEmpty { below = write("+ \(change.newText)", size: 10, color: added, at: below, in: context) }
            below -= 3
        }
        if changes.isEmpty, pair.old != nil, pair.new != nil {
            below = write(tr("The text is the same; the pictures differ in \(pair.regions.count) place\(pair.regions.count == 1 ? "" : "s").", "Der Text ist gleich; die Bilder unterscheiden sich an \(pair.regions.count) \(pair.regions.count == 1 ? "Stelle" : "Stellen")."), size: 10, color: grey, at: below, in: context)
        }
        for change in changes { line(change) }
        context.endPDFPage()
    }

    private static func jpeg(_ image: CGImage) -> CGImage? {
        guard let data = SocialMedia.jpeg(image, quality: 0.85), let provider = CGDataProvider(data: data as CFData) else { return image }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) ?? image
    }

    private static func attributed(_ text: String, size: CGFloat, bold: Bool, color: MarkColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: MarkPainter.font(size: size, bold: bold), .foregroundColor: color.cgColor()])
    }

    private static func drawText(_ text: String, size: CGFloat, color: MarkColor, at point: CGPoint, in context: CGContext) {
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed(text, size: size, bold: false, color: color)), context)
    }

    /// Top of the text at `y`, broken to the width of the page; returns where the next line goes.
    @discardableResult
    private static func write(_ text: String, size: CGFloat, bold: Bool = false, color: MarkColor, at y: CGFloat, in context: CGContext) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, size: size, bold: bold, color: color))
        let width = page.width - margin * 2
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let box = CGRect(x: margin, y: y - ceil(fitted.height), width: width, height: ceil(fitted.height))
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil), context)
        return box.minY - 2
    }
}
