import Foundation

/// Values for building a tool's jobs without its window, by name ("preset", "resize", …): from the command line of the test access,
/// or the values a tool's window remembered (`ToolMemory`). A name nobody asked for is an error (`checkAllUsed`), so a typo can't pass as
/// "the default".
struct ToolOptions {
    struct Problem: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private var values: [String: String]
    private var used: Set<String> = []

    init(_ values: [String: String]) { self.values = values }

    mutating func string(_ key: String, default fallback: String) -> String {
        used.insert(key)
        return values[key] ?? fallback
    }

    mutating func value<T: LosslessStringConvertible>(_ key: String, _ type: T.Type, default fallback: T) throws -> T {
        used.insert(key)
        guard let text = values[key] else { return fallback }
        guard let value = T(text) else { throw ToolOptions.Problem("Option \(key)=\(text) is not a valid \(T.self).") }
        return value
    }

    mutating func value<T: RawRepresentable>(_ key: String, _ type: T.Type, default fallback: T?) throws -> T where T.RawValue == String {
        used.insert(key)
        guard let text = values[key] else {
            guard let fallback else { throw ToolOptions.Problem("Option \(key) is needed.") }
            return fallback
        }
        guard let value = T(rawValue: text) else { throw ToolOptions.Problem("Option \(key)=\(text) is not a valid \(T.self).") }
        return value
    }

    mutating func optionalList(_ key: String) throws -> [Double]? {
        used.insert(key)
        guard let text = values[key] else { return nil }
        let numbers = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !numbers.contains(nil) else { throw ToolOptions.Problem("Option \(key)=\(text) needs numbers separated by commas.") }
        return numbers.compactMap { $0 }
    }

    mutating func list(_ key: String, default fallback: [Double]) throws -> [Double] {
        try optionalList(key) ?? fallback
    }

    /// "x,y,width,height" in pixels.
    mutating func rect(_ key: String, default fallback: CGRect) throws -> CGRect {
        guard let numbers = try optionalList(key) else { return fallback }
        guard numbers.count == 4 else { throw ToolOptions.Problem("Option \(key) needs x,y,width,height.") }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// A typo in an option name must not pass silently as "the default".
    func checkAllUsed() throws {
        let unknown = Set(values.keys).subtracting(used)
        guard unknown.isEmpty else { throw ToolOptions.Problem("Unknown option(s) for this tool: \(unknown.sorted().joined(separator: ", ")).") }
    }
}
