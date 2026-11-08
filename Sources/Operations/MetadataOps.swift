import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct MetadataField: Identifiable, Hashable {
    let id: String
    let group: String
    let key: String
    var value: String
    let editable: Bool
    let sensitive: Bool
}

enum MetadataOps {
    static let sensitiveGroups: Set<String> = ["GPS", "Exif", "MakerApple", "TIFF", "IPTC", "XMP"]

    static func read(_ url: URL) async -> [MetadataField] {
        guard let format = FileFormat.detect(url) else { return [] }
        switch format.category {
        case .image: return readImage(url)
        case .audio, .video: return await readAV(url)
        case .document where format == .pdf: return readPDF(url)
        default: return fileFields(url)
        }
    }

    static func fileFields(_ url: URL) -> [MetadataField] {
        var fields: [MetadataField] = []
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        fields.append(MetadataField(id: "file.name", group: "File", key: tr("Name", "Name"), value: url.lastPathComponent, editable: false, sensitive: false))
        if let size = attrs?[.size] as? Int64 {
            fields.append(MetadataField(id: "file.size", group: "File", key: tr("Size", "Größe"), value: FileSizeFormatter.string(size), editable: false, sensitive: false))
        }
        if let created = attrs?[.creationDate] as? Date {
            fields.append(MetadataField(id: "file.created", group: "File", key: tr("Created", "Erstellt"), value: created.formatted(), editable: false, sensitive: false))
        }
        if let modified = attrs?[.modificationDate] as? Date {
            fields.append(MetadataField(id: "file.modified", group: "File", key: tr("Modified", "Geändert"), value: modified.formatted(), editable: false, sensitive: false))
        }
        return fields
    }

    static func readImage(_ url: URL) -> [MetadataField] {
        var fields = fileFields(url)
        let props = ImageIOBridge.properties(url)
        for (key, value) in props {
            let name = key as String
            if let dictionary = value as? [CFString: Any] {
                let group = name.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                for (subKey, subValue) in dictionary {
                    let sub = subKey as String
                    fields.append(MetadataField(id: "\(group).\(sub)", group: group, key: sub, value: describe(subValue), editable: isEditableImageKey(group: group, key: sub), sensitive: sensitiveGroups.contains(group)))
                }
            } else {
                fields.append(MetadataField(id: "Image.\(name)", group: "Image", key: name, value: describe(value), editable: false, sensitive: false))
            }
        }
        return fields.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
    }

    private static func isEditableImageKey(group: String, key: String) -> Bool {
        let editable: Set<String> = ["Artist", "Copyright", "ImageDescription", "Software", "Make", "Model", "UserComment", "DateTimeOriginal", "DateTimeDigitized", "DateTime", "LensModel", "Keywords", "Caption/Abstract", "Byline", "CopyrightNotice", "ObjectName", "City", "Country/PrimaryLocationName"]
        return editable.contains(key)
    }

    static func readAV(_ url: URL) async -> [MetadataField] {
        var fields = fileFields(url)
        let asset = AVURLAsset(url: url)
        let info = await MediaInfo.load(url)
        if info.duration > 0 { fields.append(MetadataField(id: "media.duration", group: "Media", key: tr("Duration", "Dauer"), value: TimeFormatter.clock(info.duration), editable: false, sensitive: false)) }
        if info.hasVideo { fields.append(MetadataField(id: "media.size", group: "Media", key: tr("Dimensions", "Abmessungen"), value: "\(Int(info.naturalSize.width)) × \(Int(info.naturalSize.height))", editable: false, sensitive: false)) }
        if info.frameRate > 0 { fields.append(MetadataField(id: "media.fps", group: "Media", key: tr("Frame rate", "Bildrate"), value: String(format: "%.2f fps", info.frameRate), editable: false, sensitive: false)) }
        if info.channelCount > 0 { fields.append(MetadataField(id: "media.channels", group: "Media", key: tr("Channels", "Kanäle"), value: "\(info.channelCount)", editable: false, sensitive: false)) }
        if info.sampleRate > 0 { fields.append(MetadataField(id: "media.rate", group: "Media", key: tr("Sample rate", "Abtastrate"), value: "\(Int(info.sampleRate)) Hz", editable: false, sensitive: false)) }
        let items = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        for item in common + items {
            guard let key = item.commonKey?.rawValue ?? (item.key.map { "\($0)" }) else { continue }
            var value = (try? await item.load(.stringValue)) ?? ""
            if value.isEmpty, let raw = try? await item.load(.value) { value = "\(raw)" }
            guard !value.isEmpty else { continue }
            let id = "av.\(item.keySpace?.rawValue ?? "common").\(key)"
            if fields.contains(where: { $0.id == id }) { continue }
            fields.append(MetadataField(id: id, group: "Tags", key: key.replacingOccurrences(of: "©", with: ""), value: value, editable: item.commonKey != nil, sensitive: key.lowercased().contains("location")))
        }
        if let ffmpegFields = await readWithFFprobe(url), !ffmpegFields.isEmpty {
            for field in ffmpegFields where !fields.contains(where: { $0.key.lowercased() == field.key.lowercased() && $0.group == field.group }) {
                fields.append(field)
            }
        }
        return fields
    }

