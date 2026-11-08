import AppKit
import SwiftUI

/// What is drawn so far, what is selected, and what a press, a drag and the keys do with it. Without any view: a mouse and a test take the same way.
final class AnnotateBoard: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, arrow, text, rectangle, ellipse, pen, highlighter, number, magnifier

        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return tr("Select", "Auswählen")
            case .arrow: return tr("Arrow", "Pfeil")
            case .text: return tr("Text", "Text")
            case .rectangle: return tr("Rectangle", "Rechteck")
            case .ellipse: return tr("Ellipse", "Ellipse")
            case .pen: return tr("Pen", "Stift")
            case .highlighter: return tr("Highlighter", "Textmarker")
            case .number: return tr("Number", "Nummer")
            case .magnifier: return tr("Magnifier", "Lupe")
            }
        }
        var key: Character {
            switch self {
            case .select: return "v"
            case .arrow: return "a"
            case .text: return "t"
            case .rectangle: return "r"
            case .ellipse: return "o"
            case .pen: return "p"
            case .highlighter: return "h"
            case .number: return "n"
            case .magnifier: return "m"
            }
        }
        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .arrow: return "arrow.up.right"
            case .text: return "textformat"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .pen: return "pencil.and.scribble"
            case .highlighter: return "highlighter"
            case .number: return "1.circle"
            case .magnifier: return "magnifyingglass.circle"
            }
        }
        var kind: Mark.Kind? { Mark.Kind(rawValue: rawValue) }
    }

    @Published private(set) var marks: [Mark] = []
    @Published var tool = Tool.arrow { didSet { if tool != oldValue { live = nil } } }
    @Published var selected: UUID?
    @Published var page = 0 { didSet { if page != oldValue { selected = nil; finishEditing() } } }
    /// Being drawn right now.
    @Published private(set) var live: Mark?
    /// A text being written; a text already there is not painted meanwhile.
    @Published private(set) var editing: Mark?

    @Published var color = MarkColor.red
    @Published var highlighterColor = MarkColor.yellow
    /// As on an A4 page, whatever the size of the picture.
    @Published var lineWidth: CGFloat = 3
    @Published var highlighterWidth: CGFloat = 16
    @Published var fontSize: CGFloat = 16
    @Published var zoom: CGFloat = 2

    /// The size of the page on the board, for keeping marks on it. Set by the view.
    var pageSize = CGSize(width: 595, height: 842)
    /// Picture pixels for one point on an A4 page: a line looks the same on a screenshot and on a 12-megapixel photo. 1 on a PDF.
    var unit: CGFloat = 1
    /// How many of the page's units one point on the screen is; a click is that precise.
    var pointSize: CGFloat = 1
    /// Set by the view; the arrow keys turn pages within it.
    var pageCount = 1
    /// The tools a window offers; the keys of others do nothing there.
    var offeredTools = Tool.allCases

    private var undoStack: [[Mark]] = []
    private var redoStack: [[Mark]] = []
    /// Moving a slider many times is one step back.
    private var openStep: String?

    private enum Drag {
        case none
        case drawing(start: CGPoint)
        case moving(original: Mark, start: CGPoint)
        case resizing(original: Mark, handle: Int)
    }
    private var drag = Drag.none
    private var dragChanged = false
    private var lastPress: (time: TimeInterval, id: UUID)?

    init(marks: [Mark] = []) { self.marks = marks }

    /// Only for showing a window in a given state (test access).
    func setMarksForDrawing(_ new: [Mark]) { marks = new }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selectedMark: Mark? { marks.first { $0.id == selected } }
    var marksOnPage: [Mark] { marks.filter { $0.page == page && $0.id != editing?.id } }

    private var handleReach: CGFloat { 9 * pointSize }
    private var clickReach: CGFloat { 6 * pointSize }
    private var pageBox: CGRect { CGRect(origin: .zero, size: pageSize) }

    /// The size of what the board shows, for the sliders' values; marks store it in their own unit.
    var shownLineWidth: CGFloat {
        if let mark = selectedMark { return mark.lineWidth / unit }
        return tool == .highlighter ? highlighterWidth : lineWidth
    }
    var isHighlighting: Bool { selectedMark?.kind == .highlighter || (selectedMark == nil && tool == .highlighter) }
    var shownColor: MarkColor {
        if let mark = selectedMark { return mark.color }
        return tool == .highlighter ? highlighterColor : color
    }
    var shownFontSize: CGFloat {
        if let mark = selectedMark, mark.kind == .text { return mark.fontSize / unit }
        return fontSize
    }
    var shownZoom: CGFloat {
        if let mark = selectedMark, mark.kind == .magnifier { return mark.zoom }
        return zoom
    }

    // MARK: Style

    func setColor(_ new: MarkColor) {
        if isHighlighting { highlighterColor = new } else { color = new }
        changeSelected("color") { $0.color = new }
    }

    func setLineWidth(_ new: CGFloat) {
        if isHighlighting { highlighterWidth = new } else { lineWidth = new }
        changeSelected("line") { $0.lineWidth = new * self.unit }
    }

    func setFontSize(_ new: CGFloat) {
        fontSize = new
        changeSelected("font") { mark in
            guard mark.kind == .text else { return }
            mark.fontSize = new * self.unit
            mark.frame.size = self.fittedText(mark)
        }
    }

    func setZoom(_ new: CGFloat) {
        zoom = new
        changeSelected("zoom") { $0.zoom = new }
    }

    private func changeSelected(_ step: String, _ change: (inout Mark) -> Void) {
        guard let index = marks.firstIndex(where: { $0.id == selected }) else { return }
        var copy = marks[index]
        change(&copy)
        guard copy != marks[index] else { return }
        if openStep != step { rememberForUndo() }
        marks[index] = copy
        openStep = step
    }

    // MARK: Mouse

    func press(at point: CGPoint, time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        finishEditing()
        openStep = nil
        dragChanged = false
        drag = .none
        if let mark = selectedMark, mark.page == page, let handle = mark.handles.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= handleReach }) {
            drag = .resizing(original: mark, handle: handle)
            return
        }
        let hit = marksOnPage.last { $0.isHit(by: point, tolerance: clickReach) }
        if tool == .text, let hit, hit.kind == .text {
            beginEditing(hit)
            return
        }
        if let hit, tool == .select || hit.id == selected {
            if let last = lastPress, last.id == hit.id, time - last.time < 0.4, hit.kind == .text {
                lastPress = nil
                beginEditing(hit)
                return
            }
            lastPress = (time, hit.id)
            selected = hit.id
            drag = .moving(original: hit, start: point)
            return
        }
        lastPress = nil
        selected = nil
        guard let kind = tool.kind else { return }
        let inside = clamped(point)
        drag = .drawing(start: inside)
        switch kind {
        case .text:
            let height = MarkPainter.textSize("", fontSize: fontSize * unit, width: 100 * unit).height
            editing = Mark(kind: .text, page: page, frame: CGRect(x: inside.x, y: inside.y - height / 2, width: 0, height: height), color: color, fontSize: fontSize * unit)
            drag = .none
        case .number:
            let size = max(fontSize * 1.6, 20) * unit
            live = Mark(kind: .number, page: page, frame: CGRect(x: inside.x - size / 2, y: inside.y - size / 2, width: size, height: size), color: color, lineWidth: lineWidth * unit)
        case .magnifier:
            let size = 110 * unit
            live = Mark(kind: .magnifier, page: page, frame: CGRect(x: inside.x - size / 2, y: inside.y - size / 2, width: size, height: size), color: color, lineWidth: lineWidth * unit, zoom: zoom)
        case .arrow:
            live = Mark(kind: .arrow, page: page, points: [inside, inside], color: color, lineWidth: lineWidth * unit)
        case .rectangle, .ellipse:
            live = Mark(kind: kind, page: page, frame: CGRect(origin: inside, size: .zero), color: color, lineWidth: lineWidth * unit)
        case .pen:
            live = Mark(kind: .pen, page: page, points: [inside], color: color, lineWidth: lineWidth * unit)
        case .highlighter:
            live = Mark(kind: .highlighter, page: page, points: [inside], color: highlighterColor, lineWidth: highlighterWidth * unit)
        case .picture:
            drag = .none
        }
    }

    func dragged(to point: CGPoint) {
        switch drag {
        case .none: return
        case .drawing(let start):
            guard var mark = live else { return }
            let inside = clamped(point)
            switch mark.kind {
            case .arrow: mark.points[1] = inside
            case .rectangle, .ellipse: mark.frame = CGRect(x: min(start.x, inside.x), y: min(start.y, inside.y), width: abs(inside.x - start.x), height: abs(inside.y - start.y))
            case .pen, .highlighter:
                // Points closer than a point on the screen add nothing.
                if let last = mark.points.last, hypot(last.x - inside.x, last.y - inside.y) >= pointSize { mark.points.append(inside) }
            case .number:
                let size = mark.frame.width
                mark.frame.origin = CGPoint(x: inside.x - size / 2, y: inside.y - size / 2)
            case .magnifier:
                let radius = max(hypot(inside.x - start.x, inside.y - start.y), 55 * unit)
                mark.frame = CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
            case .text, .picture: break
            }
            live = mark
        case .moving(let original, let start):
            var delta = CGSize(width: point.x - start.x, height: point.y - start.y)
            if abs(delta.width) < pointSize, abs(delta.height) < pointSize, !dragChanged { return }
            let box = original.bounds
            delta.width = min(max(delta.width, -box.minX), pageSize.width - box.maxX)
            delta.height = min(max(delta.height, -box.minY), pageSize.height - box.maxY)
            replace(original.moved(by: delta))
        case .resizing(let original, let handle):
            replace(original.resized(handle: handle, to: clamped(point), minimum: 8 * pointSize))
        }
    }

    func released() {
        defer { drag = .none }
        guard case .drawing = drag, let mark = live else { return }
        live = nil
        let big = mark.bounds.width >= 4 * pointSize || mark.bounds.height >= 4 * pointSize
        switch mark.kind {
        case .arrow, .rectangle, .ellipse: guard big else { return }
        default: break
        }
        rememberForUndo()
        marks.append(mark)
        renumber()
        // A pen goes on drawing; what could be adjusted right away is selected.
        if mark.kind != .pen, mark.kind != .highlighter { selected = mark.id }
    }

    private func replace(_ mark: Mark) {
        guard let index = marks.firstIndex(where: { $0.id == mark.id }), marks[index] != mark else { return }
        if !dragChanged { rememberForUndo() }
        dragChanged = true
        marks[index] = mark
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), pageSize.width), y: min(max(point.y, 0), pageSize.height))
    }

    // MARK: Adding without the mouse

    /// A signature or a date: placed low in the middle of the page and selected, to be dragged to where it belongs.
    func place(_ mark: Mark) {
        var new = mark
        new.page = page
        finishEditing()
        rememberForUndo()
        openStep = nil
        marks.append(new)
        selected = new.id
        tool = .select
    }

    /// The selected mark on all the other pages too, at the same place: initials on each page.
    func copySelectedToAllPages() {
        guard let mark = selectedMark else { return }
        rememberForUndo()
        openStep = nil
        for other in 0..<pageCount where other != mark.page {
            var copy = mark
            copy.id = UUID()
            copy.page = other
            marks.append(copy)
        }
    }

    // MARK: Text

    func beginEditing(_ mark: Mark) {
        selected = nil
        tool = tool == .text ? .text : .select
        editing = mark
    }

    func setEditedText(_ text: String) {
        editing?.text = text
    }

    /// An empty text is no mark. Called whenever something else is clicked, too.
    func finishEditing() {
        guard var mark = editing else { return }
        editing = nil
        let index = marks.firstIndex { $0.id == mark.id }
        guard !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let index {
                rememberForUndo()
                marks.remove(at: index)
            }
            return
        }
        if index == nil || mark.frame.width == 0 { mark.frame.size.width = longestWidth(for: mark) }
        mark.frame.size = fittedText(mark)
        if mark.frame.maxY > pageSize.height { mark.frame.origin.y = max(0, pageSize.height - mark.frame.height) }
        if let index {
            guard marks[index] != mark else { return }
            rememberForUndo()
            marks[index] = mark
        } else {
            rememberForUndo()
            marks.append(mark)
        }
        selected = mark.id
    }

    /// As wide as the longest line, up to the edge of the page.
    private func longestWidth(for mark: Mark) -> CGFloat {
        min(MarkPainter.textSize(mark.text, fontSize: mark.fontSize, width: .greatestFiniteMagnitude).width, max(pageSize.width - mark.frame.minX, 40 * unit))
    }

    private func fittedText(_ mark: Mark) -> CGSize {
        let width = max(mark.frame.width, 20 * unit)
        return CGSize(width: width, height: MarkPainter.textSize(mark.text, fontSize: mark.fontSize, width: width).height)
    }

    // MARK: Steps

    func deleteSelected() {
        guard let id = selected, marks.contains(where: { $0.id == id }) else { return }
        rememberForUndo()
        marks.removeAll { $0.id == id }
        selected = nil
        renumber()
    }

    func nudge(_ delta: CGSize) {
        guard let mark = selectedMark else { return }
        openStep == "nudge" ? () : rememberForUndo()
        openStep = "nudge"
        marks[marks.firstIndex { $0.id == mark.id }!] = mark.moved(by: CGSize(width: delta.width * unit, height: delta.height * unit))
    }

    func undo() {
        finishEditing()
        guard let last = undoStack.popLast() else { return }
        redoStack.append(marks)
        restore(last)
    }

    func redo() {
        finishEditing()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(marks)
        restore(next)
    }

    private func restore(_ state: [Mark]) {
        marks = state
        openStep = nil
        if !marks.contains(where: { $0.id == selected }) { selected = nil }
        objectWillChange.send()
    }

    private func rememberForUndo() {
        undoStack.append(marks)
        redoStack.removeAll()
    }

    /// 1, 2, 3 in the order they were placed, over all pages and without gaps.
    private func renumber() {
        var next = 1
        for index in marks.indices where marks[index].kind == .number {
            marks[index].number = next
            next += 1
        }
    }


    // MARK: Keys

    enum Command: Equatable {
        case tool(Tool), undo, redo, delete, deselect, nudge(CGSize), previousPage, nextPage
    }

    /// What a key means when no text is being written. nil: not ours.
    static func command(characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, selection: Bool) -> Command? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        let lower = characters.lowercased()
        if flags == .command, lower == "z" { return .undo }
        if flags == [.command, .shift], lower == "z" { return .redo }
        let step: CGFloat = flags == .shift ? 10 : 1
        guard flags.isEmpty || flags == .shift else { return nil }
        switch keyCode {
        case 51, 117: return selection ? .delete : nil
        case 53: return .deselect
        case 123: return selection ? .nudge(CGSize(width: -step, height: 0)) : .previousPage
        case 124: return selection ? .nudge(CGSize(width: step, height: 0)) : .nextPage
        case 125: return selection ? .nudge(CGSize(width: 0, height: step)) : .nextPage
        case 126: return selection ? .nudge(CGSize(width: 0, height: -step)) : .previousPage
        default: break
        }
        guard flags.isEmpty, let key = lower.first, lower.count == 1, let tool = Tool.allCases.first(where: { $0.key == key }) else { return nil }
        return .tool(tool)
    }

    func perform(_ command: Command) {
        switch command {
        case .tool(let new):
            guard offeredTools.contains(new) else { return }
            finishEditing()
            selected = nil
            tool = new
        case .undo: undo()
        case .redo: redo()
        case .delete: deleteSelected()
        case .deselect:
            if editing != nil { finishEditing() } else if selected != nil { selected = nil } else { tool = .select }
        case .nudge(let delta): nudge(delta)
        case .previousPage: if page > 0 { page -= 1 }
        case .nextPage: if page < pageCount - 1 { page += 1 }
        }
    }
}
