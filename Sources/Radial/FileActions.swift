import AppKit
import CommonCrypto
import SwiftUI

/// The actions ring: everyday things to do with files. None of them changes or deletes a file; "Move to …" only moves it where the
/// person chooses. "Float" and "Terminal" have files of their own (`FloatShelf`, `TerminalAction`).
@MainActor
enum FileActions {
    static func perform(_ action: FileAction, on files: [URL], at point: NSPoint) {
        guard !files.isEmpty else { return }
        DiagnosticLog.log("action \(action.rawValue) for \(files.map(\.lastPathComponent))")
        switch action {
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(files)
        case .copyFile:
            copyFiles(files, to: .general)
        case .copyPath:
            copyPaths(files, to: .general)
        case .duplicate:
            duplicate(files)
        case .move:
            chooseFolderAndMove(files)
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                NSSound.beep()
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: files)
        case .share:
            SharePicker.show(files, at: point)
        case .checksum:
            ChecksumPanel.show(files)
        case .float:
            FloatShelf.show(files, at: point)
        case .terminal:
            TerminalAction.perform(files)
        }
    }

    /// An action that has nothing to show when it works (a window opens elsewhere) shows the card only when it can't.
    static func reportFailure(title: String, detail: String, symbol: String, message: String) {
        DiagnosticLog.log("action failed: \(title) / \(detail): \(message)")
        JobRunner.shared.runWithSteps(title: title, detail: detail, symbol: symbol) { _ in throw AppError.invalidInput(message) }
    }

    /// The files themselves, as Finder's Copy puts them: pasting in Finder, Mail or Messages gives the files.
    nonisolated static func copyFiles(_ files: [URL], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(files as [NSURL])
    }

    /// The full paths, one per line.
    nonisolated static func copyPaths(_ files: [URL], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// "Report copy.pdf" ("Bericht Kopie.pdf" in German), like Finder's Duplicate; then "copy 2", "copy 3".
    nonisolated static func duplicateURL(for file: URL) -> URL {
        let folder = file.deletingLastPathComponent()
        guard !file.pathExtension.isEmpty else {
            return ConversionMatrix.uniqueDirectory(directory: folder, name: "\(file.lastPathComponent) \(tr("copy", "Kopie"))")
        }
        return ConversionMatrix.uniqueURL(directory: folder, baseName: ConversionMatrix.strippedBaseName(file.lastPathComponent),
                                          suffix: tr("copy", "Kopie"), ext: file.pathExtension)
    }

    /// The copy is written in the staging area first, so a cancelled or failed copy never leaves half a file next to the original.
    nonisolated static func makeDuplicate(of file: URL) async throws -> URL {
        let destination = duplicateURL(for: file)
        return try await StagingArea.writing(destination) { temp in
            try FileManager.default.copyItem(at: file, to: temp)
        }
    }

    private static func duplicate(_ files: [URL]) {
        for file in files {
            JobRunner.shared.runWithSteps(title: tr("Duplicating", "Duplizieren"), detail: file.lastPathComponent, symbol: FileAction.duplicate.symbol,
                                          outputFolder: file.deletingLastPathComponent(), inputs: [file]) { _ in
                [try await makeDuplicate(of: file)]
            }
        }
    }

    /// Moves the files into a folder; a name that is taken there gets a number, nothing is replaced.
    nonisolated static func move(_ files: [URL], into folder: URL) throws -> [URL] {
        var moved: [URL] = []
        for file in files {
            var target = folder.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                target = file.pathExtension.isEmpty ? ConversionMatrix.uniqueDirectory(directory: folder, name: file.lastPathComponent)
                    : ConversionMatrix.uniqueURL(directory: folder, baseName: ConversionMatrix.strippedBaseName(file.lastPathComponent), suffix: "", ext: file.pathExtension)
            }
            guard target.standardizedFileURL != file.standardizedFileURL else { moved.append(file); continue }
            try FileManager.default.moveItem(at: file, to: target)
            moved.append(target)
        }
        return moved
    }

    private static func chooseFolderAndMove(_ files: [URL]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("Move Here", "Hierher verschieben")
        panel.message = files.count == 1 ? tr("Move \u{201C}\(files[0].lastPathComponent)\u{201D} to:", "\u{201E}\(files[0].lastPathComponent)\u{201C} verschieben nach:")
            : tr("Move \(files.count) files to:", "\(files.count) Dateien verschieben nach:")
        panel.directoryURL = files[0].deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            MainActor.assumeIsolated {
                let job = JobRunner.shared.runWithSteps(title: tr("Moving", "Verschieben"), detail: files.count == 1 ? files[0].lastPathComponent : tr("\(files.count) files", "\(files.count) Dateien"),
                                                        symbol: FileAction.move.symbol, outputFolder: folder, inputs: files) { _ in
                    try await Task.detached { try move(files, into: folder) }.value
                }
                // The result is the original in its new place: "Undo" must never put it in the Trash.
                job.undoable = false
            }
        }
    }
}

