import AppKit
import SwiftUI

struct RadialGeometry: Equatable {
    var innerRadius: CGFloat = 70
    var outerRadius: CGFloat = 150
    var gap: CGFloat = 4
    var count: Int

    init(count: Int) {
        self.count = count
        // More places need a wider ring, so the short words keep their size.
        outerRadius = count <= 6 ? 142 : (count <= 8 ? 152 : 166)
    }

    var slice: CGFloat { 2 * .pi / CGFloat(max(count, 1)) }

    var corner: CGFloat {
        let wanted: CGFloat = count > 8 ? 10 : 14
        let limit = (innerRadius * sin(slice * 0.34) - gap / 2) / (1 - sin(slice * 0.34))
        return max(4, min(wanted, limit))
    }

    var labelRadius: CGFloat { innerRadius + (outerRadius - innerRadius) * 0.54 }

    var labelWidth: CGFloat {
        let chord = 2 * labelRadius * sin(slice / 2)
        return max(24, min(chord - 8, outerRadius - innerRadius))
    }

    func angles(for index: Int) -> (start: CGFloat, end: CGFloat) {
        let end = CGFloat.pi / 2 - slice * CGFloat(index) + slice / 2
        return (end - slice, end)
    }

    func midpoint(for index: Int, in rect: CGRect) -> CGPoint {
        let (start, end) = angles(for: index)
        let mid = (start + end) / 2
        return CGPoint(x: rect.midX + cos(mid) * labelRadius, y: rect.midY - sin(mid) * labelRadius)
    }

    /// The item under a point (offset from the centre, y up). The middle and far outside are none: dropping there cancels.
    func index(at offset: CGPoint) -> Int? {
        guard count > 0 else { return nil }
        let distance = sqrt(offset.x * offset.x + offset.y * offset.y)
        guard distance >= innerRadius, distance <= outerRadius + 24 else { return nil }
        var angle = atan2(offset.y, offset.x)
        if angle < 0 { angle += 2 * .pi }
        var relative = CGFloat.pi / 2 + slice / 2 - angle
        while relative < 0 { relative += 2 * .pi }
        while relative >= 2 * .pi { relative -= 2 * .pi }
        return min(count - 1, Int(relative / slice))
    }
}

struct WedgeShape: Shape {
    var geometry: RadialGeometry
    var index: Int

    func path(in rect: CGRect) -> Path {
        let (a0, a1) = geometry.angles(for: index)
        return ArcShape(start: a0, end: a1, inner: geometry.innerRadius, outer: geometry.outerRadius, corner: geometry.corner, gap: geometry.gap).path(in: rect)
    }
}

/// A piece of a ring with rounded corners, around the middle of its frame: a ring's item, or a preset in a fan.
struct ArcShape: Shape {
    var start: CGFloat
    var end: CGFloat
    var inner: CGFloat
    var outer: CGFloat
    var corner: CGFloat
    var gap: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let (a0, a1) = (start, end)
        let r0 = inner
        let r1 = outer
        let k = corner
        let half = gap / 2
        let phiOuter = asin((k + half) / (r1 - k))
        let phiInner = asin((k + half) / (r0 + k))

        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: c.x + cos(angle) * radius, y: c.y - sin(angle) * radius)
        }
        func normal(_ angle: CGFloat, inward: Bool) -> CGVector {
            inward ? CGVector(dx: sin(angle), dy: -cos(angle)) : CGVector(dx: -sin(angle), dy: cos(angle))
        }
        func offset(_ p: CGPoint, _ v: CGVector, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: p.x + v.dx * distance, y: p.y - v.dy * distance)
        }
        func arc(_ path: inout Path, center: CGPoint, radius: CGFloat, from: CGPoint, to: CGPoint) {
            let s = atan2(from.y - center.y, from.x - center.x)
            let e = atan2(to.y - center.y, to.x - center.x)
            path.addArc(center: center, radius: radius, startAngle: .radians(s), endAngle: .radians(e), clockwise: true)
        }

        let outerEndCenter = point(r1 - k, a1 - phiOuter)
        let outerEndTangent = offset(outerEndCenter, normal(a1, inward: true), -k)
        let innerEndCenter = point(r0 + k, a1 - phiInner)
        let innerEndTangent = offset(innerEndCenter, normal(a1, inward: true), -k)
        let innerStartCenter = point(r0 + k, a0 + phiInner)
        let innerStartTangent = offset(innerStartCenter, normal(a0, inward: false), -k)
        let outerStartCenter = point(r1 - k, a0 + phiOuter)
        let outerStartTangent = offset(outerStartCenter, normal(a0, inward: false), -k)

        var path = Path()
        path.move(to: point(r1, a0 + phiOuter))
        path.addArc(center: c, radius: r1, startAngle: .radians(-(a0 + phiOuter)), endAngle: .radians(-(a1 - phiOuter)), clockwise: true)
        arc(&path, center: outerEndCenter, radius: k, from: point(r1, a1 - phiOuter), to: outerEndTangent)
        path.addLine(to: innerEndTangent)
        arc(&path, center: innerEndCenter, radius: k, from: innerEndTangent, to: point(r0, a1 - phiInner))
        path.addArc(center: c, radius: r0, startAngle: .radians(-(a1 - phiInner)), endAngle: .radians(-(a0 + phiInner)), clockwise: false)
        arc(&path, center: innerStartCenter, radius: k, from: point(r0, a0 + phiInner), to: innerStartTangent)
        path.addLine(to: outerStartTangent)
        arc(&path, center: outerStartCenter, radius: k, from: outerStartTangent, to: point(r1, a0 + phiOuter))
        path.closeSubpath()
        return path
    }
}

