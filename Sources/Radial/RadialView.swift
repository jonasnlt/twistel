import AppKit
import SwiftUI

struct RadialGeometry {
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
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let (a0, a1) = geometry.angles(for: index)
        let r0 = geometry.innerRadius
        let r1 = geometry.outerRadius
        let k = geometry.corner
        let half = geometry.gap / 2
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
                        .position(x: Self.side / 2, y: Self.side / 2 + geometry.outerRadius + 24)
                }
                if !content.hint.isEmpty {
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
                }
            }
        case .solid(let strong):
            ZStack {
                ForEach(Array(content.slots.enumerated()), id: \.element.id) { index, item in wedge(item, index: index) }
                middle
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(Circle().strokeBorder(strong ? Color.primary : Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1))
            }
        }
    }

    private func wedge(_ item: RingEntry, index: Int) -> some View {
        let shape = WedgeShape(geometry: geometry, index: index)
        let selected = content.highlighted == index
        return GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size)
            let mid = geometry.midpoint(for: index, in: rect)
            let label = self.label(item, selected: selected)
                .frame(width: geometry.labelWidth)
                .position(mid)
            switch content.style {
            case .glass:
                ZStack {
                    // Chosen: solid emerald, which shows at once and in any window state (a tint on glass greys out while the
                    // panel isn't the active window). Others: glass, dimmed behind their word.
                    shape.fill(selected ? Theme.accent : Color(nsColor: .windowBackgroundColor).opacity(Self.wedgeDimming))
                    label
                }
                    .frame(width: rect.width, height: rect.height)
                    .glassEffect(.regular, in: shape)
            case .solid(let strong):
                ZStack {
                    shape.fill(selected ? Theme.accent : Color(nsColor: .windowBackgroundColor))
                    shape.stroke(strong ? Color.primary : Color(nsColor: .separatorColor), lineWidth: strong ? 1.5 : 1)
                    label
                }
                .frame(width: rect.width, height: rect.height)
            }
        }
    }

    private func label(_ item: RingEntry, selected: Bool) -> some View {
        let dense = content.slots.count > 8
        return VStack(spacing: dense ? 3 : 4) {
            Image(systemName: item.isAvailable ? item.symbol : "arrow.down.circle")
                .font(.system(size: dense ? 16 : 19, weight: .regular))
                .symbolRenderingMode(.monochrome)
            Text(item.shortLabel)
                .font(.system(size: dense ? 10.5 : 11.5, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .foregroundStyle(selected ? Color.white : (item.isAvailable ? Color.primary : Color.secondary))
        .opacity(item.isAvailable || selected ? 1 : 0.6)
    }

    /// The full name of the item under the pointer (and the missing program), shown outside the middle.
    private var highlightedName: (title: String, missing: String?)? {
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
    var slots: [RingEntry] = [] { didSet { refresh() } }
    var title = "" { didSet { refresh() } }
    var files = "" { didSet { refresh() } }
    var hint = "" { didSet { refresh() } }
    var emptyMessage = "" { didSet { refresh() } }
    var presentation = 0 { didSet { refresh() } }
    var center: NSPoint = .zero { didSet { needsLayout = true } }
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
                    presentation: presentation)
    }

    private func refresh() {
        host.rootView = RadialWheelView(content: content)
        accessibilityItems = makeAccessibilityItems()
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
    override func accessibilityChildren() -> [Any]? { accessibilityItems }

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
        highlighted = index(at: convert(point, from: nil))
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
        return highlighted == nil ? [] : Self.operation(for: sender.draggingSourceOperationMask)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        return highlighted == nil ? [] : Self.operation(for: sender.draggingSourceOperationMask)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DragDebug.log("prepareForDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        return highlighted != nil
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
        guard let window, sender != nil, NSEvent.pressedMouseButtons & 1 == 1 else { return }
        if window.frame.insetBy(dx: 1, dy: 1).contains(NSEvent.mouseLocation) {
            onDragSessionEnded?()
        }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlighted = nil
        onDragSessionEnded?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        updateHighlight(forWindowPoint: sender.draggingLocation)
        DragDebug.log("performDragOperation highlighted=\(String(describing: highlighted)) mask=\(sender.draggingSourceOperationMask.rawValue)")
        guard let highlighted, highlighted < slots.count else {
            onCancel?()
            return false
        }
        let item = slots[highlighted]
        let option = NSEvent.modifierFlags.contains(.option)
        DispatchQueue.main.async { [weak self] in self?.onSelect?(item, option) }
        return true
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
        if let highlighted, highlighted < slots.count {
            onSelect?(slots[highlighted], event.modifierFlags.contains(.option))
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
            onCancel?()
        case 36, 76, 49:
            if let highlighted, highlighted < slots.count { onSelect?(slots[highlighted], event.modifierFlags.contains(.option)) }
        case 123, 126:
            step(-1)
        case 124, 125:
            step(1)
        case 48:
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

    func clearHighlight() { highlighted = nil }

    func highlight(_ index: Int) {
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
