import AppKit

/// The menu bar icon: the app icon's segment ring (`Icon/ebenen.swift`) as a one-colour template, which the menu bar colours itself
/// (dark on a light bar, light on a dark one, and as the Mac's settings want it). Eight segments, the chosen one reaching further out,
/// a dot in the middle; drawn for any scale, so it stays sharp on every screen.
enum MenuBarIcon {
    /// Points; the menu bar's own symbols are about this size.
    static let side: CGFloat = 18

    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            path(in: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppIdentity.name
        return image
    }

    /// The shapes, scaled from the icon's 1024 canvas so the chosen segment just fits. The gaps are a little wider than in the app icon,
    /// so they stay open at this size.
    static func path(in rect: CGRect) -> NSBezierPath {
        let scale = min(rect.width, rect.height) / 2 / 372
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let result = NSBezierPath()
        let count = 8, slice = 2 * CGFloat.pi / CGFloat(count)
        for index in 0..<count {
            let mid = CGFloat.pi / 2 - CGFloat(index) * slice
            let chosen = index == 1
            result.append(wedge(center: center, inner: 186 * scale, outer: (chosen ? 372 : 318) * scale, from: mid - slice / 2, to: mid + slice / 2,
                                gap: max(1.3, 52 * scale), round: 24 * scale))
        }
        let dot: CGFloat = 84 * scale
        result.append(NSBezierPath(ovalIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)))
        return result
    }

    /// A ring segment with rounded corners, as in the app icon.
    private static func wedge(center: CGPoint, inner: CGFloat, outer: CGFloat, from a0: CGFloat, to a1: CGFloat, gap: CGFloat, round: CGFloat) -> NSBezierPath {
        let r0 = inner + round, r1 = outer - round
        let pad0 = (gap / 2 + round) / r0, pad1 = (gap / 2 + round) / r1
        let core = CGMutablePath()
        core.addArc(center: center, radius: r1, startAngle: a0 + pad1, endAngle: a1 - pad1, clockwise: false)
        core.addArc(center: center, radius: r0, startAngle: a1 - pad0, endAngle: a0 + pad0, clockwise: true)
        core.closeSubpath()
        let rounded = core.union(core.copy(strokingWithWidth: round * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
        return NSBezierPath(cgPath: rounded)
    }
}