/// The fan: the presets of one item as a second arc just outside it. The ring stays as it is; the pointer goes straight out over the
/// item's edge into the fan. Centred on the item; where that would leave part of it off the usable screen, it turns along the ring to
/// one side, half a preset at a time, but always so that it still touches its item. (The ring keeps 248 pt from every edge of the
/// screen and the notch, `RadialController.clampedCenter`, and the fan reaches at most 236 pt out: on a real screen it always fits.)
struct FanGeometry: Equatable {
    var ring: RadialGeometry
    var parent: Int
    var count: Int
    /// The middle of the first preset, in radians counter-clockwise from 3 o'clock; the others follow clockwise.
    var first: CGFloat

    static let step: CGFloat = 22 * .pi / 180
    /// Between the ring and the fan, and how deep the fan is: with 10 places it ends 236 pt out, inside the ring's 480-pt square.
    static let gap: CGFloat = 8
    static let depth: CGFloat = 62
    static let corner: CGFloat = 10

    var inner: CGFloat { ring.outerRadius + Self.gap }
    var outer: CGFloat { inner + Self.depth }
    var labelRadius: CGFloat { (inner + outer) / 2 }
    var labelWidth: CGFloat { 2 * labelRadius * sin(Self.step / 2) - 6 }

    func mid(_ index: Int) -> CGFloat { first - CGFloat(index) * Self.step }
    func angles(_ index: Int) -> (start: CGFloat, end: CGFloat) { (mid(index) - Self.step / 2, mid(index) + Self.step / 2) }
    /// The middle of the whole fan.
    var middle: CGFloat { first - CGFloat(count - 1) * Self.step / 2 }

    /// Centred on its item, or turned until it fits inside `usable` (offsets from the ring's middle, y up; nil: anywhere).
    static func placed(ring: RadialGeometry, parent: Int, count: Int, usable: CGRect?) -> FanGeometry {
        let centred = ring.angles(for: parent).start + ring.slice / 2 + CGFloat(count - 1) * step / 2
        let plain = FanGeometry(ring: ring, parent: parent, count: count, first: centred)
        guard let usable else { return plain }
        var best = plain, least = plain.overflow(usable)
        guard least > 0 else { return plain }
        // Turned by up to half the fan plus half a preset: the item's middle stays inside the fan's arc.
        for shift in 1...count {
            for sign in [1.0, -1.0] {
                let candidate = FanGeometry(ring: ring, parent: parent, count: count, first: centred + CGFloat(sign) * CGFloat(shift) * step / 2)
                let over = candidate.overflow(usable)
                if over == 0 { return candidate }
                if over < least { best = candidate; least = over }
            }
        }
        return best
    }

    /// How far the fan's outline reaches out of `usable` (0: it fits).
    func overflow(_ usable: CGRect) -> CGFloat {
        var total: CGFloat = 0
        for index in 0..<count {
            let (a0, a1) = angles(index)
            for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
                let angle = a0 + (a1 - a0) * fraction
                for radius in [inner, outer] {
                    let p = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
                    total += max(0, usable.minX - p.x) + max(0, p.x - usable.maxX) + max(0, usable.minY - p.y) + max(0, p.y - usable.maxY)
                }
            }
        }
        return total
    }

    /// The preset under a point (offset from the ring's middle, y up), or nil.
    func index(at offset: CGPoint) -> Int? {
        let distance = hypot(offset.x, offset.y)
        guard distance >= inner - 4, distance <= outer + 20 else { return nil }
        let angle = atan2(offset.y, offset.x)
        for index in 0..<count {
            let difference = remainder(angle - mid(index), 2 * .pi)
            if abs(difference) <= Self.step / 2 { return index }
        }
        return nil
    }

    /// The middle of a preset's word, in a frame of `side` points (SwiftUI, y down).
    func labelPoint(_ index: Int, side: CGFloat) -> CGPoint {
        CGPoint(x: side / 2 + cos(mid(index)) * labelRadius, y: side / 2 - sin(mid(index)) * labelRadius)
    }

    func shape(_ index: Int) -> ArcShape {
        let (a0, a1) = angles(index)
        return ArcShape(start: a0, end: a1, inner: inner, outer: outer, corner: Self.corner, gap: ring.gap)
    }
}

