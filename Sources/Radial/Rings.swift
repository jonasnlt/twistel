import AppKit
import Foundation

/// The three rings. Each opens while its keys are held during a file drag (Settings › General).
enum RingKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case convert
    case tools
    case actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return tr("Convert", "Umwandeln")
        case .tools: return tr("Tools", "Werkzeuge")
        case .actions: return tr("Actions", "Aktionen")
        }
    }

    var symbol: String {
        switch self {
        case .convert: return "arrow.triangle.2.circlepath"
        case .tools: return "wrench.and.screwdriver"
        case .actions: return "ellipsis.circle"
        }
    }
}

/// Keys held together while dragging. Option is allowed, but then it can't also mean "run with the last values" for that ring.
struct ModifierCombo: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int

    static let control = ModifierCombo(rawValue: 1)
    static let option = ModifierCombo(rawValue: 2)
    static let shift = ModifierCombo(rawValue: 4)
    static let command = ModifierCombo(rawValue: 8)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(flags: NSEvent.ModifierFlags) {
        var combo: ModifierCombo = []
        if flags.contains(.control) { combo.insert(.control) }
        if flags.contains(.option) { combo.insert(.option) }
        if flags.contains(.shift) { combo.insert(.shift) }
        if flags.contains(.command) { combo.insert(.command) }
        self = combo
    }

    var count: Int { [ModifierCombo.control, .option, .shift, .command].filter(contains).count }

    /// In the order macOS writes them: ⌃⌥⇧⌘.
    var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    /// Spelled out, for menus and VoiceOver.
    var names: String {
        var parts: [String] = []
        if contains(.control) { parts.append(tr("Control", "Control")) }
        if contains(.option) { parts.append(tr("Option", "Wahl")) }
        if contains(.shift) { parts.append(tr("Shift", "Umschalt")) }
        if contains(.command) { parts.append(tr("Command", "Befehl")) }
        return parts.joined(separator: " + ")
    }

    /// What can be chosen for a ring: one key or two together.
    static let choices: [ModifierCombo] = {
        let singles: [ModifierCombo] = [.shift, .command, .control, .option]
        var all = singles
        for (index, first) in singles.enumerated() {
            for second in singles[(index + 1)...] { all.append(first.union(second)) }
        }
        return all
    }()
}

/// Which keys open which ring.
struct RingKeys: Equatable, Codable, Sendable {
    var convert: ModifierCombo = .shift
    var tools: ModifierCombo = .command
    var actions: ModifierCombo = .control

    static let standard = RingKeys()

    func combo(for ring: RingKind) -> ModifierCombo {
        switch ring {
        case .convert: return convert
        case .tools: return tools
        case .actions: return actions
        }
    }

    mutating func set(_ combo: ModifierCombo, for ring: RingKind) {
        switch ring {
        case .convert: convert = combo
        case .tools: tools = combo
        case .actions: actions = combo
        }
    }

    /// No ring without keys, no two rings with the same keys.
    var isValid: Bool {
        let all = RingKind.allCases.map(combo(for:))
        return !all.contains([]) && Set(all).count == all.count
    }

    /// The choices for one ring: keys already used by another ring are left out.
    func choices(for ring: RingKind) -> [ModifierCombo] {
        let taken = Set(RingKind.allCases.filter { $0 != ring }.map(combo(for:)))
        return ModifierCombo.choices.filter { !taken.contains($0) }
    }

    /// The ring for the keys held now: the one whose keys are exactly these, else the one whose keys are all held (the most of
    /// them; with Option added to ⌘ the tools ring stays). Two equally good matches open none.
    func ring(for held: ModifierCombo) -> RingKind? {
        if let exact = RingKind.allCases.first(where: { combo(for: $0) == held }) { return exact }
        let fitting = RingKind.allCases.filter { held.isSuperset(of: combo(for: $0)) }
        guard let best = fitting.map({ combo(for: $0).count }).max() else { return nil }
        let winners = fitting.filter { combo(for: $0).count == best }
        return winners.count == 1 ? winners[0] : nil
    }

    /// Option held at the drop runs a tool with its last values, unless Option is one of the ring's own keys.
    func wantsQuickRun(ring: RingKind, held: ModifierCombo) -> Bool {
        held.contains(.option) && !combo(for: ring).contains(.option)
    }

