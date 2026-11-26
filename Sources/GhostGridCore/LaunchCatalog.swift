import Foundation

/// One app in the zsh launcher, as the user configures it in Settings.
public struct LauncherEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// What gets typed at the zsh prompt: a program, an alias, a function,
    /// or a whole command line (`lazygit -p ~/code/api`).
    public var command: String
    /// One line shown beside the name.
    public var summary: String
    /// The program to look for on disk, when it differs from the command's
    /// first word (the default `y` is a function that runs yazi).
    public var program: String?

    public init(id: UUID = UUID(), name: String, command: String, summary: String = "", program: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.summary = summary
        self.program = program
    }

    /// The program whose presence is checked: `program`, else the
    /// command's first word.
    public var checkedProgram: String? {
        if let program, !program.isEmpty { return program }
        return command.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}

/// A launcher entry as the menu shows it.
public struct LaunchApp: Equatable, Sendable {
    public let name: String
    /// The key that picks it in the menu ("1" to "9").
    public let hotkey: String
    /// What gets typed at the zsh prompt to start it. Typed rather than run
    /// as the pane's command, so quitting the app leaves you in zsh, and the
    /// command lands in your history like anything else you run.
    public let command: String
    /// One line shown beside the name.
    public let summary: String
    /// Where the program was found, or nil when it was not (it may still be
    /// an alias or a function, so the entry stays usable; the menu says so).
    public let executable: String?

    public var isFound: Bool { executable != nil }
}

/// The apps offered in a new zsh pane, in menu order.
public enum LaunchCatalog {
    /// Keys 1-9 pick an app, so the menu holds at most nine.
    public static let maximumEntries = 9

    /// What Settings starts with (and Reset to Defaults restores).
    public static var defaults: [LauncherEntry] {
        [
            LauncherEntry(name: "opencode", command: "opencode", summary: "coding agent on the local model"),
            LauncherEntry(name: "claude", command: "claude", summary: "Claude Code"),
            LauncherEntry(name: "btop", command: "btop", summary: "system monitor"),
            LauncherEntry(name: "lazygit", command: "lazygit", summary: "git TUI"),
            // `y` is the dotfiles wrapper: quitting yazi cds the pane there.
            LauncherEntry(name: "yazi", command: "y", summary: "file manager; q leaves you in that folder", program: "yazi"),
        ]
    }

    /// Where to look: the app may run with a minimal PATH, so explicit
    /// Homebrew and per-user install locations (Claude Code's installer
    /// uses ~/.local/bin).
    static let searchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.opencode/bin", "~/.bun/bin", "/usr/bin", "/bin",
    ]

    /// The menu for `entries`: blank commands dropped, at most nine, keys
    /// 1-9 in order, each looked up on disk. A program given as a path is
    /// checked as is.
    public static func resolve(
        _ entries: [LauncherEntry],
        home: String,
        isExecutable: (String) -> Bool,
    ) -> [LaunchApp] {
        let directories = searchDirectories.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
        let usable = entries.filter { !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        return usable.prefix(maximumEntries).enumerated().map { index, entry in
            let found = entry.checkedProgram.flatMap { program -> String? in
                let expanded = program.hasPrefix("~/") ? home + program.dropFirst() : program
                if expanded.contains("/") { return isExecutable(expanded) ? expanded : nil }
                return directories.map { "\($0)/\(expanded)" }.first(where: isExecutable)
            }
            let name = entry.name.trimmingCharacters(in: .whitespaces)
            return LaunchApp(
                name: name.isEmpty ? entry.command : name, hotkey: String(index + 1),
                command: entry.command.trimmingCharacters(in: .whitespaces), summary: entry.summary, executable: found,
            )
        }
    }

    /// The app a key press selects, if any.
    public static func choice(forKey key: String, in apps: [LaunchApp]) -> LaunchApp? {
        apps.first { $0.hotkey == key }
    }

    /// Stored entries (JSON), or the defaults when nothing usable is stored.
    public static func decode(_ data: Data?) -> [LauncherEntry] {
        guard let data, let entries = try? JSONDecoder().decode([LauncherEntry].self, from: data) else {
            return defaults
        }
        return entries
    }

    public static func encode(_ entries: [LauncherEntry]) -> Data? {
        try? JSONEncoder().encode(entries)
    }
}
