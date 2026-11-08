import AppKit

/// A text clipping (.textClipping): text dragged from an app onto the Finder. It is a property list with the text in
/// several forms under "UTI-Data"; the richest one is taken (RTF, then HTML, then plain text). Only read, never written.
enum TextClipping {
    static func read(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let forms = list["UTI-Data"] as? [String: Any] else {
            throw AppError.invalidInput(tr("\(url.lastPathComponent) is no text clipping this Mac can read.", "\(url.lastPathComponent) ist kein Textausschnitt, den dieser Mac lesen kann."))
        }
        if let rtf = forms["public.rtf"] as? Data,
           let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           text.length > 0 {
            return text
        }
        for (key, encoding) in [("public.utf8-plain-text", String.Encoding.utf8), ("public.utf16-plain-text", .utf16), ("public.plain-text", .utf8)] {
            let string = forms[key] as? String ?? (forms[key] as? Data).flatMap { String(data: $0, encoding: encoding) }
            if let string, !string.isEmpty { return NSAttributedString(string: string, attributes: [.font: TextDocuments.bodyFont]) }
        }
        throw AppError.invalidInput(tr("\(url.lastPathComponent) holds no text.", "\(url.lastPathComponent) enthält keinen Text."))
    }
}
