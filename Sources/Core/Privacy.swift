import AVFoundation
import Foundation
import ImageIO

/// Settings › Privacy, for every conversion and tool that writes pictures, videos or sound: the place where a photo or video was taken
/// is left out (on unless switched off), all metadata only when asked. The tool "Edit metadata" does what is chosen in its window.
enum Privacy {
    struct Rules: Equatable, Sendable {
        var removeLocation = true
        var removeAllMetadata = false
    }

    /// Kept here, not only in `AppSettings`, because the work runs in the background.
    static var current: Rules {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = Rules()

    /// Picture metadata as written by `ImageIOBridge.write`: without any place (GPS, and city, street and country in IPTC), or
    /// (all metadata) with only the turn of the picture.
    static func clean(_ metadata: [CFString: Any]?, rules: Rules = current) -> [CFString: Any]? {
        guard var metadata else { return nil }
        if rules.removeAllMetadata {
            return metadata[kCGImagePropertyOrientation].map { [kCGImagePropertyOrientation: $0] }
        }
        if rules.removeLocation {
            metadata[kCGImagePropertyGPSDictionary] = nil
            if var iptc = metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                for key in iptcPlaces { iptc[key] = nil }
                metadata[kCGImagePropertyIPTCDictionary] = iptc
            }
        }
        return metadata
    }

    /// IPTC's fields for a place: where the picture was taken, and the address of whoever took it.
    static let iptcPlaces: [CFString] = [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                                          kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
                                          kCGImagePropertyIPTCCreatorContactInfo, kCGImagePropertyIPTCContact]

    static func isLocation(_ item: AVMetadataItem) -> Bool {
        let names = [item.identifier?.rawValue, item.commonKey?.rawValue, item.key.map { "\($0)" }].compactMap { $0?.lowercased() }
        // ©xyz is QuickTime's place tag, written "%A9xyz" in identifiers.
        return names.contains { isLocationKey($0) || $0.hasSuffix("xyz") }
    }

    /// A metadata name that stands for a place, in any of the ways files write it ("location", "LOCATION", "location-eng",
    /// "com.apple.quicktime.location.ISO6709", "GPSCoordinates").
    static func isLocationKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["location", "iso6709", "gps", "latitude", "longitude", "geotag"].contains { lower.contains($0) }
    }

    /// For `AVAssetExportSession.metadata`: the session copies all of the original's metadata when it gets an empty list. One empty
    /// title stands for "none": then it writes nothing at all (measured with ffprobe: no title, artist, place or encoder).
    static func forExportSession(_ items: [AVMetadataItem]) -> [AVMetadataItem] {
        guard items.isEmpty else { return items }
        let nothing = AVMutableMetadataItem()
        nothing.identifier = .commonIdentifierTitle
        nothing.value = "" as NSString
        return [nothing]
    }

    /// Video and sound metadata to write: without places, or none.
    static func filter(_ items: [AVMetadataItem]?, rules: Rules = current) -> [AVMetadataItem]? {
        guard let items else { return nil }
        if rules.removeAllMetadata { return [] }
        return rules.removeLocation ? items.filter { !isLocation($0) } : items
    }

    /// ffmpeg: "-map_metadata" and the tags it must not carry over. `tagKeys`: the tag names the inputs have (`FFmpeg.tagKeys`),
    /// so that a place is left out under whatever name a file keeps it, in the file and in each of its streams.
    static func ffmpegArguments(keepsMetadata: Bool, rules: Rules = current, tagKeys: Set<String> = []) -> [String] {
        guard keepsMetadata, !rules.removeAllMetadata else { return removeAllArguments }
        return ["-map_metadata", "0"] + locationArguments(rules: rules, tagKeys: tagKeys)
    }

    /// No metadata at all: none from the inputs (file, streams, chapters), and no "encoder" tag of ffmpeg's own.
    static let removeAllArguments = ["-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact"]

    static func locationArguments(rules: Rules = current, tagKeys: Set<String>) -> [String] {
        guard rules.removeLocation, !rules.removeAllMetadata else { return [] }
        let keys = Set(["location", "location-eng", "com.apple.quicktime.location.ISO6709"]).union(tagKeys.filter(isLocationKey))
        return keys.sorted().flatMap { ["-metadata", "\($0)=", "-metadata:s", "\($0)="] }
    }
}
