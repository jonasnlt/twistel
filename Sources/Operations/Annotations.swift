import AppKit
import CoreText
import Foundation
import ImageIO

/// A colour that can be stored and sent between threads.
struct MarkColor: Codable, Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let red = MarkColor(red: 0.9, green: 0.1, blue: 0.1)
    static let yellow = MarkColor(red: 1, green: 0.9, blue: 0)

    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    func nsColor(alpha: CGFloat = 1) -> NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    /// Whether white writing stands out on it.
    var isLight: Bool { 0.3 * red + 0.59 * green + 0.11 * blue > 0.65 }
}

/// A picture on a page, kept as the file it came from. Compared and stored by its bytes; drawn from the image made of them once.
struct MarkPicture: Codable, Equatable, @unchecked Sendable {
    let data: Data
    let image: CGImage?

    init(data: Data) {
        self.data = data
        image = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    init(from decoder: Decoder) throws { self.init(data: try decoder.singleValueContainer().decode(Data.self)) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }

    static func == (a: MarkPicture, b: MarkPicture) -> Bool { a.data == b.data }
}

/// One thing drawn on a picture or a page of a PDF. Places are in the picture's pixels or the page's points as it is seen, origin top left.
struct Mark: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, CaseIterable, Codable, Sendable {
        case arrow, text, rectangle, ellipse, pen, highlighter, number, magnifier
        /// A picture with transparency, such as a signature.
        case picture
    }

    var id = UUID()
    var kind: Kind
    var page = 0
    /// Text, rectangle, ellipse, number, magnifier.
    var frame = CGRect.zero
    /// Arrow: start and end. Pen and highlighter: the way drawn.
    var points: [CGPoint] = []
    var color = MarkColor.red
    var lineWidth: CGFloat = 3
    var fontSize: CGFloat = 16
    var text = ""
    var number = 0
    var zoom: CGFloat = 2
    var picture: MarkPicture?

    /// See-through enough that the writing under a highlighter stays readable.
    static let highlighterAlpha: CGFloat = 0.4

    init(kind: Kind, page: Int = 0, frame: CGRect = .zero, points: [CGPoint] = [], color: MarkColor = .red, lineWidth: CGFloat = 3, fontSize: CGFloat = 16, text: String = "", number: Int = 0, zoom: CGFloat = 2) {
        self.kind = kind
        self.page = page
        self.frame = frame
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.text = text
        self.number = number
        self.zoom = zoom
    }