    /// The line at the bottom of a ring: the other rings and their keys, e.g. "⌘ Tools · ⌃ Actions".
    func hint(besides ring: RingKind) -> String {
        RingKind.allCases.filter { $0 != ring }.map { "\(combo(for: $0).symbols) \($0.title)" }.joined(separator: " · ")
    }
}

/// What the actions ring can do with any file. Deleting is left out on purpose. The order is the app's own (Settings, "More …"):
/// "Float" took the place of "Duplicate", which went to the end with "Terminal".
enum FileAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case reveal
    case copyFile
    case copyPath
    case float
    case move
    case airDrop
    case share
    case checksum
    case duplicate
    case terminal

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .reveal: return tr("Finder", "Finder")
        case .copyFile: return tr("Copy", "Kopieren")
        case .copyPath: return tr("Path", "Pfad")
        case .duplicate: return tr("Duplicate", "Duplizieren")
        case .move: return tr("Move", "Verschieben")
        case .airDrop: return "AirDrop"
        case .share: return tr("Share", "Teilen")
        case .checksum: return tr("Checksum", "Prüfsumme")
        case .float: return tr("Float", "Anheften")
        case .terminal: return "Terminal"
        }
    }

    var title: String {
        switch self {
        case .reveal: return tr("Show in Finder", "Im Finder zeigen")
        case .copyFile: return tr("Copy file", "Datei kopieren")
        case .copyPath: return tr("Copy path", "Pfad kopieren")
        case .duplicate: return tr("Duplicate", "Duplizieren")
        case .move: return tr("Move to …", "Verschieben nach …")
        case .airDrop: return tr("Send with AirDrop", "Mit AirDrop senden")
        case .share: return tr("Share (Mail, Messages …)", "Teilen (Mail, Nachrichten …)")
        case .checksum: return tr("Checksum (SHA-256)", "Prüfsumme (SHA-256)")
        case .float: return tr("Float in a window", "In einem schwebenden Fenster anheften")
        case .terminal: return tr("Open in Terminal", "Im Terminal öffnen")
        }
    }

    var symbol: String {
        switch self {
        case .reveal: return "folder"
        case .copyFile: return "doc.on.doc"
        case .copyPath: return "link"
        case .duplicate: return "plus.square.on.square"
        case .move: return "folder.badge.plus"
        case .airDrop: return "airplayaudio"
        case .share: return "square.and.arrow.up"
        case .checksum: return "number.square"
        case .float: return "pin"
        case .terminal: return "terminal"
        }
    }
}

/// Kinds of files that get their own favourites.
enum FileKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case image, pdf, text, spreadsheet, presentation, video, audio, subtitle, archive
    /// The actions ring has one list for every file.
    case any

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return tr("Images", "Bilder")
        case .pdf: return "PDF"
        case .text: return tr("Word and text", "Word und Text")
        case .spreadsheet: return tr("Spreadsheets", "Tabellen")
        case .presentation: return tr("Presentations", "Präsentationen")
        case .video: return tr("Video", "Video")
        case .audio: return tr("Audio", "Audio")
        case .subtitle: return tr("Subtitles", "Untertitel")
        case .archive: return tr("Archives", "Archive")
        case .any: return tr("All files", "Alle Dateien")
        }
    }

    static func of(_ format: FileFormat) -> FileKind {
        switch format.category {
        case .image: return .image
        case .video: return .video
        case .audio: return .audio
        case .subtitle: return .subtitle
        case .archive: return .archive
        case .document:
            if format == .pdf { return .pdf }
            if FileFormat.spreadsheets.contains(format) { return .spreadsheet }
            if FileFormat.presentations.contains(format) { return .presentation }
            return .text
        }
    }

    /// The kind whose favourites a selection uses: the common one, else the first file's.
    static func common(_ formats: [FileFormat]) -> FileKind? {
        guard let first = formats.first else { return nil }
        return of(first)
    }

    /// The formats of this kind, to work out what its rings can offer.
    var formats: [FileFormat] {
        FileFormat.allCases.filter { FileKind.of($0) == self }
    }

    /// The kinds that have a list in a ring's settings.
    static func kinds(for ring: RingKind) -> [FileKind] {
        switch ring {
        case .convert: return [.image, .pdf, .text, .spreadsheet, .presentation, .video, .audio, .subtitle, .archive]
        case .tools: return [.pdf, .image, .video, .audio]
        case .actions: return [.any]
        }
    }
}

