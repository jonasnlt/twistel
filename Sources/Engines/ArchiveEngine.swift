import Foundation

struct ArchiveEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .archive && to.category == .archive && to != .rar
    }

    func convert(_ request: ConversionRequest) async throws {
        if request.target == .rar {
            throw AppError.invalidInput(tr("RAR archives can be read but macOS has no free RAR encoder. Choose ZIP, TAR, or GZIP instead.",
                                           "RAR-Archive können gelesen, aber nicht erstellt werden: Dafür hat macOS kein freies Programm. Wähle stattdessen ZIP, TAR oder GZIP."))
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("twistel-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let removed = try await extract(request.source, format: request.sourceFormat, into: staging) + ExtractedLinks.removeLeavingLinks(in: staging)
        if removed > 0 {
            JobNotes.add(tr("\(removed) link\(removed == 1 ? "" : "s") pointing outside the archive \(removed == 1 ? "was" : "were") left out.",
                            "\(removed) \(removed == 1 ? "Verknüpfung" : "Verknüpfungen"), die aus dem Archiv hinaus \(removed == 1 ? "zeigte, wurde" : "zeigten, wurden") weggelassen."))
        }
        request.progress(0.5)
        try await pack(staging, as: request.target, to: request.destination)
        request.progress(1)
    }

    /// Returns how many links leading out were already left out on the way (ZIP); `ExtractedLinks` looks after the rest.
    @discardableResult
    func extract(_ archive: URL, format: FileFormat, into directory: URL) async throws -> Int {
        switch format {
        case .zip:
            return try await ZipTool.unzip(archive, into: directory)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
            guard result.succeeded else { throw unreadable(archive) }
        case .gz:
            let name = archive.lastPathComponent.lowercased()
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
                let result = try await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path])
                guard result.succeeded else { throw unreadable(archive) }
            } else {
                let output = directory.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
                let result = try await Shell.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$0\" > \"$1\"", archive.path, output.path])
                guard result.succeeded else { throw unreadable(archive) }
            }
        case .rar:
            let candidates = ["unar", "unrar", "bsdtar"]
            for tool in candidates {
                guard let path = Shell.which(tool) else { continue }
                let args: [String]
                switch tool {
                case "unar": args = ["-q", "-o", directory.path, archive.path]
                case "unrar": args = ["x", "-y", "-idq", archive.path, directory.path + "/"]
                default: args = ["-xf", archive.path, "-C", directory.path]
                }
                let result = try await Shell.run(path, args)
                if result.succeeded { return 0 }
            }
            let bsdtar = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
            guard bsdtar.succeeded else {
                throw AppError.toolFailed("rar", tr("Install unar to extract RAR archives: brew install unar", "Installiere unar, um RAR-Archive zu entpacken: brew install unar"))
            }
        default:
            throw AppError.unsupportedConversion(format, .zip)
        }
        return 0
    }

    private func unreadable(_ archive: URL) -> AppError {
        .invalidInput(tr("\(archive.lastPathComponent) could not be read. It is damaged or incomplete.", "\(archive.lastPathComponent) konnte nicht gelesen werden. Die Datei ist beschädigt oder unvollständig."))
    }

    func pack(_ directory: URL, as format: FileFormat, to destination: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.zip(directory: directory, to: destination)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-cf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw AppError.toolFailed("tar", result.stderr) }
        case .gz:
            let result = try await Shell.run("/usr/bin/tar", ["-czf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw AppError.toolFailed("tar", result.stderr) }
        default:
            throw AppError.unsupportedConversion(.zip, format)
        }
    }
}

/// Links (symlinks) that came out of an archive. One that leads out of the unpacked folder (to "/etc", "~/.ssh" or "../../x") would make
/// whoever follows it later read or write somewhere else on this Mac; such links are removed, links within the archive stay.
enum ExtractedLinks {
    /// Returns how many were removed.
    @discardableResult
    static func removeLeavingLinks(in root: URL) -> Int {
        let fm = FileManager.default
        let rootPath = realPath(root.path)
        var links: [URL] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
            for case let item as URL in walker where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                links.append(item)
            }
        }
        var removed = 0
        for link in links where !staysInside(link, rootPath: rootPath) {
            if (try? fm.removeItem(at: link)) != nil { removed += 1 }
        }
        return removed
    }

    /// Inside by its written target (no absolute path, no way up past the top) and by where it really leads now.
    static func staysInside(_ link: URL, rootPath: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), !target.isEmpty, !target.hasPrefix("/") else { return false }
        func inside(_ path: String) -> Bool { path == rootPath || path.hasPrefix(rootPath + "/") }
        let folder = realPath(link.deletingLastPathComponent().path)
        let written = lexical(folder + "/" + target)
        guard inside(written) else { return false }
        // Through other links, where the target exists.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(link.path, &buffer) != nil {
            return inside(String(cString: buffer))
        }
        return true
    }

    /// The path with every link resolved, as the system resolves it ("/var" is "/private/var"; Foundation's `resolvingSymlinksInPath`
    /// and `standardizedFileURL` drop "/private" instead, so the paths would never match).
    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buffer) != nil ? String(cString: buffer) : lexical(path)
    }

    /// "." and ".." worked out in the text alone, without looking at the disk.
    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}
