// Writes the layers of the app icon (draft 1, "Segmentring") as SVG for Icon/AppIcon.icon. Run by scripts/icon.sh.
// The ring of the app itself: eight segments, one chosen (it reaches further out), a dot in the middle. Canvas 1024 × 1024, as
// Icon Composer has it for macOS; the system puts the shape, glass, shadow and the dark and tinted looks on top.
import CoreGraphics
import Foundation

let center = CGPoint(x: 512, y: 512)

/// An annular wedge with rounded corners, as in the app's ring.
func wedge(inner: CGFloat, outer: CGFloat, from a0: CGFloat, to a1: CGFloat, gap: CGFloat, round: CGFloat) -> CGPath {
    let r0 = inner + round, r1 = outer - round
    let pad0 = (gap / 2 + round) / r0, pad1 = (gap / 2 + round) / r1
    let core = CGMutablePath()
    core.addArc(center: center, radius: r1, startAngle: a0 + pad1, endAngle: a1 - pad1, clockwise: false)
    core.addArc(center: center, radius: r0, startAngle: a1 - pad0, endAngle: a0 + pad0, clockwise: true)
    core.closeSubpath()
    return core.union(core.copy(strokingWithWidth: round * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
}

/// SVG path data; SVG counts y from the top.
func svgPath(_ path: CGPath) -> String {
    func p(_ point: CGPoint) -> String { String(format: "%.2f %.2f", point.x, 1024 - point.y) }
    var d: [String] = []
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: d.append("M" + p(e.points[0]))
        case .addLineToPoint: d.append("L" + p(e.points[0]))
        case .addQuadCurveToPoint: d.append("Q" + p(e.points[0]) + " " + p(e.points[1]))
        case .addCurveToPoint: d.append("C" + p(e.points[0]) + " " + p(e.points[1]) + " " + p(e.points[2]))
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined(separator: " ")
}

func svg(_ paths: [CGPath], colour: String) -> String {
    let body = paths.map { "  <path fill=\"\(colour)\" d=\"\(svgPath($0))\"/>" }.joined(separator: "\n")
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">\n\(body)\n</svg>\n"
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let emerald = "#0A7C5A"
let n = 8, slice = 2 * CGFloat.pi / CGFloat(n)
var segments: [CGPath] = [], chosen: [CGPath] = []
for i in 0..<n {
    let mid = CGFloat.pi / 2 - CGFloat(i) * slice
    let isChosen = i == 1
    let path = wedge(inner: 196, outer: isChosen ? 372 : 340, from: mid - slice / 2, to: mid + slice / 2, gap: 30, round: 30)
    if isChosen { chosen.append(path) } else { segments.append(path) }
}
let dot = CGPath(ellipseIn: CGRect(x: center.x - 92, y: center.y - 92, width: 184, height: 184), transform: nil)
try svg(segments, colour: emerald).write(to: folder.appendingPathComponent("Segmente.svg"), atomically: true, encoding: .utf8)
try svg(chosen, colour: emerald).write(to: folder.appendingPathComponent("Auswahl.svg"), atomically: true, encoding: .utf8)
try svg([dot], colour: emerald).write(to: folder.appendingPathComponent("Mitte.svg"), atomically: true, encoding: .utf8)
print("Ebenen geschrieben:", folder.path)
