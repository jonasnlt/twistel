import AppKit
import CoreImage
import CoreText
import Foundation
import ImageIO
import Security

/// A visible signature: a picture with transparency, only ever kept on this Mac.
struct SavedSignature: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var png: Data
    var created = Date()
}

/// One point of a line drawn by hand: where, and when (seconds, from any start).
struct InkPoint: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var time: TimeInterval
}

/// Where signatures are kept.
protocol SignatureVault: Sendable {
    func all() throws -> [SavedSignature]
    func save(_ signature: SavedSignature) throws
    func delete(_ id: UUID) throws
}

/// In the login keychain, which is where macOS keeps such data: encrypted on disk, locked with the Mac, opened only for this app. Not synchronized to iCloud, and in no backup as a loose file.
struct KeychainSignatureVault: SignatureVault {
    static let service = "\(AppIdentity.bundleID).signature"
    let items: KeychainItems

    /// `keychain`: a keychain file of its own (tests); nil is the login keychain.
    init(service: String = Self.service, keychain: SecKeychain? = nil) {
        items = KeychainItems(service: service, keychain: keychain)
    }

    /// The list first, then each signature on its own (asking for the data of all at once is refused, -50). One that cannot be read
    /// is left out; only a list that cannot be read at all is an error.
    func all() throws -> [SavedSignature] {
        let (status, accounts) = items.accounts()
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw AppError.invalidInput(tr("The keychain did not open (\(status)). Signatures can still be made for this window, but not kept.", "Der Schlüsselbund hat sich nicht geöffnet (\(status)). Unterschriften lassen sich für dieses Fenster trotzdem erstellen, aber nicht behalten.")) }
        var list: [SavedSignature] = []
        for account in accounts {
            let (read, data) = items.data(account: account)
            guard read == errSecSuccess, let data, let signature = try? JSONDecoder().decode(SavedSignature.self, from: data) else {
                DiagnosticLog.log("keychain: a signature could not be read (\(read))")
                continue
            }
            list.append(signature)
        }
        return list.sorted { $0.created < $1.created }
    }

    /// New, or in place of the one with the same id (a new name, a new picture).
    func save(_ signature: SavedSignature) throws {
        let data = try JSONEncoder().encode(signature)
        var status = items.add(account: signature.id.uuidString, data: data, label: "\(AppIdentity.name) signature")
        if status == errSecDuplicateItem { status = items.update(account: signature.id.uuidString, data: data) }
        guard status == errSecSuccess else { throw AppError.invalidInput(tr("The keychain did not take the signature (\(status)). It can still be used in this window.", "Der Schlüsselbund hat die Unterschrift nicht übernommen (\(status)). In diesem Fenster kannst du sie trotzdem verwenden.")) }
    }

    func delete(_ id: UUID) throws {
        let status = items.delete(account: id.uuidString)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.invalidInput(tr("The keychain did not delete the signature (\(status)).", "Der Schlüsselbund hat die Unterschrift nicht gelöscht (\(status)).")) }
    }
}

/// Generic-password items of one service, asked for the way the file keychain of macOS answers an app signed ad hoc: the list
/// with attributes only, then each item's data on its own. Asking for the data of all items at once is refused (errSecParam, -50), also
/// for the app's own items.
struct KeychainItems: @unchecked Sendable {
    let service: String
    /// A keychain file of its own (tests); nil: the login keychain.
    var keychain: SecKeychain?

