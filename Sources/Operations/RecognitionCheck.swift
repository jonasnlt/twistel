import AppKit
import CoreText

/// Checks once per launch, before the first text recognition, that recognition works: a picture with known lines is
/// read and every line must come back. macOS keeps a prepared recognition model per app
/// (`~/Library/Caches/<app>/com.apple.e5rt.e5bundlecache`); a damaged one once returned only two thirds of the lines
/// without any error. With this check the app says so instead of silently losing text.
actor RecognitionCheck {
    static var shared = RecognitionCheck()

    /// The known lines, drawn into the check picture. Plain, well readable text: if one of them is missing, recognition is broken.
    static let knownLines = [
        "Die Texterkennung prüft sich selbst mit diesem Bild.",
        "Jede Zeile muss vollständig ankommen, auch diese hier.",
        "Größe, Übergabe und Straße: Umlaute gehören dazu.",
        "Invoice 4711, total amount 128.50 EUR",
        "Ein zweiter Absatz beginnt nach einer Lücke.",
        "Kurze Zeile.",
        "Noch eine längere Zeile mit vielen Wörtern, damit die Prüfung nicht zu leicht ist.",
        "Ende der Prüfung.",
    ]

    static var firstFailure: String {
        tr("Text recognition on this Mac returned incomplete results in a self-check, so nothing was saved. "
            + "The prepared recognition model in \(AppIdentity.name) has been reset. Please quit and reopen \(AppIdentity.name), then try again.",
           "Die Texterkennung auf diesem Mac hat bei einer Selbstprüfung unvollständige Ergebnisse geliefert, deshalb wurde nichts gesichert. "
            + "Das vorbereitete Erkennungsmodell in \(AppIdentity.name) wurde zurückgesetzt. Bitte beende \(AppIdentity.name), öffne es wieder und versuch es dann noch einmal.")
    }
    static var repeatedFailure: String {
        tr("Text recognition on this Mac still returns incomplete results after a reset, so nothing was saved. "
            + "Restarting the Mac or updating macOS may help.",
           "Die Texterkennung auf diesem Mac liefert auch nach dem Zurücksetzen unvollständige Ergebnisse, deshalb wurde nichts gesichert. "
            + "Ein Neustart des Macs oder ein macOS-Update kann helfen.")
    }

    private static let resetKey = "recognitionModelWasReset"

    private let read: @Sendable (CGImage) async throws -> [TextRecognizer.Line]
    private let resetModel: @Sendable () -> Void
    private let store: SettingsStore
    private var passed = false
    /// Two jobs may start at once (JobRunner runs two); the second waits for the check the first one started.
    private var running: Task<Void, Error>?

    init(read: @escaping @Sendable (CGImage) async throws -> [TextRecognizer.Line] = { try await TextRecognizer.recognize($0) },
         resetModel: @escaping @Sendable () -> Void = { RecognitionCheck.removeAppModelCache() },
         store: SettingsStore = UserDefaults.standard) {
        self.read = read
        self.resetModel = resetModel
        self.store = store
    }

    /// Returns when recognition works; otherwise throws a message for the progress card.
    func ensureWorking() async throws {
        guard !passed else { return }
        if let running { return try await running.value }
        let task = Task { try await check() }
        running = task
        defer { running = nil }
        try await task.value
    }

    private func check() async throws {
        let lines = try await read(Self.picture())
        if Self.allKnownLinesArrive(in: lines) {
            passed = true
            store.set(false, forKey: Self.resetKey)
            DiagnosticLog.log("recognition self-check passed")
            return
        }
        let wasReset = store.object(forKey: Self.resetKey) as? Bool ?? false
        DiagnosticLog.log("recognition self-check FAILED: \(lines.count) of \(Self.knownLines.count) lines, reset before: \(wasReset)")
        guard !wasReset else { throw AppError.invalidInput(Self.repeatedFailure) }
        resetModel()
        store.set(true, forKey: Self.resetKey)
        throw AppError.invalidInput(Self.firstFailure)
    }

    static func allKnownLinesArrive(in lines: [TextRecognizer.Line]) -> Bool {
        knownLines.allSatisfy { known in lines.contains { similarity($0.text, known) >= 0.8 } }
    }

    /// How alike two lines are, from 0 to 1, ignoring spaces and case.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { !$0.isWhitespace }), y = Array(b.lowercased().filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty else { return x == y ? 1 : 0 }
        var previous = Array(0...y.count), current = previous
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count { current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    /// The known lines, dark on white, at Retina size, with a gap after the fourth line like a new paragraph.
    static func picture() -> CGImage {
        let scale: CGFloat = 2, pointSize: CGFloat = 15
        let lineHeight = pointSize * 1.45 * scale
        let width = 1000 * scale, height = (CGFloat(knownLines.count) * lineHeight + 120 * scale).rounded()
        let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = NSFont.systemFont(ofSize: pointSize * scale)
        var y = height - 50 * scale - lineHeight
        for (index, line) in knownLines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
            context.textPosition = CGPoint(x: 50 * scale, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            y -= lineHeight + (index == 3 ? pointSize * scale : 0)
        }
        return context.makeImage()!
    }

    /// Removes only this app's prepared models; macOS builds new ones at the next launch.
    static func removeAppModelCache() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let folder = caches.appendingPathComponent(bundleID).appendingPathComponent("com.apple.e5rt.e5bundlecache")
        do {
            try FileManager.default.removeItem(at: folder)
            DiagnosticLog.log("recognition model cache removed: \(folder.path)")
        } catch {
            DiagnosticLog.log("recognition model cache not removed: \(error.localizedDescription)")
        }
    }
}