/// One thing a ring can offer.
enum RingEntryID: Hashable, Sendable {
    case convert(FileFormat)
    case tool(ToolID)
    case action(FileAction)
    case more

    /// Kept in the settings, e.g. "convert.jpg", "tool.compress", "action.reveal".
    var key: String {
        switch self {
        case .convert(let format): return "convert.\(format.rawValue)"
        case .tool(let tool): return "tool.\(tool.rawValue)"
        case .action(let action): return "action.\(action.rawValue)"
        case .more: return "more"
        }
    }

    init?(key: String) {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            if key == "more" { self = .more; return }
            return nil
        }
        switch parts[0] {
        case "convert": guard let format = FileFormat(rawValue: parts[1]) else { return nil }; self = .convert(format)
        case "tool": guard let tool = ToolID(rawValue: parts[1]) else { return nil }; self = .tool(tool)
        case "action": guard let action = FileAction(rawValue: parts[1]) else { return nil }; self = .action(action)
        default: return nil
        }
    }
}

/// An item as the ring shows it.
struct RingEntry: Identifiable, Hashable {
    let id: RingEntryID
    /// Under the symbol in the ring: one short word.
    let shortLabel: String
    /// In the middle of the ring while the pointer is on it, in lists and for VoiceOver.
    let title: String
    let symbol: String
    /// A helper program it cannot do without and that is not installed: the item is grey.
    var missing: HelperProgram?

    var isAvailable: Bool { missing == nil }
}

/// The short words and full names of what the rings offer, in both languages.
enum RingWords {
    static func formatLabel(_ format: FileFormat) -> String {
        switch format {
        case .md: return "MD"
        case .gz: return "TAR.GZ"
        default: return format.displayName
        }
    }

    static func convertTitle(_ target: FileFormat, from sources: [FileFormat]) -> String {
        let name = formatLabel(target)
        if target == .docx, !sources.isEmpty, sources.allSatisfy({ $0.category == .image }) {
            return tr("Convert to \(name) (with text recognition)", "In \(name) umwandeln (mit Texterkennung)")
        }
        return tr("Convert to \(name)", "In \(name) umwandeln")
    }

    static func toolLabel(_ tool: ToolID) -> String {
        switch tool {
        case .compress: return tr("Compress", "Verkleinern")
        case .editMetadata: return tr("Metadata", "Metadaten")
        case .recognizeText: return tr("OCR", "Texterkennung")
        case .readQR: return tr("QR code", "QR-Code")
        case .editImage: return tr("Adjust", "Anpassen")
        case .frameImage: return tr("Background", "Hintergrund")
        case .cropImage, .cropVideo: return tr("Crop", "Zuschneiden")
        case .redactImage, .redactVideo, .redactPDF: return tr("Redact", "Schwärzen")
        case .resizeImage: return tr("Resize", "Größe")
        case .rotateImage: return tr("Rotate", "Drehen")
        case .createPDF: return tr("Combine", "Zu PDF")
        case .createCollage: return tr("Collage", "Collage")
        case .trimVideo, .trimAudio: return tr("Trim", "Kürzen")
        case .changeVideoSpeed: return tr("Speed", "Tempo")
        case .joinVideos: return tr("Join", "Verbinden")
        case .videoSnapshots: return tr("Frames", "Standbilder")
        case .splitVideo, .splitPDF: return tr("Split", "Aufteilen")
        case .normalizeAudio: return tr("Normalize", "Angleichen")
        case .audioToVideo: return tr("Visualize", "Visualisieren")
        case .audioChannels: return tr("Channels", "Kanäle")
        case .redactAudio: return tr("Bleep", "Zensieren")
        case .transcribe: return tr("Transcribe", "Transkript")
        case .mergePDF: return tr("Merge", "Verbinden")
        case .organizePDF: return tr("Organize", "Ordnen")
        case .extractImages: return tr("Images", "Bilder")
        case .pdfPassword: return tr("Password", "Passwort")
        case .watermarkPDF: return tr("Watermark", "Wasserzeichen")
        case .pageNumbersPDF: return tr("Numbering", "Seitenzahlen")
        case .socialMedia, .videoPresets: return tr("Social", "Social")
        case .removeBackground: return tr("Cutout", "Freistellen")
        case .pdfArchive: return "PDF/A"
        case .annotate: return tr("Annotate", "Annotieren")
        case .signPDF: return tr("Sign", "Signieren")
        case .comparePDF: return tr("Compare", "Vergleichen")
        case .burnSubtitles: return tr("Subtitles", "Untertitel")
        }
    }