    private func query(account: String? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrSynchronizable: false]
        if let account { query[kSecAttrAccount] = account }
        if let keychain { query[kSecMatchSearchList] = [keychain] }
        return query
    }

    var listQuery: [CFString: Any] {
        query().merging([kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true]) { $1 }
    }

    func dataQuery(account: String) -> [CFString: Any] {
        query(account: account).merging([kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true]) { $1 }
    }

    /// The accounts (for signatures: their ids), never their data.
    func accounts() -> (OSStatus, [String]) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &result)
        return (status, ((result as? [[CFString: Any]]) ?? []).compactMap { $0[kSecAttrAccount] as? String })
    }

    func data(account: String) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(dataQuery(account: account) as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(account: String, data: Data, label: String) -> OSStatus {
        var add = query(account: account)
        add[kSecMatchSearchList] = nil
        if let keychain { add[kSecUseKeychain] = keychain }
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel] = label
        return SecItemAdd(add as CFDictionary, nil)
    }

    func update(account: String, data: Data) -> OSStatus {
        SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData: data] as CFDictionary)
    }

    func delete(account: String) -> OSStatus {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

/// How a signature comes to be.
enum SignatureMaker {
    /// Fonts of this Mac that look written by hand, in the order offered; those that exist.
    static var handwritingFonts: [String] {
        ["SnellRoundhand", "BradleyHandITCTT-Bold", "SavoyeLetPlain", "BrushScriptMT", "Zapfino", "Noteworthy-Light"].filter { CTFontCopyPostScriptName(CTFontCreateWithName($0 as CFString, 20, nil)) as String == $0 }
    }

    static func fontTitle(_ name: String) -> String {
        CTFontCopyDisplayName(CTFontCreateWithName(name as CFString, 20, nil)) as String
    }

    /// Enough for a signature several centimetres wide, printed.
    private static let height: CGFloat = 400

    /// Strokes in any unit, at a line width in the same unit: the picture of them, with air around, cut to what is drawn.
    /// Points without times: the same width everywhere.
    static func picture(strokes: [[CGPoint]], lineWidth: CGFloat, color: MarkColor) -> CGImage? {
        picture(strokes: strokes.map { $0.map { InkPoint(x: $0.x, y: $0.y, time: 0) } }, lineWidth: lineWidth, color: color)
    }

    static func picture(strokes: [[InkPoint]], lineWidth: CGFloat, color: MarkColor) -> CGImage? {
        let lines = strokes.map { inkSamples($0, lineWidth: lineWidth) }.filter { !$0.isEmpty }
        guard let first = lines.first?.first else { return nil }
        // The box of the line itself: the curve may swing a little beyond the points.
        var box = CGRect(origin: first.point, size: .zero)
        for sample in lines.joined() { box = box.union(CGRect(x: sample.point.x - sample.width / 2, y: sample.point.y - sample.width / 2, width: sample.width, height: sample.width)) }
        box = box.insetBy(dx: -lineWidth, dy: -lineWidth)
        let scale = min(height / max(box.height, 1), 1600 / max(box.width, 1))
        let width = Int(ceil(box.width * scale)), tall = Int(ceil(box.height * scale))
        guard width > 0, tall > 0, let context = CGContext(data: nil, width: width, height: tall, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -box.minX, y: -box.maxY)
        context.setFillColor(color.cgColor())
        for line in lines { fill(line, in: context) }
        return context.makeImage()
    }

    /// A drawn line as a pen leaves it, into a context whose fill colour is the ink.
    static func draw(_ stroke: [InkPoint], lineWidth: CGFloat, in context: CGContext) {
        fill(inkSamples(stroke, lineWidth: lineWidth), in: context)
    }

    /// Round dots along the line, joined by their tangents, all turning the same way: filled once, they are one shape without seams.
    private static func fill(_ samples: [InkSample], in context: CGContext) {
        guard !samples.isEmpty else { return }
        let path = CGMutablePath()
        for (index, sample) in samples.enumerated() {
            path.addArc(center: sample.point, radius: sample.width / 2, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            path.closeSubpath()
            guard index > 0 else { continue }
            let before = samples[index - 1]
            let dx = sample.point.x - before.point.x, dy = sample.point.y - before.point.y, length = hypot(dx, dy)
            guard length > 0 else { continue }
            let nx = -dy / length, ny = dx / length
            var corners = [CGPoint(x: before.point.x + nx * before.width / 2, y: before.point.y + ny * before.width / 2),
                           CGPoint(x: sample.point.x + nx * sample.width / 2, y: sample.point.y + ny * sample.width / 2),
                           CGPoint(x: sample.point.x - nx * sample.width / 2, y: sample.point.y - ny * sample.width / 2),
                           CGPoint(x: before.point.x - nx * before.width / 2, y: before.point.y - ny * before.width / 2)]
            var area: CGFloat = 0
            for corner in 0..<4 { area += corners[corner].x * corners[(corner + 1) % 4].y - corners[(corner + 1) % 4].x * corners[corner].y }
            if area < 0 { corners.reverse() }
            path.addLines(between: corners)
            path.closeSubpath()
        }
        context.addPath(path)
        context.fillPath()
    }

    /// A point of the line on its way: where, and how wide.
    struct InkSample: Equatable {
        var point: CGPoint
        var width: CGFloat
    }

    /// Slow is a little wider than fast, as with a pen: from 1.25 times the line width when still to 0.75 from this speed (units per second) on.
    static let fastInk: CGFloat = 1200

    /// The hand's points, made into a line: a little calmer where they lie close, then a curve through all of them
    /// (centripetal Catmull-Rom: no loops or spikes where points lie unevenly), sampled every quarter line width. The first and the last point stay where they were.
    static func inkSamples(_ stroke: [InkPoint], lineWidth: CGFloat) -> [InkSample] {
        var points: [InkPoint] = []
        for point in stroke {
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) < lineWidth * 0.1 { continue }
            points.append(point)
        }
        if points.count > 1, let last = stroke.last, points.last != last {
            points[points.count - 1] = last
        }
        guard let first = points.first else { return [] }
        guard points.count > 1 else { return [InkSample(point: CGPoint(x: first.x, y: first.y), width: lineWidth * 1.25)] }
        // Only close points are calmed (the hand trembles there); far apart, each one is meant.
        var calm = points
        if points.count > 2 {
            for index in 1..<(points.count - 1) {
                let near = max(hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y), hypot(points[index + 1].x - points[index].x, points[index + 1].y - points[index].y))
                let share = 0.25 * max(0, 1 - near / (lineWidth * 2))
                calm[index].x += share * (points[index - 1].x + points[index + 1].x - 2 * points[index].x)
                calm[index].y += share * (points[index - 1].y + points[index + 1].y - 2 * points[index].y)
            }
        }
        let widths = penWidths(calm, lineWidth: lineWidth)
        let spots = calm.map { CGPoint(x: $0.x, y: $0.y) }
        var samples = [InkSample(point: spots[0], width: widths[0])]
        for index in 0..<(spots.count - 1) {
            let p1 = spots[index], p2 = spots[index + 1]
            // Beyond the ends, the line goes on straight.
            let p0 = index > 0 ? spots[index - 1] : CGPoint(x: 2 * p1.x - p2.x, y: 2 * p1.y - p2.y)
            let p3 = index + 2 < spots.count ? spots[index + 2] : CGPoint(x: 2 * p2.x - p1.x, y: 2 * p2.y - p1.y)
            let steps = max(1, Int(ceil(hypot(p2.x - p1.x, p2.y - p1.y) / (lineWidth * 0.25))))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                samples.append(InkSample(point: catmullRom(p0, p1, p2, p3, t), width: widths[index] + (widths[index + 1] - widths[index]) * t))
            }
        }
        return samples
    }

    /// Width at each point from the speed of the hand there, changing gently. Without times, the line width everywhere.
    private static func penWidths(_ points: [InkPoint], lineWidth: CGFloat) -> [CGFloat] {
        let count = points.count
        var factors = [CGFloat](repeating: 1, count: count)
        guard let start = points.first?.time, let end = points.last?.time, end > start else { return factors.map { $0 * lineWidth } }
        for index in 0..<count {
            let before = points[max(0, index - 1)], after = points[min(count - 1, index + 1)]
            let seconds = after.time - before.time
            guard seconds > 0 else { continue }
            let speed = hypot(after.x - before.x, after.y - before.y) / CGFloat(seconds)
            factors[index] = 1.25 - 0.5 * min(1, speed / fastInk)
        }
        // Averaged over the neighbours, so that one quick twitch does not make a notch.
        let calm = (0..<count).map { index -> CGFloat in
            let near = factors[max(0, index - 3)...min(count - 1, index + 3)]
            return near.reduce(0, +) / CGFloat(near.count)
        }
        return calm.map { $0 * lineWidth }
    }

    /// Centripetal Catmull-Rom between p1 and p2 (Barry and Goldman's form).
    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(pow(hypot(b.x - a.x, b.y - a.y), 0.5), 1e-4) }
        func mix(_ a: CGPoint, _ b: CGPoint, _ from: CGFloat, _ to: CGFloat, _ at: CGFloat) -> CGPoint {
            let share = (at - from) / (to - from)
            return CGPoint(x: a.x + (b.x - a.x) * share, y: a.y + (b.y - a.y) * share)
        }
        let t0: CGFloat = 0, t1 = t0 + knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
        let u = t1 + (t2 - t1) * t
        let a1 = mix(p0, p1, t0, t1, u), a2 = mix(p1, p2, t1, t2, u), a3 = mix(p2, p3, t2, t3, u)
        let b1 = mix(a1, a2, t0, t2, u), b2 = mix(a2, a3, t1, t3, u)
        return mix(b1, b2, t1, t2, u)
    }

    /// A typed name in a handwriting font.
    static func picture(name: String, font fontName: String, color: MarkColor) -> CGImage? {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let font = CTFontCreateWithName(fontName as CFString, height * 0.6, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color.cgColor()]))
        // Handwriting reaches far beyond its own metrics: the shapes count.
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let margin: CGFloat = 8
        let width = Int(ceil(bounds.width + margin * 2)), tall = Int(ceil(bounds.height + margin * 2))
        guard width > 0, tall > 0, let context = CGContext(data: nil, width: width, height: tall, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.textPosition = CGPoint(x: margin - bounds.minX, y: margin - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    /// A signature on paper, photographed: paper out, line kept, in the colour of ink chosen (nil: the ink's own).
    /// `sensitivity`: 0 keeps only clear lines, 1 also very faint ones. See `SignaturePhoto`.
    static func picture(photo: CGImage, color: MarkColor?, sensitivity: Double = 0.5) throws -> CGImage {
        try SignaturePhoto(photo).cut(sensitivity: sensitivity, color: color)
    }

    static let black = MarkColor(red: 0, green: 0, blue: 0)

    /// The same line in another ink, at once: only the colour changes, where the line is and how solid stay.
    static func tinted(_ shape: CGImage, color: MarkColor) -> CGImage? {
        let rect = CGRect(x: 0, y: 0, width: shape.width, height: shape.height)
        guard let context = CGContext(data: nil, width: shape.width, height: shape.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(shape, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor())
        context.fill(rect)
        return context.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Measuring and cutting out photos, on a queue of its own and one at a time. A request replaced by a newer one is skipped, and `stop` drops all.
/// Each move of the slider used to start a cut of its own (about a second each in the debug build) on the threads Swift shares with all other work;
/// dozens of them held up saving for 31 s and opening the next window for 45 s.
final class PhotoCutter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "signature-photo", qos: .userInitiated)
    private let lock = NSLock()
    private var latest = 0

    private func isLatest(_ request: Int) -> Bool { lock.withLock { request == latest } }

    /// `done` on the main thread, and only for the latest request.
    func submit<Value>(_ work: @escaping () throws -> Value, done: @escaping @MainActor (Result<Value, Error>) -> Void) {
        let request = lock.withLock { latest += 1; return latest }
        queue.async { [self] in
            guard isLatest(request) else { return }
            let result = Result { try work() }
            guard isLatest(request) else { return }
            DispatchQueue.main.async {
                guard self.isLatest(request) else { return }
                MainActor.assumeIsolated { done(result) }
            }
        }
    }

    /// Nothing waiting runs, and nothing running is shown.
    func stop() {
        lock.withLock { latest += 1 }
    }

    #if DEBUG
    /// For tests: returns when all requests so far are through.
    func drain() { queue.sync {} }
    #endif
}

/// A photo of a signature on paper, measured once; cut out at any sensitivity without measuring again (the slider in the window).
///
/// The paper: the photo with every dark line thinner than a few millimetres closed over (the brightest value nearby, then the darkest of those).
/// Uneven light, soft and hard shadows and a table at the edge are wide and stay part of the paper; a pen line is not.
/// Each pixel's darkness is measured against that paper. Lines are kept from clearly dark pixels on, and followed into faint ones as long as they
/// are connected (a pale or skipping pen stays one line). Parts much smaller than the signature are dirt, unless they lie by it (the dot on an i);
/// parts at the edge of the photo go when there is anything else.
final class SignaturePhoto: @unchecked Sendable {
    let width: Int
    let height: Int
    /// 0 is the paper, 1 black; never changed after measuring.
    private let darkness: [Float]
    private let colors: [UInt8]
    /// How dark plain paper looks here (grain, noise of the camera).
    private let grain: Float

    /// Large enough for print, small enough that the slider answers quickly.
    static let maxSide = 2000

    init(_ photo: CGImage) throws {
        let source = max(photo.width, photo.height) > Self.maxSide ? ImageIOBridge.resized(photo, longEdge: Self.maxSide) : photo
        let input = CIImage(cgImage: source)
        let calm = input.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: input.extent)
        let radius = max(4, Double(max(source.width, source.height)) / 150)
        let paper = calm.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        guard let drawn = ImageOps.render(calm, extent: input.extent), let light = ImageOps.render(paper, extent: input.extent) else { throw AppError.encodeFailed(tr("signature", "Unterschrift")) }
        width = drawn.width
        height = drawn.height
        guard let ink = Self.bytes(drawn, width: width, height: height), let around = Self.bytes(light, width: width, height: height) else { throw AppError.encodeFailed(tr("signature", "Unterschrift")) }
        colors = ink
        let count = width * height
        var dark = [Float](repeating: 0, count: count)
        var histogram = [Int](repeating: 0, count: 1001)
        ink.withUnsafeBufferPointer { ink in
            around.withUnsafeBufferPointer { around in
                dark.withUnsafeMutableBufferPointer { dark in
                    for index in 0..<count {
                        let at = index * 4
                        let own = 0.3 * Float(ink[at]) + 0.59 * Float(ink[at + 1]) + 0.11 * Float(ink[at + 2])
                        let bright = 0.3 * Float(around[at]) + 0.59 * Float(around[at + 1]) + 0.11 * Float(around[at + 2])
                        let value = max(0, min(1, (bright - own) / max(bright, 12)))
                        dark[index] = value
                        histogram[Int(value * 1000)] += 1
                    }
                }
            }
        }
        darkness = dark
        // A signature covers a few percent of a photo at most: nine in ten pixels are paper.
        var seen = 0, level = 0
        while level < 1000, seen + histogram[level] < count * 9 / 10 { seen += histogram[level]; level += 1 }
        grain = Float(level) / 1000
    }

    /// Small gaps in a line filled: each pixel takes the strongest ink within two pixels, then the weakest of those (a closing).
    /// Ink only grows into gaps narrower than four pixels; the outline stays where it was.
    private static func closeGaps(_ pixels: inout [UInt8], width: Int, height: Int, in box: (minX: Int, minY: Int, maxX: Int, maxY: Int), color: MarkColor?) {
        let w = box.maxX - box.minX + 1, h = box.maxY - box.minY + 1
        guard w > 2, h > 2 else { return }
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { alpha[y * w + x] = pixels[((box.minY + y) * width + box.minX + x) * 4 + 3] } }
        func pass(_ source: [UInt8], horizontal: Bool, grow: Bool) -> [UInt8] {
            var out = source
            source.withUnsafeBufferPointer { source in
                out.withUnsafeMutableBufferPointer { out in
                    for y in 0..<h {
                        for x in 0..<w {
                            let at = y * w + x
                            var value = source[at]
                            for step in [-1, 1] {
                                let nx = horizontal ? x + step : x, ny = horizontal ? y : y + step
                                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                                let other = source[ny * w + nx]
                                value = grow ? max(value, other) : min(value, other)
                            }
                            out[at] = value
                        }
                    }
                }
            }
            return out
        }
        var closed = alpha
        for grow in [true, true, false, false] {
            closed = pass(pass(closed, horizontal: true, grow: grow), horizontal: false, grow: grow)
        }
        for y in 0..<h {
            for x in 0..<w where closed[y * w + x] > alpha[y * w + x] {
                let at = ((box.minY + y) * width + box.minX + x) * 4
                let old = pixels[at + 3], new = closed[y * w + x]
                // The colour of the ink beside it, or the one chosen.
                let share = Float(new) / 255
                if let color {
                    pixels[at] = UInt8(Float(color.red) * 255 * share); pixels[at + 1] = UInt8(Float(color.green) * 255 * share); pixels[at + 2] = UInt8(Float(color.blue) * 255 * share)
                } else if old > 0 {
                    let scale = Float(new) / Float(old)
                    pixels[at] = UInt8(min(255, Float(pixels[at]) * scale)); pixels[at + 1] = UInt8(min(255, Float(pixels[at + 1]) * scale)); pixels[at + 2] = UInt8(min(255, Float(pixels[at + 2]) * scale))
                } else {
                    pixels[at] = 0; pixels[at + 1] = 0; pixels[at + 2] = 0
                }
                pixels[at + 3] = new
            }
        }
    }

    private static func bytes(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let done: Bool = out.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return done ? out : nil
    }

    /// Where a line surely is, and down to where it is followed, at this sensitivity.
    func thresholds(sensitivity: Double) -> (sure: Float, faint: Float) {
        let level = Float(max(0, min(1, sensitivity)))
        // Never down into the grain of the paper; at the top of the slider close to it.
        let sure = max(grain * (4 - 1.5 * level) + 0.02 * (1 - level), 0.24 - 0.2 * level)
        return (sure, max(grain * (2.5 - 0.5 * level) + 0.01 * (1 - level), sure * 0.4))
    }

    func cut(sensitivity: Double, color: MarkColor?) throws -> CGImage {
        let (sure, faint) = thresholds(sensitivity: sensitivity)
        let count = width * height
        let none = AppError.invalidInput(tr("No line found on this photo. It works with dark ink on light paper; try a higher sensitivity.", "Auf diesem Foto wurde keine Linie gefunden. Es klappt mit dunkler Tinte auf hellem Papier; versuch eine höhere Empfindlichkeit."))
        // Lines: from sure pixels into faint ones that touch them.
        var part = [Int32](repeating: 0, count: count)
        var sizes: [Int] = [0]
        var boxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = [(0, 0, 0, 0)]
        var stack: [Int] = []
        // Every pixel of a line, in the order found, with its part.
        var members: [Int] = []
        darkness.withUnsafeBufferPointer { dark in
            part.withUnsafeMutableBufferPointer { part in
                for start in 0..<count where dark[start] >= sure && part[start] == 0 {
                    sizes.append(0)
                    let id = Int32(sizes.count - 1)
                    var box = (minX: width, minY: height, maxX: -1, maxY: -1)
                    part[start] = id
                    stack.append(start)
                    while let index = stack.popLast() {
                        sizes[Int(id)] += 1
                        members.append(index)
                        let x = index % width, y = index / width
                        box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
                        // Across gaps of a pixel or two: a pencil on grainy paper, a pen that skips.
                        for dy in -2...2 {
                            let ny = y + dy
                            guard ny >= 0, ny < height else { continue }
                            for dx in -2...2 {
                                let nx = x + dx
                                guard nx >= 0, nx < width else { continue }
                                let other = ny * width + nx
                                if part[other] == 0, dark[other] >= faint {
                                    part[other] = id
                                    stack.append(other)
                                }
                            }
                        }
                    }
                    boxes.append(box)
                }
            }
        }
        guard sizes.count > 1 else { throw none }
        // Which parts are the signature.
        let span = max(width, height) / 60, edge = 3
        func large(_ id: Int) -> Bool { max(boxes[id].maxX - boxes[id].minX, boxes[id].maxY - boxes[id].minY) >= span }
        func atEdge(_ id: Int) -> Bool { boxes[id].minX < edge || boxes[id].minY < edge || boxes[id].maxX >= width - edge || boxes[id].maxY >= height - edge }
        let ids = Array(1..<sizes.count)
        var main = ids.filter { large($0) && !atEdge($0) }
        if main.isEmpty { main = ids.filter(large) }
        if main.isEmpty { main = [ids.max { sizes[$0] < sizes[$1] }!] }
        var region = (minX: width, minY: height, maxX: -1, maxY: -1)
        for id in main { region = (min(region.minX, boxes[id].minX), min(region.minY, boxes[id].minY), max(region.maxX, boxes[id].maxX), max(region.maxY, boxes[id].maxY)) }
        let reach = max(width, height) / 25
        var keep = [Bool](repeating: false, count: sizes.count)
        for id in main { keep[id] = true }
        for id in ids where !keep[id] && !(large(id) && atEdge(id)) {
            let centerX = (boxes[id].minX + boxes[id].maxX) / 2, centerY = (boxes[id].minY + boxes[id].maxY) / 2
            // A dot of dirt has few pixels; the dot on an i some more.
            keep[id] = sizes[id] >= 6 && centerX >= region.minX - reach && centerX <= region.maxX + reach && centerY >= region.minY - reach && centerY <= region.maxY + reach
        }
        // How dark the line itself is: from there on it is fully ink; the edge of the line stays soft.
        let kept = members.filter { keep[Int(part[$0])] }
        var core = kept.map { darkness[$0] }.filter { $0 >= sure }
        guard !core.isEmpty else { throw none }
        core.sort()
        let full = max(core[core.count * 7 / 10] * 0.75, faint + 0.02)
        let soft = faint * 0.5
        var pixels = [UInt8](repeating: 0, count: count * 4)
        var bounds = (minX: width, minY: height, maxX: -1, maxY: -1)
        darkness.withUnsafeBufferPointer { dark in
            colors.withUnsafeBufferPointer { colors in
                pixels.withUnsafeMutableBufferPointer { pixels in
                    // The line and the pixels right beside it (its soft edge).
                    for index in kept {
                        let x = index % width, y = index / width
                        for dy in -1...1 {
                            let ny = y + dy
                            guard ny >= 0, ny < height else { continue }
                            for dx in -1...1 {
                                let nx = x + dx
                                guard nx >= 0, nx < width else { continue }
                                let other = ny * width + nx, at = other * 4
                                guard pixels[at + 3] == 0 else { continue }
                                // A pixel of the line is ink, however pale (else a pencil turns into dashes); beside it, the edge stays soft.
                                let inLine = part[other] != 0 && keep[Int(part[other])]
                                let shade = max(0, min(1, (dark[other] - soft) / (full - soft)))
                                let alpha = inLine ? 0.55 + 0.45 * shade : shade
                                guard alpha > 0 else { continue }
                                let red = color.map { Float($0.red) * 255 } ?? Float(colors[at]), green = color.map { Float($0.green) * 255 } ?? Float(colors[at + 1]), blue = color.map { Float($0.blue) * 255 } ?? Float(colors[at + 2])
                                pixels[at] = UInt8(red * alpha)
                                pixels[at + 1] = UInt8(green * alpha)
                                pixels[at + 2] = UInt8(blue * alpha)
                                pixels[at + 3] = max(1, UInt8(alpha * 255))
                                if alpha > 0.3 { bounds = (min(bounds.minX, nx), min(bounds.minY, ny), max(bounds.maxX, nx), max(bounds.maxY, ny)) }
                            }
                        }
                    }
                }
            }
        }
        guard bounds.maxX > bounds.minX, bounds.maxY > bounds.minY else { throw none }
        Self.closeGaps(&pixels, width: width, height: height, in: (max(0, bounds.minX - 4), max(0, bounds.minY - 4), min(width - 1, bounds.maxX + 4), min(height - 1, bounds.maxY + 4)), color: color)
        let box = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.maxX - bounds.minX + 1, height: bounds.maxY - bounds.minY + 1)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let picture = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let cut = picture.cropping(to: box.insetBy(dx: -6, dy: -6).intersection(CGRect(x: 0, y: 0, width: width, height: height))) else { throw AppError.encodeFailed(tr("signature", "Unterschrift")) }
        return cut
    }
}