/// SHA-256 of a file, read in pieces (large videos don't fill the memory). Stops when the task is cancelled.
enum Checksum {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(chunk.count)) }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A checksum pasted from a web page: spaces, line breaks and capitals don't matter.
    static func matches(_ expected: String, _ actual: String) -> Bool {
        let cleaned = expected.lowercased().filter { $0.isHexDigit }
        return !cleaned.isEmpty && cleaned == actual.lowercased()
    }
}

@MainActor
final class ChecksumModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        let file: URL
        var sum: String?
        var error: String?
    }

    @Published var rows: [Row]
    @Published var expected = ""
    private var task: Task<Void, Never>?

    init(files: [URL]) {
        rows = files.map { Row(file: $0) }
        task = Task { [weak self] in
            guard let self else { return }
            for index in self.rows.indices {
                let file = self.rows[index].file
                let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                    Result { try Checksum.sha256(of: file) }
                }.value
                switch result {
                case .success(let sum): self.rows[index].sum = sum
                case .failure(let error): self.rows[index].error = error.localizedDescription
                }
            }
        }
    }

    func stop() { task?.cancel() }
}

struct ChecksumView: View {
    @ObservedObject var model: ChecksumModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.file.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let sum = row.sum {
                        // One line, never broken: a hyphen in the middle of a checksum would read as part of it.
                        Text(sum)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .textSelection(.enabled)
                            .accessibilityLabel(tr("SHA-256 checksum", "SHA-256-Prüfsumme"))
                        Button(tr("Copy Checksum", "Prüfsumme kopieren")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sum, forType: .string)
                        }
                        if !model.expected.isEmpty {
                            let same = Checksum.matches(model.expected, sum)
                            // The colour only in the symbol: red or green text on the window is too faint to read well.
                            Label {
                                Text(same ? tr("Matches", "Stimmt überein") : tr("Does not match", "Stimmt nicht überein"))
                            } icon: {
                                Image(systemName: same ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(same ? Theme.accentForeground : .red)
                            }
                            .font(.callout)
                        }
                    } else if let error = row.error {
                        Label {
                            Text(error).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        .font(.callout)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(tr("Calculating …", "Wird berechnet …")).foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Compare with", "Vergleichen mit")).font(.callout)
                TextField(tr("Paste the expected checksum", "Erwartete Prüfsumme einfügen"), text: $model.expected)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
            }
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class ChecksumPanel: NSPanel, NSWindowDelegate {
    private var model: ChecksumModel?
    private static var open: [ChecksumPanel] = []

    @MainActor
    static func show(_ files: [URL]) {
        let model = ChecksumModel(files: files)
        let panel = ChecksumPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = tr("Checksum (SHA-256)", "Prüfsumme (SHA-256)")
        followLanguage(panel) { [weak panel] in panel?.title = tr("Checksum (SHA-256)", "Prüfsumme (SHA-256)") }
        panel.model = model
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = panel
        let hosting = NSHostingController(rootView: ChecksumView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.center()
        open.append(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        ChecksumPanel.open.removeAll { $0 === self }
    }
}

/// macOS' share menu (Mail, Messages, Notes …), opened where the files were dropped.
final class SharePicker: NSObject, NSSharingServicePickerDelegate {
    private static var current: SharePicker?
    private let anchor: NSPanel

    private init(at point: NSPoint) {
        anchor = NSPanel(contentRect: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.isOpaque = false
        anchor.backgroundColor = .clear
        anchor.level = .popUpMenu
        super.init()
    }

    @MainActor
    static func show(_ files: [URL], at point: NSPoint) {
        let picker = SharePicker(at: point)
        current = picker
        picker.anchor.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        let service = NSSharingServicePicker(items: files)
        service.delegate = picker
        guard let view = picker.anchor.contentView else { return }
        service.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        anchor.orderOut(nil)
        SharePicker.current = nil
    }
}
