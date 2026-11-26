/// A command-line app offered after picking zsh from the shell menu.
public struct LaunchApp: Equatable, Sendable {
    public let name: String
    /// The key that picks it in the menu ("1", "2", ...).
    public let hotkey: String
    /// What gets typed at the zsh prompt to start it. Typed rather than run
    /// as the pane's command, so quitting the app leaves you in zsh, and the
    /// command lands in your history like anything else you run.
    public let command: String
    /// One line shown beside the name.
    public let summary: String
    /// Where the app was found, or nil when it is not installed.
    public let executable: String?

    public var isInstalled: Bool { executable != nil }
}

/// The apps offered in a new zsh pane, in menu order.
public enum LaunchCatalog {
    static let known: [(name: String, binary: String, command: String, summary: String)] = [
        ("opencode", "opencode", "opencode", "coding agent on the local model"),
        ("claude", "claude", "claude", "Claude Code"),
        ("btop", "btop", "btop", "system monitor"),
        ("lazygit", "lazygit", "lazygit", "git TUI"),
        // `y` is the dotfiles wrapper: quitting yazi cds the pane there.
        ("yazi", "yazi", "y", "file manager; q leaves you in that folder"),
    ]

    /// Where to look: the app may run with a minimal PATH, so explicit
    /// Homebrew and per-user install locations (Claude Code's installer
    /// uses ~/.local/bin).
    static let searchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.opencode/bin", "~/.bun/bin",
    ]

    public static func resolve(home: String, isExecutable: (String) -> Bool) -> [LaunchApp] {
        let directories = searchDirectories.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
        return known.enumerated().map { index, app in
            let found = directories.map { "\($0)/\(app.binary)" }.first(where: isExecutable)
            return LaunchApp(
                name: app.name, hotkey: String(index + 1), command: app.command,
                summary: app.summary, executable: found,
            )
        }
    }

    /// The installed app a key press selects, if any.
    public static func choice(forKey key: String, in apps: [LaunchApp]) -> LaunchApp? {
        apps.first { $0.hotkey == key && $0.isInstalled }
    }
}