    /// The test access writes marks by hand: only `kind` is needed.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try values.decode(Kind.self, forKey: .kind))
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? id
        page = try values.decodeIfPresent(Int.self, forKey: .page) ?? page
        frame = try values.decodeIfPresent(CGRect.self, forKey: .frame) ?? frame
        points = try values.decodeIfPresent([CGPoint].self, forKey: .points) ?? points
        color = try values.decodeIfPresent(MarkColor.self, forKey: .color) ?? color
        lineWidth = try values.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? lineWidth
        fontSize = try values.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? fontSize
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? text
        number = try values.decodeIfPresent(Int.self, forKey: .number) ?? number
        zoom = try values.decodeIfPresent(CGFloat.self, forKey: .zoom) ?? zoom
        picture = try values.decodeIfPresent(MarkPicture.self, forKey: .picture)
    }

    var usesPoints: Bool { kind == .arrow || kind == .pen || kind == .highlighter }

    /// The box the handles sit on.
    var bounds: CGRect {
        guard usesPoints else { return frame }
        guard let first = points.first else { return .zero }
        return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// All that is painted, with the width of the line.
    var paintedBounds: CGRect { bounds.insetBy(dx: -lineWidth - arrowHead, dy: -lineWidth - arrowHead) }

    var arrowHead: CGFloat { kind == .arrow ? MarkPainter.arrowHeadLength(lineWidth: lineWidth) : 0 }

    func moved(by delta: CGSize) -> Mark {
        var copy = self
        copy.frame = frame.offsetBy(dx: delta.width, dy: delta.height)
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }

    /// Points where it can be taken to change its size.
    var handles: [CGPoint] {
        if kind == .arrow { return points }
        let box = bounds
        return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    /// Handle `index` taken to `point`, with the opposite corner staying where it is.
    func resized(handle index: Int, to point: CGPoint, minimum: CGFloat) -> Mark {
        var copy = self
        if kind == .arrow {
            copy.points[index] = point
            return copy
        }
        let box = bounds
        let fixed = handles[(index + 2) % 4]
        var width = max(abs(point.x - fixed.x), minimum), height = max(abs(point.y - fixed.y), minimum)
        if kind == .number || kind == .magnifier { width = max(width, height); height = width }
        if kind == .picture, box.height > 0 {
            // Keeps its shape, however the corner is pulled.
            let shape = box.width / box.height
            width = max(width, height * shape)
            height = width / shape
        }
        let left = index == 0 || index == 3, top = index == 0 || index == 1
        var new = CGRect(x: left ? fixed.x - width : fixed.x, y: top ? fixed.y - height : fixed.y, width: width, height: height)
        if kind == .text {
            new.size.height = MarkPainter.textSize(text, fontSize: fontSize, width: width).height
            new.origin.y = box.minY
        }
        if usesPoints {
            let sx = box.width > 0 ? new.width / box.width : 1, sy = box.height > 0 ? new.height / box.height : 1
            copy.points = points.map { CGPoint(x: new.minX + ($0.x - box.minX) * sx, y: new.minY + ($0.y - box.minY) * sy) }
        } else {
            copy.frame = new
        }
        return copy
    }

    /// Whether a click at `point` means this. Rectangles and ellipses only on their line: what is inside them can still be clicked.
    func isHit(by point: CGPoint, tolerance: CGFloat) -> Bool {
        let reach = max(tolerance, lineWidth / 2 + 1)
        switch kind {
        case .arrow, .pen, .highlighter:
            if points.count == 1 { return hypot(points[0].x - point.x, points[0].y - point.y) <= reach }
            return zip(points, points.dropFirst()).contains { Self.distance(point, from: $0, to: $1) <= reach }
        case .text, .number, .magnifier, .picture:
            return frame.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point)
        case .rectangle:
            return frame.insetBy(dx: -reach, dy: -reach).contains(point) && !frame.insetBy(dx: reach, dy: reach).contains(point)
        case .ellipse:
            let a = max(frame.width / 2, 1), b = max(frame.height / 2, 1)
            let radial = hypot((point.x - frame.midX) / a, (point.y - frame.midY) / b)
            return abs(radial - 1) * min(a, b) <= reach
        }
    }

    private static func distance(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

/// Paints marks: in the window, on a saved picture and on a burned-in page, always the same way. The context's origin is top left and its unit that of the marks.
enum MarkPainter {
    /// The picture under the marks, for a magnifier.
    struct Source: @unchecked Sendable {
        var picture: CGImage
        /// The picture's size in the unit of the marks.
        var size: CGSize
    }

    static func font(size: CGFloat, bold: Bool = false) -> CTFont {
        CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
    }

    /// The arrow head as Apple draws it on a comment in a PDF: measured, so that the window, burned-in pages and comments look the same.
    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat { lineWidth * 5 }

    /// The line distance of a text comment in a PDF, also measured.
    static let lineHeight: CGFloat = 1.06

    private static func attributed(_ text: String, fontSize: CGFloat, color: MarkColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = fontSize * lineHeight
        paragraph.maximumLineHeight = fontSize * lineHeight
        return NSAttributedString(string: text, attributes: [.font: font(size: fontSize), .foregroundColor: color.cgColor(), .paragraphStyle: paragraph])
    }

    /// What a text needs, broken at `width`.
    static func textSize(_ text: String, fontSize: CGFloat, width: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text.isEmpty ? " " : text, fontSize: fontSize, color: .red))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(size.width) + 1, height: ceil(size.height) + 1)
    }

    static func draw(_ mark: Mark, in context: CGContext, source: Source?) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(mark.lineWidth)
        context.setStrokeColor(mark.color.cgColor())
        context.setFillColor(mark.color.cgColor())
        switch mark.kind {
        case .arrow: drawArrow(mark, in: context)
        case .rectangle:
            context.setLineJoin(.miter)
            context.stroke(mark.frame.insetBy(dx: mark.lineWidth / 2, dy: mark.lineWidth / 2))
        case .ellipse: context.strokeEllipse(in: mark.frame.insetBy(dx: mark.lineWidth / 2, dy: mark.lineWidth / 2))
        case .pen, .highlighter:
            if mark.kind == .highlighter { context.setStrokeColor(mark.color.cgColor(alpha: Mark.highlighterAlpha)) }
            guard let first = mark.points.first else { return }
            context.move(to: first)
            // One point alone: a dot.
            for point in mark.points.count == 1 ? mark.points : Array(mark.points.dropFirst()) { context.addLine(to: point) }
            context.strokePath()
        case .text: drawText(mark, in: context)
        case .number: drawNumber(mark, in: context)
        case .magnifier: drawMagnifier(mark, in: context, source: source)
        case .picture:
            guard let image = mark.picture?.image else { return }
            context.interpolationQuality = .high
            context.translateBy(x: mark.frame.minX, y: mark.frame.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: mark.frame.size))
        }
    }

    private static func drawArrow(_ mark: Mark, in context: CGContext) {
        guard mark.points.count == 2 else { return }
        let start = mark.points[0], end = mark.points[1]
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return }
        // The tip reaches one line width beyond the end point.
        let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length
        let tip = CGPoint(x: end.x + ux * mark.lineWidth, y: end.y + uy * mark.lineWidth)
        let head = mark.arrowHead
        let base = CGPoint(x: tip.x - ux * head, y: tip.y - uy * head)
        context.setLineCap(.butt)
        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()
        let half = mark.lineWidth * 2.2
        context.move(to: tip)
        context.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        context.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        context.closePath()
        context.fillPath()
    }

    private static func drawText(_ mark: Mark, in context: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(attributed(mark.text, fontSize: mark.fontSize, color: mark.color))
        let box = CGRect(origin: .zero, size: mark.frame.size)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box, transform: nil), nil)
        context.translateBy(x: mark.frame.minX, y: mark.frame.maxY)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
    }

    /// The digits as shapes, not as writing: a file then needs no font for them, and a search does not find stray numbers.
    private static func drawNumber(_ mark: Mark, in context: CGContext) {
        context.fillEllipse(in: mark.frame)
        let text = "\(mark.number)"
        let size = mark.frame.height * (text.count > 2 ? 0.42 : text.count == 2 ? 0.5 : 0.6)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(size: size, bold: true)]))
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        context.translateBy(x: mark.frame.midX - bounds.midX, y: mark.frame.midY + bounds.midY)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(mark.color.isLight ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName as String] else { continue }
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), places = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &places)
            for index in 0..<count {
                guard let path = CTFontCreatePathForGlyph(runFont as! CTFont, glyphs[index], nil) else { continue }
                context.saveGState()
                context.translateBy(x: places[index].x, y: places[index].y)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
            }
        }
    }

    /// What lies under it, enlarged around its middle, in a circle. Marks are not in it: it shows the picture itself.
    private static func drawMagnifier(_ mark: Mark, in context: CGContext, source: Source?) {
        let circle = mark.frame.insetBy(dx: mark.lineWidth / 2, dy: mark.lineWidth / 2)
        if let source {
            context.saveGState()
            context.addEllipse(in: circle)
            context.clip()
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(circle)
            let width = mark.frame.width / mark.zoom, height = mark.frame.height / mark.zoom
            let shown = CGRect(x: mark.frame.midX - width / 2, y: mark.frame.midY - height / 2, width: width, height: height)
            let inside = shown.intersection(CGRect(origin: .zero, size: source.size))
            let scale = CGFloat(source.picture.width) / max(source.size.width, 1)
            let pixels = CGRect(x: inside.minX * scale, y: inside.minY * scale, width: inside.width * scale, height: inside.height * scale).integral
            if !inside.isEmpty, let part = source.picture.cropping(to: pixels) {
                // The part as cropped to whole pixels, so that it does not shift.
                let exact = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
                let target = CGRect(x: mark.frame.midX + (exact.minX - mark.frame.midX) * mark.zoom, y: mark.frame.midY + (exact.minY - mark.frame.midY) * mark.zoom,
                                    width: exact.width * mark.zoom, height: exact.height * mark.zoom)
                context.interpolationQuality = .high
                context.translateBy(x: target.minX, y: target.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(part, in: CGRect(origin: .zero, size: target.size))
            }
            context.restoreGState()
        }
        context.strokeEllipse(in: circle)
    }
}
