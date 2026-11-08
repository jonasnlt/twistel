import SwiftUI

/// What to look for, and the list of what was found. Nothing is blacked out until it is ticked here and the main button is pressed.
@MainActor
final class RedactionSearch: ObservableObject {
    @Published var termsText = ""
    @Published var patterns: Set<RedactionFinder.Pattern> = []
    @Published var faces = false
    @Published var finds: [RedactionFinder.Find] = []
    @Published var ticked: Set<UUID> = []
    @Published var status: String?
    @Published var running = false
    @Published var searched = false
    @Published var unreadPages: [Int] = []
    private var task: Task<Void, Never>?

    var request: RedactionFinder.Request {
        .init(terms: termsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, patterns: patterns, faces: faces)
    }
    var chosen: [RedactionFinder.Find] { finds.filter { ticked.contains($0.id) } }
    var left: [RedactionFinder.Find] { finds.filter { !ticked.contains($0.id) } }

    func start(_ work: @escaping @Sendable (RedactionFinder.Request, @escaping @Sendable (Int, Int) -> Void) async throws -> RedactionFinder.Result) {
        task?.cancel()
        let request = request
        running = true
        status = tr("Looking …", "Sucht …")
        task = Task { [weak self] in
            let owner = self
            let job = Task.detached {
                try await work(request) { page, pages in
                    Task { @MainActor in owner?.status = tr("Looking at page \(page) of \(pages)", "Durchsucht Seite \(page) von \(pages)") }
                }
            }
            let outcome = await withTaskCancellationHandler { await job.result } onCancel: { job.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.running = false
            self.searched = true
            switch outcome {
            case .success(let result):
                self.finds = result.finds
                self.ticked = Set(result.finds.map(\.id))
                self.unreadPages = result.unreadPages
                self.status = nil
            case .failure(let error):
                self.status = error.localizedDescription
            }
        }
    }

    func stop() {
        task?.cancel()
        running = false
    }
}

struct RedactionFindPanel: View {
    @ObservedObject var search: RedactionSearch
    /// Pages are named only where there are pages.
    var showsPages: Bool
    var onFind: () -> Void
    var onShow: (RedactionFinder.Find) -> Void = { _ in }

    var body: some View {
        SidebarSection(title: tr("Find", "Suchen")) {
            Text(tr("Words to black out, one per line", "Wörter zum Schwärzen, eines pro Zeile")).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $search.termsText)
                .font(.callout)
                .frame(height: 58)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            ForEach(RedactionFinder.Pattern.allCases) { pattern in
                Toggle(pattern.title, isOn: Binding(get: { search.patterns.contains(pattern) }, set: { on in
                    if on { search.patterns.insert(pattern) } else { search.patterns.remove(pattern) }
                }))
            }
            Toggle(tr("Faces", "Gesichter"), isOn: $search.faces)
            HStack {
                Button(search.running ? tr("Looking …", "Sucht …") : tr("Find", "Suchen"), action: onFind)
                    .disabled(search.running || search.request.isEmpty)
                if let status = search.status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
        if search.searched {
            SidebarSection(title: tr("Found (\(search.ticked.count) of \(search.finds.count) ticked)", "Gefunden (\(search.ticked.count) von \(search.finds.count) angehakt)")) {
                if search.finds.isEmpty { Text(tr("Nothing found.", "Nichts gefunden.")).font(.callout).foregroundStyle(.secondary) }
                if !search.unreadPages.isEmpty {
                    Text(VisionLimit.skippedPages(search.unreadPages) + " Please check them yourself.").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(search.finds) { find in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(get: { search.ticked.contains(find.id) }, set: { on in
                            if on { search.ticked.insert(find.id) } else { search.ticked.remove(find.id) }
                        }))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(find.title).font(.callout).lineLimit(2).textSelection(.enabled)
                            if showsPages || find.kind != .face {
                                Text(showsPages ? tr("Page \(find.page + 1) · \(find.kindTitle)", "Seite \(find.page + 1) · \(find.kindTitle)") : find.kindTitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onShow(find) }
                }
                if !search.finds.isEmpty {
                    HStack {
                        Button(tr("Tick all", "Alle anhaken")) { search.ticked = Set(search.finds.map(\.id)) }
                        Button(tr("Untick all", "Alle abwählen")) { search.ticked = [] }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// The finds over the picture: ticked ones as they will be, the others only outlined.
struct RedactionFindsOverlay: View {
    let finds: [RedactionFinder.Find]
    let ticked: Set<UUID>
    let imageSize: CGSize

    static let tickedFill = Color.black.opacity(0.35)
    static let tickedEdge = Color.red

    var body: some View {
        GeometryReader { proxy in
            let fit = FitGeometry(container: proxy.size, image: imageSize)
            ForEach(finds) { find in
                let isTicked = ticked.contains(find.id)
                ForEach(Array(PDFRedactor.cover(of: find).enumerated()), id: \.offset) { _, box in
                    let shown = fit.toDisplay(CGRect(x: box.minX * imageSize.width, y: box.minY * imageSize.height, width: box.width * imageSize.width, height: box.height * imageSize.height))
                    // Ticked: half see-through black with a red edge, so what goes black stays readable; only the result is really black.
                    // Not ticked: an orange dashed edge (dashed, so it doesn't depend on colour alone).
                    Rectangle()
                        .fill(isTicked ? Self.tickedFill : Color.clear)
                        .overlay(Rectangle().stroke(isTicked ? Self.tickedEdge : Color.orange,
                                                    style: StrokeStyle(lineWidth: 1.5, dash: isTicked ? [] : [4, 3])))
                        .frame(width: max(shown.width, 1), height: max(shown.height, 1))
                        .position(x: shown.midX, y: shown.midY)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
