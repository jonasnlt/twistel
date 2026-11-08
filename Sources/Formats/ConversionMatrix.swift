import Foundation

enum ConversionMatrix {
    static func targets(for source: FileFormat) -> [FileFormat] {
        let list: [FileFormat]
        switch source {
        case .jpg, .png:
            list = FileFormat.imageTargets + [.docx]
        case .webp, .heic, .tiff, .svg, .avif, .bmp:
            list = FileFormat.imageTargets
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma:
            list = FileFormat.audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            list = FileFormat.video + [.gif, .mp3]
        case .gif:
            list = FileFormat.video
        case .pdf:
            list = [.docx, .pptx, .txt, .md, .epub, .jpg, .png, .xlsx]
        case .txt:
            list = [.pdf, .docx, .odt, .rtf, .html, .md, .epub, .jpg, .png, .srt, .vtt]
        // Office documents: see OfficeEngine for which way each one goes (LibreOffice, Apple or own code).
        case .docx, .odt, .rtf, .html, .md:
            list = [.pdf, .docx, .odt, .rtf, .html, .md, .txt, .epub, .jpg, .png]
        case .doc:
            list = [.pdf, .docx, .odt, .rtf, .txt, .epub, .jpg, .png]
        // Only read: RTFD (TextEdit with pictures) and text clippings (text dragged to the Finder).
        case .rtfd, .textClipping:
            list = [.pdf, .docx, .txt, .md, .html, .epub, .jpg, .png]
        case .epub:
            list = [.pdf, .docx, .txt, .md, .html]
        case .xlsx, .xls, .ods:
            list = [.pdf, .xlsx, .ods, .csv, .tsv]
        case .csv, .tsv:
            list = [.xlsx, .ods, .csv, .tsv, .pdf]
        case .pptx, .ppt, .odp:
            list = [.pdf, .pptx, .odp, .jpg, .png]
        case .srt, .vtt:
            list = FileFormat.subtitles + [.txt]
        case .zip, .tar, .gz, .rar:
            list = FileFormat.archiveTargets
        }
        return list.filter { $0 != source }
    }

    static func targets(for sources: [FileFormat]) -> [FileFormat] {
        guard let first = sources.first else { return [] }
        var common = targets(for: first)
        for source in sources.dropFirst() {
            let next = Set(targets(for: source))
            common = common.filter { next.contains($0) }
        }
        return common
    }

    static var totalConversions: Int {
        FileFormat.allCases.reduce(0) { $0 + targets(for: $1).count }
    }

    /// A file name can have 255 bytes. A long one must leave room for " compressed 2.jpeg" and for what Apple's tools add while writing.
    static func shortened(_ name: String, limit: Int = 200) -> String {
        guard name.utf8.count > limit else { return name }
        var short = ""
        for character in name {
            guard short.utf8.count + character.utf8.count <= limit else { break }
            short.append(character)
        }
        return short
    }

    static func outputURL(for source: URL, target: FileFormat, in directory: URL, existing: Set<String> = []) -> URL {
        let base = shortened(strippedBaseName(source.lastPathComponent))
        var candidate = "\(base).\(target.fileExtension)"
        var counter = 2
        while existing.contains(candidate) || isTaken(directory.appendingPathComponent(candidate)) {
            candidate = "\(base) \(counter).\(target.fileExtension)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    /// Whether a name is in use: also by a link that leads nowhere, which `FileManager.fileExists` takes for a free name
    /// (and a result moved there would then replace the link).
    static func isTaken(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    static func uniqueURL(directory: URL, baseName: String, suffix: String, ext: String) -> URL {
        let baseName = shortened(baseName)
        var candidate = suffix.isEmpty ? "\(baseName).\(ext)" : "\(baseName) \(suffix).\(ext)"
        var counter = 2
        while isTaken(directory.appendingPathComponent(candidate)) {
            candidate = suffix.isEmpty ? "\(baseName) \(counter).\(ext)" : "\(baseName) \(suffix) \(counter).\(ext)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func uniqueDirectory(directory: URL, name: String) -> URL {
        let name = shortened(name)
        var candidate = name
        var counter = 2
        while isTaken(directory.appendingPathComponent(candidate)) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func strippedBaseName(_ fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(fileName.dropLast(7)) }
        if lower.hasSuffix(".tgz") { return String(fileName.dropLast(4)) }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }
}
