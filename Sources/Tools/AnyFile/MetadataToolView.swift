import SwiftUI

@MainActor
struct MetadataToolView: View {
    let session: ToolSession
    @State private var fields: [MetadataField] = []
    @State private var loading = true
    @State private var search = ""
    @State private var removeAll = false
    @State private var removeSensitive = false
    @State private var selectedFile: URL

    init(session: ToolSession) {
        self.session = session
        _selectedFile = State(initialValue: session.primary)
    }

    /// The group names are also the sort keys (English); shown in the app's language.
    static func groupTitle(_ group: String) -> String {
        switch group {
        case "File": return tr("File", "Datei")
        case "Media": return tr("Media", "Medien")
        case "Document": return tr("Document", "Dokument")
        case "Tags": return tr("Tags", "Tags")
        case "Image": return tr("Image", "Bild")
        case "Chapters": return tr("Chapters", "Kapitel")
        default: return group
        }
    }

    private var groups: [(String, [MetadataField])] {
        let filtered = fields.filter { search.isEmpty || $0.key.localizedCaseInsensitiveContains(search) || $0.value.localizedCaseInsensitiveContains(search) || $0.group.localizedCaseInsensitiveContains(search) }
        let order = ["File", "Media", "Document", "Tags", "Image", "Exif", "TIFF", "GPS", "IPTC", "MakerApple", "Chapters"]
        var dict: [String: [MetadataField]] = [:]
        for field in filtered { dict[field.group, default: []].append(field) }
        return dict.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? Int.max
            let ib = order.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }.map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        ToolShell(session: session, saveTitle: session.files.count == 1 ? tr("Save copy", "Kopie sichern") : tr("Apply to \(session.files.count) files", "Auf \(session.files.count) Dateien anwenden"), onSave: run) {
            VStack(spacing: 0) {
                HStack {
                    if session.files.count > 1 {
                        Picker(tr("File", "Datei"), selection: $selectedFile) {
                            ForEach(session.files, id: \.self) { Text($0.lastPathComponent).tag($0) }
                        }
                        .frame(maxWidth: 320)
                    }
                    Spacer()
                    TextField(tr("Search fields", "Felder durchsuchen"), text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                .padding(12)
                Divider()
                if loading {
                    LoadingOrError(error: nil)
                } else if fields.isEmpty {
                    Text(tr("No metadata found.", "Keine Metadaten gefunden.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups, id: \.0) { group, items in
                            Section(Self.groupTitle(group)) {
                                ForEach(items) { field in
                                    row(field)
                                }
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .disabled(removeAll)
                    .opacity(removeAll ? 0.4 : 1)
                }
            }
        } sidebar: {
            SidebarSection(title: tr("Remove", "Entfernen")) {
                Toggle(tr("Remove all metadata", "Alle Metadaten entfernen"), isOn: $removeAll)
                Toggle(tr("Remove camera, GPS and processing data", "Kamera-, GPS- und Bearbeitungsdaten entfernen"), isOn: $removeSensitive).disabled(removeAll)
                Text(tr("Pixel data, page content and audio are untouched. Orientation and color profile are kept.", "Bildinhalt, Seiteninhalt und Ton bleiben unverändert. Ausrichtung und Farbprofil bleiben erhalten."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            SidebarSection(title: tr("Editing", "Bearbeiten")) {
                Text(tr("Editable fields show a text box. Clear a value to remove that field. Changes apply to a new copy; the original stays as is.", "Änderbare Felder haben ein Textfeld. Leere einen Wert, um das Feld zu entfernen. Die Änderungen landen in einer neuen Kopie, das Original bleibt, wie es ist."))
                    .font(.caption2).foregroundStyle(.secondary)
                if session.files.count > 1 {
                    Text(tr("Edited field values are applied to every selected file; removal options apply to all.", "Geänderte Feldwerte gelten für jede ausgewählte Datei, ebenso die Optionen zum Entfernen."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            SidebarSection(title: tr("Summary", "Übersicht")) {
                let sensitive = fields.filter(\.sensitive).count
                Text(tr("\(fields.count) fields · \(sensitive) sensitive", "\(fields.count) Felder · \(sensitive) heikel")).font(.callout.monospacedDigit())
            }
        }
        .task(id: selectedFile) { await load() }
    }

    @ViewBuilder
    private func row(_ field: MetadataField) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 4) {
                if field.sensitive {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
                Text(field.key).font(.callout).frame(width: 200, alignment: .leading).lineLimit(1)
            }
            if field.editable, let index = fields.firstIndex(where: { $0.id == field.id }) {
                TextField("", text: $fields[index].value)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(field.value).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                Spacer()
            }
        }
    }

    private func load() async {
        loading = true
        let url = selectedFile
        let result = await MetadataOps.read(url)
        fields = result
        loading = false
    }

    private func run() {
        session.start(Self.jobs(session, Options(edits: fields.filter(\.editable), removeAll: removeAll, removeSensitive: removeSensitive)))
    }

    struct Options {
        /// The editable fields as shown (and maybe changed) in the window.
        var edits: [MetadataField]
        var removeAll: Bool
        var removeSensitive: Bool
    }

    static func jobs(_ session: ToolSession, _ options: Options) -> [ToolJob] {
        session.files.compactMap { url in
            guard let format = FileFormat.detect(url) else { return nil }
            let base = ConversionMatrix.strippedBaseName(url.lastPathComponent)
            let ext = format.category == .image && !ImageIOBridge.canEncodeNatively(format) ? "png" : url.pathExtension
            let destination = ConversionMatrix.uniqueURL(directory: session.outputDirectory, baseName: base, suffix: options.removeAll ? tr("clean", "bereinigt") : tr("edited", "bearbeitet"), ext: ext)
            return session.job(tr("Editing metadata", "Metadaten werden bearbeitet"), detail: url.lastPathComponent) { progress in
                return [try await StagingArea.writing(destination) { destination in
                    try await MetadataOps.write(url, edits: options.edits, removeAll: options.removeAll, removeSensitive: options.removeSensitive, to: destination, progress: progress)
                }]
            }
        }
    }
}