/// How the ring is drawn: Liquid Glass, or solid surfaces (Reduce transparency, Increase contrast, and pictures drawn off screen,
/// where glass has nothing behind it to show).
enum RingStyle: Equatable {
    case glass
    case solid(strongEdges: Bool)

    @MainActor
    static var current: RingStyle {
        let workspace = NSWorkspace.shared
        return style(reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
                     increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
    }

    /// Glass unless the Mac asks for less transparency or more contrast; more contrast also draws strong edges.
    static func style(reduceTransparency: Bool, increaseContrast: Bool) -> RingStyle {
        reduceTransparency || increaseContrast ? .solid(strongEdges: increaseContrast) : .glass
    }
}

/// What the ring shows; built by `RadialView` and, for pictures, by the test access.
struct RingContent: Equatable {
    var slots: [RingEntry] = []
    var highlighted: Int?
    /// The middle when nothing is under the pointer: the ring's name …
    var title = ""
    /// … and the file name or "12 files".
    var files = ""
    /// The other rings and their keys.
    var hint = ""
    var emptyMessage = ""
    var style: RingStyle = .glass
    /// Counts up each time the ring opens: it grows in from a little smaller, or only fades in with "Reduce motion".
    var presentation = 0
    /// The open fan of the item `fan.parent`: its place, its presets and the one under the pointer.
    var fan: FanGeometry?
    var fanEntries: [RingEntry] = []
    var fanHighlighted: Int?
}

/// The ring appearing: already visible in the first frame (so it still comes within 100 ms), then settling in 0.18 s. With "Reduce
/// motion" no growing, only fading.
private struct RingAppear: ViewModifier {
    let id: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = -1

    func body(content: Content) -> some View {
        let isShown = shown == id
        content
            .scaleEffect(isShown || reduceMotion ? 1 : 0.94)
            .opacity(isShown ? 1 : 0.4)
            .onAppear(perform: reveal)
            .onChange(of: id) { reveal() }
    }

    private func reveal() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18)) { shown = id }
    }
}

/// The outline of an aspect ratio ("ratio.16.9"), the symbol of a crop preset.
struct RatioGlyph: View {
    var ratio: CGSize
    var side: CGFloat

    static func ratio(_ symbol: String) -> CGSize? {
        let parts = symbol.split(separator: ".")
        guard parts.count == 3, parts[0] == "ratio", let width = Double(parts[1]), let height = Double(parts[2]), width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    var body: some View {
        let scale = side * 0.95 / max(ratio.width, ratio.height)
        RoundedRectangle(cornerRadius: 2.5)
            .strokeBorder(lineWidth: 1.6)
            .frame(width: ratio.width * scale, height: ratio.height * scale)
            .frame(width: side + 2, height: side + 2)
    }
}

struct RadialWheelView: View {
    var content: RingContent

    /// Room for the ring (up to 166 pt out from the middle), the name and the line with the other rings below it.
    static let side: CGFloat = 480
    /// Glass behind text is dimmed so writing on the desktop can't show through (HIG: legibility on Liquid Glass).
    static let textDimming: Double = 0.55
    /// Behind the words in the ring's fields: a little more, because the fields are large and busy desktops showed through them;
    /// the glass still shows at the edges.
    static let wedgeDimming: Double = 0.7

    private var geometry: RadialGeometry { RadialGeometry(count: content.slots.count) }

    var body: some View {
        ZStack {
            if content.slots.isEmpty {
                empty
            } else {
                // The chosen item is emerald in the same frame the pointer reaches it: no fade, nothing grey in between.
                ring
                    .frame(width: Self.side, height: Self.side)
                // The full name of the item under the pointer: a pill right under the ring, never in the middle, where the picture
                // Finder drags along covers it (variant A); the other rings below it.
                if let name = highlightedName {
                    namePill(name)
                        .position(namePillPoint)
                }
                // While a fan is open the line with the other rings makes room for it.
                if !content.hint.isEmpty, content.fan == nil {
                    hintLine
                        .position(x: Self.side / 2, y: Self.side / 2 + geometry.outerRadius + 58)
                }
            }
        }
        .frame(width: Self.side, height: Self.side)
        // The panel is never the active window; the ring must not look like one that is (greyed tints).
        .environment(\.appearsActive, true)
        .modifier(RingAppear(id: content.presentation))
    }

