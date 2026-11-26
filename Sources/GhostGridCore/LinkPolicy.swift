import Foundation

/// Decides what a Cmd-clicked link in a terminal opens.
///
/// The text a terminal hands over is untrusted: a program can print or
/// OSC 8-link anything. Only web, mail and file links open; other schemes
/// (custom app handlers, javascript:, ...) are refused. A bare path opens
/// as a file when it exists, relative paths resolving against the pane's
/// working directory.
public enum LinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "file"]

    public static func url(
        for raw: String,
        workingDirectory: String?,
        home: String,
        fileExists: (String) -> Bool,
    ) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            return allowedSchemes.contains(scheme) ? url : nil
        }

        var path = text
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            guard let workingDirectory else { return nil }
            path = (workingDirectory as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        return fileExists(path) ? URL(fileURLWithPath: path) : nil
    }
}

/// Reads option values from a Ghostty config (the flattened text), for the
/// options ghostgrid implements itself. The last occurrence wins, as in
/// Ghostty; quotes are stripped.
public struct GhosttyConfigValues: Sendable {
    private let values: [String: String]

    public init(_ text: String) {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        self.values = values
    }

    public func string(_ key: String) -> String? { values[key] }

    public func bool(_ key: String, default fallback: Bool) -> Bool {
        switch values[key]?.lowercased() {
        case "true": true
        case "false": false
        default: fallback
        }
    }

    public func double(_ key: String, default fallback: Double) -> Double {
        values[key].flatMap(Double.init) ?? fallback
    }
}
