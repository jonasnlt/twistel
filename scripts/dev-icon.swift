// Draws the debug build's icon: the app icon with a small orange "DEV" label at the bottom, as an .iconset for iconutil.
// Called by scripts/build.sh for "twistel dev" only: swift scripts/dev-icon.swift <AppIcon.icns> <out.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let icon = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("Aufruf: dev-icon.swift AppIcon.icns Ziel.iconset\n".utf8))
    exit(1)
}
let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let side = CGFloat(size)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        // Below 32 pixels the word can't be read: a plain orange dot says the same.
        let label = NSRect(x: side * 0.2, y: side * 0.06, width: side * 0.6, height: side * 0.22)
        NSColor(srgbRed: 0.96, green: 0.45, blue: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: label, xRadius: label.height / 2, yRadius: label.height / 2).fill()
        if size >= 32 {
            let font = NSFont.systemFont(ofSize: label.height * 0.68, weight: .heavy)
            let text = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.white])
            let textSize = text.size()
            text.draw(at: NSPoint(x: label.midX - textSize.width / 2, y: label.midY - textSize.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
