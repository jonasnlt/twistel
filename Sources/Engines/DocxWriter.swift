import Foundation
import ImageIO

enum ZipTool {
    static func zip(directory: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        // -y: a link stays a link. Followed, a link in an archive to some file of this Mac would put that file into the result.
        let result = try await Shell.run("/usr/bin/zip", ["-r", "-y", "-X", "-q", destination.path, "."], currentDirectory: directory)
        guard result.succeeded else { throw AppError.toolFailed("zip", result.stderr) }
    }

    static func zipOrdered(directory: URL, entries: [String], to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        // The names through standard input: a PDF of 3,000 pages is more than a command line can hold (the app went down).
        let names = entries.joined(separator: "\n") + "\n"
        let result = try await Shell.run("/usr/bin/zip", ["-X", "-q", destination.path, "-@"], currentDirectory: directory, input: Data(names.utf8))
        guard result.succeeded else { throw AppError.toolFailed("zip", result.stderr) }
    }

    /// Returns how many links leading out of `directory` were left out.
    @discardableResult
    static func unzip(_ archive: URL, into directory: URL) async throws -> Int {
        let result = try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        // Its own words name paths and "pkzip signatures".
        guard result.succeeded else { throw AppError.invalidInput(tr("\(archive.lastPathComponent) could not be read. It is damaged or incomplete.", "\(archive.lastPathComponent) konnte nicht gelesen werden. Die Datei ist beschädigt oder unvollständig.")) }
        // A Word, Excel or e-book file has no links; one that leads out must not make a reader take a file of this Mac for its part.
        return ExtractedLinks.removeLeavingLinks(in: directory)
    }
}

enum DocxWriter {
    /// A picture file (JPEG or PNG) for a Word document, as large as it was at 96 dpi; saving shrinks it to the text width.
    static func picture(_ image: URL) throws -> WordDocument.Picture {
        let size = ImageIOBridge.pixelSize(image)
        return .init(data: try Data(contentsOf: image), isJPEG: ["jpg", "jpeg"].contains(image.pathExtension.lowercased()),
                     size: CGSize(width: max(size.width, 1) * 0.75, height: max(size.height, 1) * 0.75))
    }
}
