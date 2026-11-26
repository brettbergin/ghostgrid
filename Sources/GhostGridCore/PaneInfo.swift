import Foundation

/// The git branch for a folder, read from the repository's HEAD file
/// without running git (a header updates on every prompt). Walks up to
/// the nearest `.git`, which may be a folder or, in a worktree or
/// submodule, a file pointing at the real git dir.
public enum GitBranch {
    public static func read(
        from directory: String,
        fileExists: (String) -> Bool,
        isDirectory: (String) -> Bool,
        readFile: (String) -> String?,
    ) -> String? {
        var current = (directory as NSString).standardizingPath
        while true {
            let dotGit = (current as NSString).appendingPathComponent(".git")
            if fileExists(dotGit) {
                guard let gitDir = resolveGitDir(dotGit, isDirectory: isDirectory, readFile: readFile),
                      let head = readFile((gitDir as NSString).appendingPathComponent("HEAD"))
                else { return nil }
                return branch(fromHead: head)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    /// "ref: refs/heads/main" -> "main"; a detached HEAD -> its short hash.
    public static func branch(fromHead head: String) -> String? {
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref:") {
            let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
        }
        let isHash = text.count >= 7 && text.allSatisfy(\.isHexDigit)
        return isHash ? String(text.prefix(7)) : nil
    }

    private static func resolveGitDir(
        _ dotGit: String,
        isDirectory: (String) -> Bool,
        readFile: (String) -> String?,
    ) -> String? {
        if isDirectory(dotGit) { return dotGit }
        guard let contents = readFile(dotGit),
              let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("/") { return path }
        let base = (dotGit as NSString).deletingLastPathComponent
        return ((base as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }
}

/// A folder as a header shows it: the home folder as "~", and long paths
/// trimmed from the left so the end (the part you care about) stays.
public enum PathDisplay {
    public static func short(_ path: String, home: String, maxLength: Int = 48) -> String {
        var text = path
        if path == home {
            text = "~"
        } else if path.hasPrefix(home + "/") {
            text = "~" + path.dropFirst(home.count)
        }
        guard text.count > maxLength, maxLength > 1 else { return text }
        return "…" + text.suffix(maxLength - 1)
    }
}

/// Something that happened in a pane while you were not looking at it.
public enum PaneActivity: Equatable, Sendable {
    case bell
    case finished(exitCode: Int?, seconds: Double)

    public var failed: Bool {
        if case let .finished(code, _) = self { return (code ?? 0) != 0 }
        return false
    }

    /// Commands shorter than this do not badge: quick commands finish
    /// before you would have looked away.
    public static let minimumSeconds: Double = 5

    /// The badge for a finished command, or nil when it should not show:
    /// the pane is focused, or the command was quick.
    public static func forFinishedCommand(exitCode: Int?, durationNanos: UInt64, paneFocused: Bool) -> PaneActivity? {
        let seconds = Double(durationNanos) / 1_000_000_000
        guard !paneFocused, seconds >= minimumSeconds else { return nil }
        return .finished(exitCode: exitCode, seconds: seconds)
    }

    /// Short text for the badge: "bell", "12s", "1m 05s", "exit 2".
    public var label: String {
        switch self {
        case .bell:
            return "bell"
        case let .finished(code, seconds):
            if let code, code != 0 { return "exit \(code)" }
            let total = Int(seconds.rounded())
            return total < 60 ? "\(total)s" : String(format: "%dm %02ds", total / 60, total % 60)
        }
    }
}