    private static func readWithFFprobe(_ url: URL) async -> [MetadataField]? {
        guard let probe = FFmpeg.probePath else { return nil }
        guard let result = try? await Shell.run(probe, ["-v", "error", "-show_entries", "format_tags:stream_tags:chapters", "-of", "json", url.path], limit: .quick), result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var fields: [MetadataField] = []
        if let format = object["format"] as? [String: Any], let tags = format["tags"] as? [String: Any] {
            for (key, value) in tags {
                fields.append(MetadataField(id: "ff.format.\(key)", group: "Tags", key: key, value: describe(value), editable: true, sensitive: key.lowercased().contains("location")))
            }
        }
        if let streams = object["streams"] as? [[String: Any]] {
            for (index, stream) in streams.enumerated() {
                guard let tags = stream["tags"] as? [String: Any] else { continue }
                for (key, value) in tags {
                    fields.append(MetadataField(id: "ff.stream\(index).\(key)", group: tr("Track \(index + 1)", "Spur \(index + 1)"), key: key, value: describe(value), editable: false, sensitive: false))
                }
            }
        }
        if let chapters = object["chapters"] as? [[String: Any]] {
            for (index, chapter) in chapters.enumerated() {
                let title = ((chapter["tags"] as? [String: Any])?["title"] as? String) ?? tr("Chapter \(index + 1)", "Kapitel \(index + 1)")
                let start = chapter["start_time"] as? String ?? ""
                fields.append(MetadataField(id: "ff.chapter\(index)", group: "Chapters", key: title, value: start, editable: false, sensitive: false))
            }
        }
        return fields
    }

    static func readPDF(_ url: URL) -> [MetadataField] {
        var fields = fileFields(url)
        guard let document = PDFDocument(url: url) else { return fields }
        fields.append(MetadataField(id: "pdf.pages", group: "Document", key: tr("Pages", "Seiten"), value: "\(document.pageCount)", editable: false, sensitive: false))
        for (key, value) in document.documentAttributes ?? [:] {
            let name = (key.base as? PDFDocumentAttribute)?.rawValue ?? "\(key)"
            fields.append(MetadataField(id: "pdf.\(name)", group: "Document", key: name, value: describe(value), editable: true, sensitive: name == "Author" || name == "Creator" || name == "Producer"))
        }
        return fields
    }

    static func describe(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let date = value as? Date { return date.formatted() }
        if let array = value as? [Any] { return array.map(describe).joined(separator: ", ") }
        if let dictionary = value as? [AnyHashable: Any] { return dictionary.map { "\($0.key)=\(describe($0.value))" }.sorted().joined(separator: "; ") }
        return "\(value)"
    }

    static func write(_ url: URL, edits: [MetadataField], removeAll: Bool, removeSensitive: Bool, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        guard let format = FileFormat.detect(url) else { throw AppError.unreadable(url) }
        switch format.category {
        case .image:
            try writeImage(url, edits: edits, removeAll: removeAll, removeSensitive: removeSensitive, to: destination)
        case .audio, .video:
            try await writeAV(url, format: format, edits: edits, removeAll: removeAll, to: destination, progress: progress)
        case .document where format == .pdf:
            try writePDF(url, edits: edits, removeAll: removeAll, to: destination)
        default:
            throw AppError.invalidInput(tr("Metadata editing is not supported for \(format.displayName).", "Metadaten von \(format.displayName) lassen sich nicht bearbeiten."))
        }
        progress(1)
    }

