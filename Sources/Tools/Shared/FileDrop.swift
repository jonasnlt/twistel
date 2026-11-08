import SwiftUI
import UniformTypeIdentifiers

/// Files dragged onto a place in a window (from the Finder, Downloads, the desktop), besides its "Choose …" button.
/// Only files of the kinds given are taken; while something is held over the place, a frame shows it.
struct FileDropArea: ViewModifier {
    let types: [UTType]
    /// Endings taken besides: macOS knows no kind for some (".srt" is only a makeshift one).
    var extensions: [String] = []
    let multiple: Bool
    let action: ([URL]) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8).stroke(Theme.accentForeground, lineWidth: 3).allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let fitting = Self.fitting(urls, types: types, extensions: extensions)
                guard !fitting.isEmpty else { return false }
                action(multiple ? fitting : [fitting[0]])
                return true
            } isTargeted: { targeted = $0 }
    }

    /// The files among `urls` of one of the kinds, in the order given.
    static func fitting(_ urls: [URL], types: [UTType], extensions: [String] = []) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            if extensions.contains(url.pathExtension.lowercased()) { return true }
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return types.contains { type.conforms(to: $0) }
        }
    }
}

extension View {
    /// See `FileDropArea`.
    func fileDrop(_ types: [UTType], extensions: [String] = [], multiple: Bool = false, action: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropArea(types: types, extensions: extensions, multiple: multiple, action: action))
    }
}