    @ViewBuilder private var ring: some View {
        switch content.style {
        case .glass:
            GlassEffectContainer(spacing: 0) {
                ZStack {
                    ForEach(Array(content.slots.enumerated()), id: \.element.id) { index, item in wedge(item, index: index) }
                    middle.background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(Self.textDimming)))
                        .glassEffect(.regular, in: Circle())
                    fanView
                }
            }
        case .solid(let strong):
            ZStack {
                ForEach(Array(content.slots.enumerated()), id: \.element.id) { index, item in wedge(item, index: index) }
                fanView
                middle
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Circle().strokeBorder(strong ? Color.primary : Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1))
            }
        }
    }

    private func wedge(_ item: RingEntry, index: Int) -> some View {
        let shape = WedgeShape(geometry: geometry, index: index)
        let selected = content.highlighted == index
        // The item whose fan is open while the pointer is out in the fan: tinted and outlined in emerald (the way it came from).
        let onTheWay = !selected && content.fan?.parent == index
        return GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let mid = geometry.midpoint(for: index, in: rect)
            let label = self.label(item, selected: selected)
                .frame(width: geometry.labelWidth)
                .position(mid)
            let marker = presetMarker(item, index: index, selected: selected, in: rect)
            switch content.style {
            case .glass:
                ZStack {
                    // Chosen: solid emerald, which shows at once and in any window state (a tint on glass greys out while the
                    // panel isn't the active window). Others: glass, dimmed behind their word.
                    shape.fill(selected ? Theme.accent : Color(nsColor: .windowBackgroundColor).opacity(Self.wedgeDimming))
                    if onTheWay { shape.fill(Theme.accent.opacity(0.22)); shape.stroke(Theme.accent, lineWidth: 1.5) }
                    label
                    marker
                }
                    .frame(width: rect.width, height: rect.height)
                    .glassEffect(.regular, in: shape)
            case .solid(let strong):
                ZStack {
                    shape.fill(selected ? Theme.accent : Color(nsColor: .windowBackgroundColor))
                    if onTheWay { shape.fill(Theme.accent.opacity(0.22)) }
                    shape.stroke(onTheWay ? Theme.accent : (strong ? Color.primary : Color(nsColor: .separatorColor)), lineWidth: strong || onTheWay ? 1.5 : 1)
                    label
                    marker
                }
                .frame(width: rect.width, height: rect.height)
            }
        }
    }

    /// A small triangle at the outer edge of an item with presets: there is a fan behind it. On the middle of the edge where it stays
    /// clear of the item's symbol and word, else moved along the edge until it does.
    @ViewBuilder private func presetMarker(_ item: RingEntry, index: Int, selected: Bool, in rect: CGRect) -> some View {
        if !item.presets.isEmpty {
            let angle = Self.markerAngle(geometry: geometry, index: index, label: item.shortLabel), radius = geometry.outerRadius - 9
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 7))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                .rotationEffect(.radians(-angle))
                .position(x: rect.midX + cos(angle) * radius, y: rect.midY - sin(angle) * radius)
                .accessibilityHidden(true)
        }
    }

    /// Where on an item's outer edge its fan marker goes: the first angle, going out from the middle in both directions, at which a
    /// 7-pt triangle keeps 2 pt away from the symbol and the word (sizes as `label` draws them).
    static func markerAngle(geometry: RadialGeometry, index: Int, label: String) -> CGFloat {
        let (a0, a1) = geometry.angles(for: index)
        let mid = (a0 + a1) / 2, radius = geometry.outerRadius - 9
        let dense = geometry.count > 8
        let font = NSFont.systemFont(ofSize: dense ? 10.5 : 11.5, weight: .medium)
        let textWidth = min(geometry.labelWidth, (label as NSString).size(withAttributes: [.font: font]).width)
        let center = CGPoint(x: cos(mid) * geometry.labelRadius, y: -sin(mid) * geometry.labelRadius)
        // y down, as on screen: the symbol above the middle, the word below it.
        let symbol = CGRect(x: center.x - 12, y: center.y - 20, width: 24, height: 22)
        let word = CGRect(x: center.x - textWidth / 2, y: center.y + 4, width: textWidth, height: 16)
        let degree = CGFloat.pi / 180
        var tries: [CGFloat] = [0]
        for step in stride(from: 3, through: Int((a1 - a0) / degree / 2) - 8, by: 3) { tries += [-CGFloat(step) * degree, CGFloat(step) * degree] }
        for offset in tries {
            let angle = mid + offset
            let point = CGPoint(x: cos(angle) * radius, y: -sin(angle) * radius)
            let marker = CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11)
            if !marker.intersects(symbol) && !marker.intersects(word) { return angle }
        }
        return mid
    }

    /// The open fan's presets, drawn like the ring's items.
    @ViewBuilder private var fanView: some View {
        if let fan = content.fan {
            ForEach(Array(content.fanEntries.enumerated()), id: \.offset) { index, entry in
                fanWedge(entry, index: index, fan: fan)
            }
            .transition(.opacity)
        }
    }

    private func fanWedge(_ entry: RingEntry, index: Int, fan: FanGeometry) -> some View {
        let shape = fan.shape(index)
        let selected = content.fanHighlighted == index
        let label = self.label(entry, selected: selected, dense: true)
            .frame(width: fan.labelWidth)
            .position(fan.labelPoint(index, side: Self.side))
        return Group {
            switch content.style {
            case .glass:
                ZStack {
                    shape.fill(selected ? Theme.accent : Color(nsColor: .windowBackgroundColor).opacity(Self.wedgeDimming))
                    label
                }
                .frame(width: Self.side, height: Self.side)
                .glassEffect(.regular, in: shape)
            case .solid(let strong):
                ZStack {
                    shape.fill(selected ? Theme.accent : Color(nsColor: .windowBackgroundColor))
                    shape.stroke(strong ? Color.primary : Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1)
                    label
                }
                .frame(width: Self.side, height: Self.side)
            }
        }
    }

    private func label(_ item: RingEntry, selected: Bool, dense denseFan: Bool = false) -> some View {
        let dense = denseFan || content.slots.count > 8
        return VStack(spacing: dense ? 3 : 4) {
            if let ratio = RatioGlyph.ratio(item.symbol) {
                RatioGlyph(ratio: ratio, side: dense ? 16 : 19)
            } else {
                Image(systemName: item.isAvailable ? item.symbol : "arrow.down.circle")
                    .font(.system(size: dense ? 16 : 19, weight: .regular))
                    .symbolRenderingMode(.monochrome)
            }
            Text(item.shortLabel)
                .font(.system(size: dense ? 10.5 : 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .foregroundStyle(selected ? Color.white : (item.isAvailable ? Color.primary : Color.secondary))
        .opacity(item.isAvailable || selected ? 1 : 0.6)
    }

    /// Under the ring, as always; with a fan open, moved sideways away from it, or above the ring when the fan hangs below.
    private var namePillPoint: CGPoint {
        let below = CGPoint(x: Self.side / 2, y: Self.side / 2 + geometry.outerRadius + 24)
        guard let fan = content.fan else { return below }
        if sin(fan.middle) < -0.45 { return CGPoint(x: Self.side / 2, y: Self.side / 2 - geometry.outerRadius - 24) }
        return CGPoint(x: Self.side / 2 - cos(fan.middle) * 95, y: below.y + 6)
    }

    /// The full name of the item under the pointer (and the missing program), shown outside the middle.
    private var highlightedName: (title: String, missing: String?)? {
        if let index = content.fanHighlighted, content.fanEntries.indices.contains(index) { return (content.fanEntries[index].title, nil) }
        guard let index = content.highlighted, content.slots.indices.contains(index) else { return nil }
        let item = content.slots[index]
        return (item.title, item.missing.map { tr("Needs \($0.name)", "Braucht \($0.name)") })
    }

    @ViewBuilder private func namePill(_ name: (title: String, missing: String?)) -> some View {
        let text = VStack(spacing: 1) {
            Text(name.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
            if let missing = name.missing {
                Text(missing).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        switch content.style {
        case .glass:
            text.background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(Self.textDimming)))
                .glassEffect(.regular, in: Capsule())
        case .solid(let strong):
            text.background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Capsule().strokeBorder(strong ? Color.primary : Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1))
                .fixedSize()
        }
    }

    /// The middle: the ring's name and the files (the full name of an item goes in its own pill, where the dragged picture can't
    /// cover it).
    private var middle: some View {
        let width = geometry.innerRadius * 2 - 18
        return VStack(spacing: 3) {
            Text(content.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(content.files)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
        }
        .frame(width: width)
        .frame(width: geometry.innerRadius * 2 - 8, height: geometry.innerRadius * 2 - 8)
    }

    @ViewBuilder private var hintLine: some View {
        let text = Text(content.hint)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        switch content.style {
        case .glass:
            text.background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(Self.textDimming)))
                .glassEffect(.regular, in: Capsule())
        case .solid(let strong):
            ZStack {
                Capsule().fill(Color(nsColor: .windowBackgroundColor))
                Capsule().strokeBorder(strong ? Color.primary : Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1)
                text
            }
            .fixedSize()
        }
    }

    @ViewBuilder private var empty: some View {
        let box = VStack(spacing: 3) {
            Text(content.emptyMessage)
                .font(.system(size: 14, weight: .semibold))
            if !content.files.isEmpty {
                Text(content.files)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: 300)
        switch content.style {
        case .glass:
            box.background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(Self.textDimming)))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        case .solid:
            box.background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The full-screen view that holds the ring. It takes the drop (the dragged files land on it), follows the pointer and, when the ring
/// was opened without a drag (menu bar, Finder's menu), the keyboard.
final class RadialView: NSView {
    var slots: [RingEntry] = [] { didSet { resetFan(); refresh() } }
    var title = "" { didSet { refresh() } }
    var files = "" { didSet { refresh() } }
    var hint = "" { didSet { refresh() } }
    var emptyMessage = "" { didSet { refresh() } }
    var presentation = 0 { didSet { scroll = ScrollStepper(); refresh() } }
    var center: NSPoint = .zero { didSet { needsLayout = true } }
    /// Scrolling with a mouse over the open ring changes the ring (`ScrollStepper`).
    private var scroll = ScrollStepper()
    /// The item, and whether Option was held (run with the last values).
    var onSelect: ((RingEntry, Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onDragEntered: ((NSDraggingInfo) -> Void)?
    var onDragSessionEnded: (() -> Void)?
    /// Typing while the ring has the keyboard: the "More …" list opens with the text.
    var onType: ((String) -> Void)?
    /// Tab: the next ring (Shift-Tab: the one before).
    var onSwitchRing: ((Int) -> Void)?
    var interactive = false
    /// The mouse moved or was pressed on the ring: a ring that waits for that before it takes the keyboard (`RadialController.presentPicker`).
    /// With the mouse's place on the screen, and whether it was a click.
    var onPointer: ((NSPoint, Bool) -> Void)?
    /// False while the ring waits for the person to turn to it (`RadialController.presentPicker`): every key is ignored.
    var keysArmed = true

    private(set) var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            if highlighted != nil {
                MainActor.assumeIsolated {
                    Haptics.selectionChanged()
                    SoundPlayer.shared.play(.hover)
                }
            }
            refresh()
            // VoiceOver follows the arrow keys.
            if interactive, let highlighted, accessibilityItems.indices.contains(highlighted) {
                NSAccessibility.post(element: accessibilityItems[highlighted], notification: .focusedUIElementChanged)
            }
        }
    }
    // MARK: The fan

    /// The open fan (`FanGeometry.parent` is its item) and the preset under the pointer or chosen with the keys.
    private(set) var fan: FanGeometry?
    private(set) var fanHighlighted: Int? {
        didSet {
            guard oldValue != fanHighlighted else { return }
            if fanHighlighted != nil {
                MainActor.assumeIsolated {
                    Haptics.selectionChanged()
                    SoundPlayer.shared.play(.hover)
                }
            }
            refresh()
            if interactive, let fanHighlighted, fanAccessibilityItems.indices.contains(fanHighlighted) {
                NSAccessibility.post(element: fanAccessibilityItems[fanHighlighted], notification: .focusedUIElementChanged)
            }
        }
    }
    /// How long the pointer rests on an item before its fan opens (moving out over the item's edge opens it at once).
    nonisolated(unsafe) static var dwellSeconds: Double = 0.3
    private var dwell: DispatchWorkItem?
    /// Where the fan may go, as offsets from the ring's middle (y up). Nil: the screen without the notch.
    var usableArea: CGRect?

    /// The presets of the open fan, as the ring shows them.
    var fanEntries: [RingEntry] {
        guard let fan, slots.indices.contains(fan.parent) else { return [] }
        return slots[fan.parent].presets.map(\.entry)
    }

    private var trackingArea: NSTrackingArea?
    private let host: PassthroughHostingView<RadialWheelView>

    var discRadius: CGFloat { RadialWheelView.side / 2 }

    private var geometry: RadialGeometry { RadialGeometry(count: slots.count) }

    override init(frame frameRect: NSRect) {
        host = PassthroughHostingView(rootView: RadialWheelView(content: RingContent()))
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, NSPasteboard.PasteboardType("com.apple.finder.node")] + promiseTypes)
        wantsLayer = true
        host.sizingOptions = []
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        host.frame = NSRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    var content: RingContent {
        RingContent(slots: slots, highlighted: highlighted, title: title, files: files, hint: hint, emptyMessage: emptyMessage, style: RingStyle.current,
                    presentation: presentation, fan: fan, fanEntries: fanEntries, fanHighlighted: fanHighlighted)
    }

    private func refresh() {
        host.rootView = RadialWheelView(content: content)
        accessibilityItems = makeAccessibilityItems()
        fanAccessibilityItems = makeFanAccessibilityItems()
    }

    // MARK: VoiceOver

    /// One button per place, at its place on screen, named with the full name (and the missing program); pressing it chooses it.
    private(set) var accessibilityItems: [NSAccessibilityElement] = []

    private func makeAccessibilityItems() -> [NSAccessibilityElement] {
        slots.enumerated().map { index, item in
            let element = RingAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            var label = item.title
            if let missing = item.missing { label += ", " + tr("needs \(missing.name)", "braucht \(missing.name)") }
            element.setAccessibilityLabel(label)
            element.setAccessibilityHelp(item.shortLabel)
            element.setAccessibilityEnabled(item.isAvailable)
            element.setAccessibilityFrameInParentSpace(accessibilityFrame(of: index))
            element.press = { [weak self] in self?.onSelect?(item, false) }
            // The fan's presets as VoiceOver actions of the item (VO-Command-Space), without opening the fan.
            element.setAccessibilityCustomActions(item.presets.map { preset in
                NSAccessibilityCustomAction(name: preset.title) { [weak self] in
                    self?.onSelect?(preset.entry, false)
                    return true
                }
            })
            return element
        }
    }

    /// The open fan's presets, as buttons after the ring's items.
    private(set) var fanAccessibilityItems: [NSAccessibilityElement] = []

    private func makeFanAccessibilityItems() -> [NSAccessibilityElement] {
        guard let fan else { return [] }
        return fanEntries.enumerated().map { index, entry in
            let element = RingAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(entry.title)
            element.setAccessibilityHelp(entry.shortLabel)
            let size: CGFloat = 40
            let x = center.x + cos(fan.mid(index)) * fan.labelRadius, y = center.y + sin(fan.mid(index)) * fan.labelRadius
            element.setAccessibilityFrameInParentSpace(NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
            element.press = { [weak self] in self?.onSelect?(entry, false) }
            return element
        }
    }

    /// The square around the middle of the item's wedge, in this view's space.
    private func accessibilityFrame(of index: Int) -> NSRect {
        let ring = RadialGeometry(count: slots.count)
        let disc = CGRect(x: 0, y: 0, width: RadialWheelView.side, height: RadialWheelView.side)
        let mid = ring.midpoint(for: index, in: disc)
        let size = max(28, ring.outerRadius - ring.innerRadius - 10)
        // `midpoint` counts from the top (SwiftUI); this view counts from the bottom.
        let x = center.x - discRadius + mid.x, y = center.y + discRadius - mid.y
        return NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        slots.isEmpty ? emptyMessage : "\(title), \(files)"
    }
    override func accessibilityChildren() -> [Any]? { accessibilityItems + fanAccessibilityItems }

    /// Says which ring opened and how many places it has (VoiceOver, without taking the focus from Finder).
    func announce() {
        let text = slots.isEmpty ? emptyMessage : tr("\(title) ring, \(slots.count) items, \(files)", "Ring \(title), \(slots.count) Einträge, \(files)")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func index(at point: NSPoint) -> Int? {
        geometry.index(at: CGPoint(x: point.x - center.x, y: point.y - center.y))
    }

    func updateHighlight(forWindowPoint point: NSPoint) {
        track(convert(point, from: nil))
    }

    /// Follows the pointer (in this view's space): the item under it, its fan after a moment or once the pointer is out over the
    /// item's edge, a preset in the fan; back into the ring closes the fan again.
    func track(_ point: NSPoint) {
        let offset = CGPoint(x: point.x - center.x, y: point.y - center.y)
        let distance = hypot(offset.x, offset.y)
        if let fan {
            if distance >= fan.inner - 4 {
                // Out in the fan's arc: a preset, or nothing (dropping there cancels, as outside the ring).
                fanHighlighted = fan.index(at: offset)
                setHighlight(nil)
                return
            }
            let index = geometry.index(at: offset)
            if index == fan.parent {
                fanHighlighted = nil
                setHighlight(index)
                return
            }
            closeFan()
            setHighlight(index)
            return
        }
        let index = geometry.index(at: offset)
        setHighlight(index)
        guard let index, slots.indices.contains(index), !slots[index].presets.isEmpty else { return }
        if distance > geometry.outerRadius + 2 {
            openFan(index)
            track(point)
        }
    }

    /// The item under the pointer; resting on one with presets opens its fan after `dwellSeconds`.
    private func setHighlight(_ index: Int?) {
        guard index != highlighted else { return }
        highlighted = index
        dwell?.cancel()
        dwell = nil
        guard let index, fan == nil, slots.indices.contains(index), !slots[index].presets.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.highlighted == index, self.fan == nil else { return }
            self.openFan(index)
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellSeconds, execute: work)
    }

    /// Opens the fan of an item with presets.
    func openFan(_ index: Int) {
        guard slots.indices.contains(index), !slots[index].presets.isEmpty, fan?.parent != index else { return }
        dwell?.cancel()
        dwell = nil
        fan = FanGeometry.placed(ring: geometry, parent: index, count: slots[index].presets.count, usable: usableOffsets())
        fanHighlighted = nil
        refresh()
        let text = tr("\(slots[index].title): \(slots[index].presets.count) presets", "\(slots[index].title): \(slots[index].presets.count) Vorgaben")
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func closeFan() {
        dwell?.cancel()
        dwell = nil
        guard fan != nil else { return }
        fan = nil
        fanHighlighted = nil
        refresh()
    }

    /// A new set of items: no fan, nothing waiting to open one.
    private func resetFan() {
        dwell?.cancel()
        dwell = nil
        fan = nil
        fanHighlighted = nil
    }

    /// Chooses a preset of the open fan (test access, keyboard).
    func highlightFan(_ index: Int?) {
        fanHighlighted = index.flatMap { fanEntries.indices.contains($0) ? $0 : nil }
    }

    /// The fan of an item open, as the pointer leaves it: on the item itself, or on one of its presets (test access, pictures).
    func showFan(_ index: Int, preset: Int?) {
        closeFan()
        highlighted = slots.indices.contains(index) ? index : nil
        openFan(index)
        if let preset, fan != nil {
            highlighted = nil
            highlightFan(preset)
        }
    }

    /// The screen this ring is on, without the notch, a few points in from its edges, as offsets from the ring's middle.
    private func usableOffsets() -> CGRect? {
        if let usableArea { return usableArea }
        guard window != nil else { return nil }
        let notch = window?.screen?.safeAreaInsets.top ?? 0
        let area = CGRect(x: bounds.minX + 4, y: bounds.minY + 4, width: bounds.width - 8, height: bounds.height - 8 - notch)
        return area.offsetBy(dx: -center.x, dy: -center.y)
    }

    /// What a drop or a click here chooses: the preset under the pointer, else the item.
    private var chosenEntry: RingEntry? {
        if let fan, let index = fanHighlighted, slots.indices.contains(fan.parent), slots[fan.parent].presets.indices.contains(index) {
            return slots[fan.parent].presets[index].entry
        }
        if let highlighted, highlighted < slots.count { return slots[highlighted] }
        return nil
    }

    /// Finder offers copy, or only move while ⌘ is held, link with ⌥⌘: the ring takes whatever is offered and never moves or deletes
    /// anything itself (it only reads where the files are).
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for operation in [NSDragOperation.copy, .generic, .move, .link, .every] where mask.contains(operation) { return operation }
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEntered?(sender)
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return chosenEntry == nil ? [] : Self.operation(for: sender.draggingSourceOperationMask)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return chosenEntry == nil ? [] : Self.operation(for: sender.draggingSourceOperationMask)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DragDebug.log("prepareForDragOperation highlighted=\(String(describing: highlighted)) fan=\(String(describing: fanHighlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        return chosenEntry != nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        closeFan()
        guard let window, sender != nil, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        if window.frame.insetBy(dx: 1, dy: 1).contains(NSEvent.mouseLocation) {
            onDragSessionEnded?()
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlighted = nil
        closeFan()
        onDragSessionEnded?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        DragDebug.log("performDragOperation highlighted=\(String(describing: highlighted)) fan=\(String(describing: fanHighlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        guard let item = chosenEntry else {
            onCancel?()
            return false
        }
        let option = NSEvent.modifierFlags.contains(.option)
        DispatchQueue.main.async { [weak self] in self?.onSelect?(item, option) }
        return true
    }

    /// The panel takes the mouse only while a ring is open, so this is scrolling over an open ring. It never reaches the app below
    /// (no Finder window scrolls); a wheel step, or a swipe on a Magic Mouse, changes the ring.
    override func scrollWheel(with event: NSEvent) {
        let step = scroll.step(ScrollStepper.Event(event))
        guard step != 0, let onSwitchRing else { return }
        closeFan()
        onSwitchRing(step)
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        onPointer?(NSEvent.mouseLocation, false)
        updateHighlight(forWindowPoint: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        onPointer?(NSEvent.mouseLocation, true)
        updateHighlight(forWindowPoint: event.locationInWindow)
        if let item = chosenEntry {
            onSelect?(item, event.modifierFlags.contains(.option))
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { return }
        guard keysArmed else {
            // Escape only closes: harmless, whoever meant it.
            if event.keyCode == 53 { onCancel?() } else { DiagnosticLog.log("ring ignored a key: it waits for the mouse") }
            return
        }
        switch event.keyCode {
        case 53:
            // Escape closes an open fan first, then the ring.
            if fan != nil { closeFan() } else { onCancel?() }
        case 49 where fan == nil && highlighted.map { slots.indices.contains($0) && !slots[$0].presets.isEmpty } == true:
            // Space on an item with presets opens its fan, with the first preset chosen.
            if let highlighted { openFan(highlighted) }
            fanHighlighted = 0
        case 36, 76, 49:
            if let item = chosenEntry { onSelect?(item, event.modifierFlags.contains(.option)) }
        case 123, 126:
            if fan != nil { stepFan(-1) } else { step(-1) }
        case 124, 125:
            if fan != nil { stepFan(1) } else { step(1) }
        case 48:
            closeFan()
            onSwitchRing?(event.modifierFlags.contains(.shift) ? -1 : 1)
        default:
            let typed = (event.charactersIgnoringModifiers ?? "").filter { $0.isLetter || $0.isNumber }
            if !typed.isEmpty, event.modifierFlags.intersection([.command, .control]).isEmpty {
                onType?(typed)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func step(_ delta: Int) {
        guard !slots.isEmpty else { return }
        let current = highlighted ?? (delta > 0 ? -1 : 0)
        var next = (current + delta) % slots.count
        if next < 0 { next += slots.count }
        highlighted = next
    }

    /// Moves through the open fan's presets with the arrow keys (they don't go round).
    private func stepFan(_ delta: Int) {
        let count = fanEntries.count
        guard count > 0 else { return }
        fanHighlighted = min(count - 1, max(0, (fanHighlighted ?? (delta > 0 ? -1 : count)) + delta))
    }

    func clearHighlight() {
        highlighted = nil
        closeFan()
    }

    func highlight(_ index: Int) {
        closeFan()
        highlighted = slots.indices.contains(index) ? index : nil
    }
}

/// A place of the ring for VoiceOver.
final class RingAccessibilityElement: NSAccessibilityElement {
    var press: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }
}