    static var moreLabel: String { tr("More …", "Mehr …") }
    static var moreTitle: String { tr("More (list with search)", "Mehr (Liste mit Suche)") }
}

/// What a ring offers for some files, and which of it is a favourite.
enum RingCatalog {
    /// Everything the ring can do for these files, in the app's own order.
    static func applicable(_ ring: RingKind, for formats: [FileFormat]) -> [RingEntryID] {
        guard !formats.isEmpty else { return [] }
        switch ring {
        case .convert: return ConversionMatrix.targets(for: formats).map(RingEntryID.convert)
        case .tools: return ToolID.available(for: formats).map(RingEntryID.tool)
        case .actions: return FileAction.allCases.map(RingEntryID.action)
        }
    }

    /// Everything the ring can offer for any file of a kind (the lists in Settings).
    static func offered(_ ring: RingKind, for kind: FileKind) -> [RingEntryID] {
        switch ring {
        case .actions: return FileAction.allCases.map(RingEntryID.action)
        case .convert:
            var seen = Set<FileFormat>()
            return kind.formats.flatMap { ConversionMatrix.targets(for: $0) }.filter { seen.insert($0).inserted }.map(RingEntryID.convert)
        case .tools:
            // One file and several: some tools need two or more.
            let formats = kind.formats
            return ToolID.allCases.filter { tool in
                formats.contains { tool.applies(to: [$0]) || tool.applies(to: [$0, $0]) }
            }.map(RingEntryID.tool)
        }
    }

    static func entry(_ id: RingEntryID, for formats: [FileFormat]) -> RingEntry {
        switch id {
        case .convert(let target):
            return RingEntry(id: id, shortLabel: RingWords.formatLabel(target), title: RingWords.convertTitle(target, from: formats),
                             symbol: target.category == .document && target != .pdf ? "doc.text" : (target == .pdf ? "doc.richtext" : target.category.symbol),
                             missing: HelperPrograms.missing(forConverting: formats, to: target))
        case .tool(let tool):
            return RingEntry(id: id, shortLabel: RingWords.toolLabel(tool), title: tool.title, symbol: tool.symbol, missing: HelperPrograms.missing(forTool: tool))
        case .action(let action):
            return RingEntry(id: id, shortLabel: action.shortLabel, title: action.title, symbol: action.symbol, missing: nil)
        case .more:
            return RingEntry(id: .more, shortLabel: RingWords.moreLabel, title: RingWords.moreTitle, symbol: "ellipsis", missing: nil)
        }
    }

    /// The favourites a new installation starts with. Kinds without a list there start with everything.
    static func defaultFavorites(_ ring: RingKind, for kind: FileKind) -> [RingEntryID] {
        switch (ring, kind) {
        case (.convert, .image): return [.jpg, .png, .heic, .webp, .pdf, .docx].map(RingEntryID.convert)
        case (.convert, .pdf): return [.docx, .jpg, .png, .txt, .md, .xlsx].map(RingEntryID.convert)
        case (.convert, .text): return [.pdf, .docx, .txt, .md].map(RingEntryID.convert)
        case (.convert, .video): return [.mp4, .mov, .gif, .mp3].map(RingEntryID.convert)
        case (.convert, .audio): return [.mp3, .m4a, .wav].map(RingEntryID.convert)
        case (.tools, .pdf): return [.compress, .mergePDF, .organizePDF, .signPDF, .redactPDF, .recognizeText, .annotate].map(RingEntryID.tool)
        case (.tools, .image): return [.socialMedia, .compress, .cropImage, .resizeImage, .removeBackground, .annotate, .redactImage].map(RingEntryID.tool)
        case (.tools, .video): return [.trimVideo, .videoPresets, .compress, .burnSubtitles, .transcribe].map(RingEntryID.tool)
        case (.tools, .audio): return [.transcribe, .trimAudio, .compress, .normalizeAudio].map(RingEntryID.tool)
        // Seven places and "More …": Checksum, Duplicate and Terminal are behind "More …".
        case (.actions, .any): return [.reveal, .copyFile, .copyPath, .float, .move, .airDrop, .share].map(RingEntryID.action)
        default: return offered(ring, for: kind)
        }
    }