    /// Writes the picture with new metadata: each picture is decoded and written again with exactly this metadata (EXIF, IPTC and XMP
    /// come from one tree, so a place or a name is gone from all of them), plus what an animation needs. Copying the picture as it is
    /// (`CGImageDestinationCopyImageSource`) kept a second IPTC block, comments and PNG texts of a made-up file.
    private static func writeImage(_ url: URL, edits: [MetadataField], removeAll: Bool, removeSensitive: Bool, to destination: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { throw AppError.unreadable(url) }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw AppError.unreadable(url) }
        let outputType: CFString = ImageIOBridge.nativeEncoders.contains(type as String) ? type : (UTType.png.identifier as CFString)
        func metadata(at index: Int) -> CGMutableImageMetadata {
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            if removeAll { return ImageMetadataCleaner.onlyOrientation(properties) }
            let original = CGImageSourceCopyMetadataAtIndex(source, index, nil)
            // A copy of the tree carries Apple's camera notes along unseen (some 50 values); built anew from its tags it does not.
            let meta = (removeSensitive ? original.map(ImageMetadataCleaner.visibleTags) : original.flatMap { CGImageMetadataCreateMutableCopy($0) })
                ?? CGImageMetadataCreateMutable()
            for edit in edits where edit.editable {
                guard let groupKey = groupDictionaryKey(edit.group) else { continue }
                ImageMetadataCleaner.set(meta, group: groupKey, key: edit.key as CFString, value: edit.value.isEmpty ? nil : edit.value)
            }
            // After the edits: the window hands over every field it shows, the city and the camera too, and removing must win.
            if removeSensitive { ImageMetadataCleaner.removeSensitive(from: meta) }
            return meta
        }
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, outputType, count, nil) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        // How often an animation plays is a property of the whole file, not of a frame (a GIF that looped for ever played once).
        let file = ImageMetadataCleaner.loops((CGImageSourceCopyProperties(source, nil) as? [CFString: Any]) ?? [:])
        if !file.isEmpty { CGImageDestinationSetProperties(dest, file as CFDictionary) }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw AppError.unreadable(url) }
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            var options = ImageMetadataCleaner.frameTiming(properties)
            options[kCGImageDestinationLossyCompressionQuality] = rewriteQuality
            // The pixels stay as stored, so the turn stays too. A HEIC takes it only from here, not from the metadata (iPhone photos
            // came out lying on their side).
            options[kCGImagePropertyOrientation] = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
            // The print size says nothing about who or where, and goes with "remove all" too.
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] { options[key] = properties[key] }
            // Of Apple's camera notes the two that set how bright the photo shows on an HDR screen (with its gain map).
            if removeAll || removeSensitive, let notes = ImageMetadataCleaner.hdrNotes(properties) { options[kCGImagePropertyMakerAppleDictionary] = notes }
            CGImageDestinationAddImageAndMetadata(dest, image, metadata(at: index), options as CFDictionary)
        }
        // The HDR gain map and the depth map of an iPhone photo: without them the photo loses its brightness on HDR screens and
        // its depth (portrait blur can no longer be changed). Their own metadata keeps only what they need.
        if count == 1, outputType == type {
            for (kind, info) in ImageMetadataCleaner.auxiliaryData(of: source) { CGImageDestinationAddAuxiliaryDataInfo(dest, kind, info as CFDictionary) }
        }
        guard CGImageDestinationFinalize(dest) else { throw AppError.encodeFailed(destination.lastPathComponent) }
    }

    /// JPEG and HEIC quality when the same picture is written again. Measured on an iPhone photo (HEIC, 12 MP) and a phone
    /// photo of a page (JPEG): 49 and 47 dB from the original, no difference to be seen at 200 %; the colour profile stays.
    static let rewriteQuality = 0.92

    private static func groupDictionaryKey(_ group: String) -> CFString? {
        switch group {
        case "Exif": return kCGImagePropertyExifDictionary
        case "TIFF": return kCGImagePropertyTIFFDictionary
        case "IPTC": return kCGImagePropertyIPTCDictionary
        case "GPS": return kCGImagePropertyGPSDictionary
        case "PNG": return kCGImagePropertyPNGDictionary
        default: return nil
        }
    }

    private static func writeAV(_ url: URL, format: FileFormat, edits: [MetadataField], removeAll: Bool, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let nativeTarget = VideoEngine.nativeTargets.contains(format) || format == .m4a
        if nativeTarget, await MediaInfo.isNativelyReadable(url) {
            var items: [AVMetadataItem] = []
            if !removeAll {
                for edit in edits where edit.editable && edit.id.hasPrefix("av.") {
                    let key = edit.id.components(separatedBy: ".").last ?? ""
                    let commonKey = AVMetadataKey(rawValue: key)
                    let item = AVMutableMetadataItem()
                    item.keySpace = .common
                    item.key = commonKey.rawValue as NSString
                    item.value = edit.value as NSString
                    items.append(item)
                }
            }
            try await AVExporter.export(asset: AVURLAsset(url: url), to: destination, format: format, preset: AVAssetExportPresetPassthrough, metadata: items, progress: progress)
            return
        }
        var args = ["-i", url.path, "-map", "0", "-c", "copy"]
        if removeAll {
            // Also a cover picture (its own metadata: place, name) and attached files of a Matroska film.
            args += ["-map", "-0:disp:attached_pic", "-map", "-0:t?"] + Privacy.removeAllArguments
        } else {
            args += ["-map_metadata", "0"]
            for edit in edits where edit.editable {
                args += ["-metadata", "\(edit.key)=\(edit.value)"]
            }
        }
        // ffmpeg writes every GIF as one that plays for ever; it keeps how often the original plays.
        if format == .gif { args += ["-loop", gifLoopArgument(url)] }
        args.append(destination.path)
        try await FFmpeg.run(args, purpose: tr("Writing metadata", "Metadaten schreiben"), privacy: false)
    }

    /// ffmpeg's `-loop` for the GIF at `url`: ImageIO counts how often it plays (0: for ever), ffmpeg how often it repeats (-1: none).
    static func gifLoopArgument(_ url: URL) -> String {
        let properties = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyProperties($0, nil) } as? [CFString: Any]
        let plays = (properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int ?? 0
        return plays <= 0 ? "0" : "\(plays - 1 == 0 ? -1 : plays - 1)"
    }

    private static func writePDF(_ url: URL, edits: [MetadataField], removeAll: Bool, to destination: URL) throws {
        let document = try PDFOps.document(url)
        if removeAll {
            document.documentAttributes = [:]
        } else {
            var attrs = document.documentAttributes ?? [:]
            for edit in edits where edit.editable && edit.id.hasPrefix("pdf.") {
                let name = String(edit.id.dropFirst(4))
                let key = AnyHashable(PDFDocumentAttribute(rawValue: name))
                if edit.value.isEmpty {
                    attrs.removeValue(forKey: key)
                } else {
                    attrs[key] = edit.value
                }
            }
            document.documentAttributes = attrs
        }
        guard document.write(to: destination) else { throw AppError.encodeFailed(destination.lastPathComponent) }
        // PDFKit keeps the XMP metadata (author, title, tool) of the document and its pages, whatever the attributes say.
        if removeAll { try PDFMetadataScrubber.blankXMP(at: destination) }
    }
}

