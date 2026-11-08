import CoreGraphics
import Foundation

/// Numbers that come from a file (a page size, a duration, a time code) can say anything: infinity, "not a number", 10^76.
/// `Int(_:)` ends the app on such a value; these turn them into a whole number within a range instead.
enum SafeNumber {
    /// The whole number nearest to `value`, kept within `range`; "not a number" counts as the range's lower end.
    static func int(_ value: Double, in range: ClosedRange<Int> = -1_000_000_000...1_000_000_000) -> Int {
        guard !value.isNaN else { return range.lowerBound }
        if value <= Double(range.lowerBound) { return range.lowerBound }
        if value >= Double(range.upperBound) { return range.upperBound }
        return Int(value.rounded(.towardZero))
    }

    static func int(_ value: CGFloat, in range: ClosedRange<Int> = -1_000_000_000...1_000_000_000) -> Int {
        int(Double(value), in: range)
    }

    /// The longest time the app works with: 100 days. A file that says longer is damaged.
    static let longestSeconds = 8_640_000.0

    /// Seconds as written in a file, or nil when they are no time: negative, infinite, not a number or over `longestSeconds`.
    static func seconds(_ value: Double) -> Double? {
        value.isFinite && value >= 0 && value <= longestSeconds ? value : nil
    }

    /// Seconds for showing or writing a time code: always within 0 … `longestSeconds`.
    static func clampedSeconds(_ value: Double) -> Double {
        value.isFinite ? min(max(0, value), longestSeconds) : 0
    }
}