    /// What comes after the favourites, in this order (the concept names it for PDF tools; elsewhere the app's own order).
    static func defaultRest(_ ring: RingKind, for kind: FileKind) -> [RingEntryID] {
        let named: [RingEntryID]
        switch (ring, kind) {
        case (.tools, .pdf): named = [.splitPDF, .pdfPassword, .watermarkPDF, .pageNumbersPDF, .pdfArchive, .comparePDF, .extractImages].map(RingEntryID.tool)
        default: named = []
        }
        let favorites = defaultFavorites(ring, for: kind)
        return named + offered(ring, for: kind).filter { !favorites.contains($0) && !named.contains($0) }
    }

    /// The concept's favourites are made for 8 places (7 + "More …"). With 10 places the next two of the rest join them, so a new ring
    /// has no gaps; with 6 the ring shows the first 5 (`RingBuilder`).
    static func defaultList(_ ring: RingKind, for kind: FileKind, count: Int = RingBuilder.standardCount) -> FavoriteList {
        let favorites = defaultFavorites(ring, for: kind)
        let rest = defaultRest(ring, for: kind)
        let extra = max(0, count - RingBuilder.standardCount)
        return FavoriteList(order: (favorites + rest).map(\.key), enabled: Set((favorites + rest.prefix(extra)).map(\.key)))
    }
}

extension RingCatalog {
    /// The actions ring as every installation had it before "Float" and "Terminal" (all eight, in their old order). A saved list
    /// that is still exactly this was never changed by hand, so it gives way to the new start values (`AppSettings`).
    static let oldActionsDefault = FavoriteList(order: ["reveal", "copyFile", "copyPath", "duplicate", "move", "airDrop", "share", "checksum"].map { "action.\($0)" },
                                                enabled: Set(["reveal", "copyFile", "copyPath", "duplicate", "move", "airDrop", "share", "checksum"].map { "action.\($0)" }))
}

/// The favourites of one ring for one kind of file: all items in the chosen order, and which of them are in the ring.
struct FavoriteList: Codable, Equatable, Sendable {
    var order: [String]
    var enabled: Set<String>

    /// Items the app offers now but the saved list doesn't know (a newer version): added at the end, not in the ring.
    func completed(with offered: [RingEntryID]) -> FavoriteList {
        var list = self
        let known = Set(order)
        list.order += offered.map(\.key).filter { !known.contains($0) }
        return list
    }

    var favorites: [RingEntryID] { order.filter(enabled.contains).compactMap(RingEntryID.init(key:)) }
}

/// What one ring shows: its slots (with "More …" last when there is more), and the full list behind "More …".
struct RingLayout: Equatable {
    var slots: [RingEntry]
    var all: [RingEntry]

    static let empty = RingLayout(slots: [], all: [])
}

enum RingBuilder {
    /// Places in a ring: Settings › General offers these.
    static let countChoices = [6, 8, 10]
    static let standardCount = 8

    /// The ring's favourites that apply to these files, in their fixed order. When anything else applies, or there are more
    /// favourites than places, the last place is "More …". Nothing moves on its own.
    static func layout(_ ring: RingKind, for formats: [FileFormat], count: Int, favorites: FavoriteList?) -> RingLayout {
        let applicable = RingCatalog.applicable(ring, for: formats)
        guard !applicable.isEmpty else { return .empty }
        let kind = ring == .actions ? FileKind.any : (FileKind.common(formats) ?? .any)
        let list = (favorites ?? RingCatalog.defaultList(ring, for: kind, count: count)).completed(with: RingCatalog.offered(ring, for: kind))
        let available = Set(applicable)
        let chosen = list.favorites.filter(available.contains)
        let places = max(2, count)
        let needsMore = chosen.count > places || applicable.contains { !chosen.contains($0) }
        let shown = needsMore ? Array(chosen.prefix(places - 1)) : chosen
        var slots = shown.map { RingCatalog.entry($0, for: formats) }
        if needsMore { slots.append(RingCatalog.entry(.more, for: formats)) }
        let all = applicable.map { RingCatalog.entry($0, for: formats) }
        return RingLayout(slots: slots, all: all)
    }

    /// The "More …" list filtered by what was typed: every word must appear in the full name or the short word.
    static func filter(_ entries: [RingEntry], by text: String) -> [RingEntry] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = (entry.title + " " + entry.shortLabel).lowercased()
            return words.allSatisfy { haystack.localizedStandardContains($0) }
        }
    }
}