/// Removes metadata from a picture's metadata tree (`CGImageMetadata`, which ImageIO writes as EXIF, IPTC and XMP alike).
enum ImageMetadataCleaner {
    /// No metadata but the turn of the picture: without it a photo taken upright would show lying.
    static func onlyOrientation(_ properties: [CFString: Any]) -> CGMutableImageMetadata {
        let meta = CGImageMetadataCreateMutable()
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            set(meta, group: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFOrientation, value: orientation)
        }
        return meta
    }

    /// Sets (or with nil removes) the tag that stands for one property of `CGImageSourceCopyPropertiesAtIndex`.
    static func set(_ meta: CGMutableImageMetadata, group: CFString, key: CFString, value: Any?) {
        if let value {
            CGImageMetadataSetValueMatchingImageProperty(meta, group, key, value as CFTypeRef)
        } else if let tag = CGImageMetadataCopyTagMatchingImageProperty(meta, group, key),
                  let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) {
            CGImageMetadataRemoveTagWithPath(meta, nil, "\(prefix):\(name)" as CFString)
        }
    }

    /// "Remove camera, GPS and processing data": every place (GPS, city, street, country, in EXIF, IPTC and XMP), the camera and
    /// lens with their serial numbers, the software and its editing history, and who made the picture.
    static func removeSensitive(from meta: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { path, tag in
            let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            if isSensitive(namespace: namespace, name: name) { paths.append(path as String) }
            return true
        }
        for path in paths { CGImageMetadataRemoveTagWithPath(meta, nil, path as CFString) }
    }

    static func isSensitive(namespace: String, name: String) -> Bool {
        let lower = name.lowercased()
        if isLocation(name) { return true }
        switch namespace {
        case "http://ns.adobe.com/exif/1.0/aux/", "http://ns.adobe.com/xap/1.0/mm/", "http://ns.adobe.com/camera-raw-settings/1.0/":
            return true
        case "http://ns.adobe.com/exif/1.0/":
            return ["usercomment", "makernote", "subjectlocation", "cameraownername", "bodyserialnumber", "lensmake", "lensmodel",
                    "lensserialnumber", "lensspecification", "imageuniqueid"].contains(lower)
        case let space where space.hasPrefix("http://cipa.jp/exif/"):
            return ["cameraownername", "bodyserialnumber", "lensmake", "lensmodel", "lensserialnumber", "lensspecification", "imageuniqueid"].contains(lower)
        case "http://ns.adobe.com/tiff/1.0/":
            return ["make", "model", "software", "artist", "hostcomputer"].contains(lower)
        case "http://ns.adobe.com/xap/1.0/":
            return lower == "creatortool"
        case "http://ns.adobe.com/photoshop/1.0/":
            return ["history", "authorsposition", "captionwriter"].contains(lower)
        case "http://purl.org/dc/elements/1.1/":
            return lower == "creator"
        case "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/":
            return lower == "creatorcontactinfo"
        case "http://ns.apple.com/ImageIO/1.0/":
            return false
        case let space where space.hasPrefix("http://ns.apple.com/"):
            return true
        default:
            return false
        }
    }

    /// Names that say where: GPS in all its forms, and the place fields of IPTC and XMP.
    static func isLocation(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["gps", "location", "latitude", "longitude", "altitude", "city", "country", "province", "sublocation", "worldregion"]
            .contains { lower.contains($0) } || lower == "state"
    }

    /// A new tree with the tags `meta` shows, without what a copy would carry along unseen.
    static func visibleTags(_ meta: CGImageMetadata) -> CGMutableImageMetadata {
        let kept = CGImageMetadataCreateMutable()
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { path, tag in
            if let namespace = CGImageMetadataTagCopyNamespace(tag), let prefix = CGImageMetadataTagCopyPrefix(tag) {
                CGImageMetadataRegisterNamespaceForPrefix(kept, namespace, prefix, nil)
            }
            CGImageMetadataSetTagWithPath(kept, nil, path, tag)
            return true
        }
        return kept
    }

    /// Apple's camera notes 33 and 48: the HDR headroom and gain of an iPhone photo, nothing about who, where or which camera.
    static func hdrNotes(_ properties: [CFString: Any]) -> [String: Any]? {
        guard let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return nil }
        let notes = apple.filter { ["33", "48"].contains($0.key) }
        return notes.isEmpty ? nil : notes
    }

    /// The extra pictures a photo carries that are kept: gain maps (HDR) and depth. Masks of the people in it (portrait matte, skin,
    /// hair, teeth, glasses) are left out, and so is the sky mask.
    static let keptAuxiliaryData: [CFString] = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap,
                                                kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity]

    /// `keptAuxiliaryData` of the first picture, each with metadata only from the namespaces that describe such data.
    static func auxiliaryData(of source: CGImageSource) -> [(CFString, [CFString: Any])] {
        keptAuxiliaryData.compactMap { kind in
            guard var info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) as? [CFString: Any] else { return nil }
            if let meta = info[kCGImageAuxiliaryDataInfoMetadata] {
                info[kCGImageAuxiliaryDataInfoMetadata] = auxiliaryMetadata(meta as! CGImageMetadata)
            }
            return (kind, info)
        }
    }

    /// Only tags of Apple's and Adobe's gain map and depth namespaces, never one that names a place.
    static func auxiliaryMetadata(_ meta: CGImageMetadata) -> CGMutableImageMetadata {
        let kept = CGImageMetadataCreateMutable()
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, nil) { path, tag in
            let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            if isAuxiliaryNamespace(namespace), !isLocation(name), let prefix = CGImageMetadataTagCopyPrefix(tag) {
                CGImageMetadataRegisterNamespaceForPrefix(kept, namespace as CFString, prefix, nil)
                CGImageMetadataSetTagWithPath(kept, nil, path, tag)
            }
            return true
        }
        return kept
    }

    static func isAuxiliaryNamespace(_ namespace: String) -> Bool {
        ["http://ns.apple.com/HDRGainMap/1.0/", "http://ns.adobe.com/hdr-gain-map/1.0/", "http://ns.apple.com/depthData/1.0/",
         "http://ns.apple.com/ImageIO/1.0/"].contains(namespace)
    }

    /// The time each frame of an animation shows, without the texts a GIF or PNG may carry. How often it loops goes with the file
    /// (`loops`): repeated on a frame, ImageIO let it win over the file's (a GIF meant to play three times played for ever).
    static func frameTiming(_ properties: [CFString: Any]) -> [CFString: Any] {
        var timing: [CFString: Any] = [:]
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            timing[kCGImagePropertyGIFDictionary] = gif.filter { [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime].contains($0.key) }
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            timing[kCGImagePropertyPNGDictionary] = png.filter { [kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGUnclampedDelayTime].contains($0.key) }
        }
        return timing
    }

    /// How often an animation plays (0: for ever), from the file's own properties.
    static func loops(_ properties: [CFString: Any]) -> [CFString: Any] {
        var loops: [CFString: Any] = [:]
        if let count = (properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] {
            loops[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFLoopCount: count]
        }
        if let count = (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyAPNGLoopCount] {
            loops[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGLoopCount: count]
        }
        return loops
    }
}

/// XMP metadata in a PDF: streams marked /Type /Metadata (on the document and on pages). Their content is overwritten with spaces of the
/// same length, so every place in the file stays where it was and the PDF stays valid; the stream is then empty, readers find no metadata.
enum PDFMetadataScrubber {
    static func blankXMP(at url: URL) throws {
        var data = try Data(contentsOf: url)
        guard blankXMP(in: &data) > 0 else { return }
        guard let check = PDFDocument(data: data), check.pageCount == PDFDocument(url: url)?.pageCount else {
            throw AppError.encodeFailed(url.lastPathComponent)
        }
        try data.write(to: url, options: .atomic)
    }

    /// Returns how many metadata streams were blanked.
    @discardableResult
    static func blankXMP(in data: inout Data) -> Int {
        let space = UInt8(ascii: " ")
        // Latin-1: one character for each byte, so places in the text are places in the file.
        func text(_ range: Range<Int>) -> String { String(data: data[range], encoding: .isoLatin1) ?? "" }
        func blank(_ range: Range<Int>) { data.replaceSubrange(range, with: Data(repeating: space, count: range.count)) }
        var blanked = 0
        var searchFrom = data.startIndex
        while let streamWord = data.range(of: Data("stream".utf8), in: searchFrom..<data.endIndex) {
            searchFrom = streamWord.upperBound
            // "endstream" contains "stream" too.
            if streamWord.lowerBound - data.startIndex >= 3, data[(streamWord.lowerBound - 3)..<streamWord.lowerBound] == Data("end".utf8) { continue }
            // The stream's dictionary: what stands between its "obj" and the word "stream".
            guard let object = data.range(of: Data(" obj".utf8), options: .backwards, in: data.startIndex..<streamWord.lowerBound) else { continue }
            let dictionary = object.upperBound..<streamWord.lowerBound
            guard text(dictionary).range(of: #"/Type\s*/Metadata\b"#, options: .regularExpression) != nil else { continue }
            var start = streamWord.upperBound
            if start < data.endIndex, data[start] == 13 { start += 1 }
            if start < data.endIndex, data[start] == 10 { start += 1 }
            guard let end = data.range(of: Data("endstream".utf8), in: start..<data.endIndex) else { break }
            blank(start..<end.lowerBound)
            // A compressed stream of spaces would not decode: its filter goes too, replaced by spaces of the same length.
            for pattern in [#"/Filter\s*/[A-Za-z0-9]+"#, #"/Filter\s*\[[^\]]*\]"#, #"/DecodeParms\s*<<[^<>]*>>"#] {
                while case let found = text(dictionary), let match = found.range(of: pattern, options: .regularExpression) {
                    let lower = dictionary.lowerBound + found.unicodeScalars.distance(from: found.startIndex, to: match.lowerBound)
                    let upper = dictionary.lowerBound + found.unicodeScalars.distance(from: found.startIndex, to: match.upperBound)
                    blank(lower..<upper)
                }
            }
            blanked += 1
            searchFrom = end.upperBound
        }
        return blanked
    }
}
