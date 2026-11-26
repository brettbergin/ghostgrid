/// A shell a new pane can start, and where it was found.
public struct ShellChoice: Equatable, Sendable {
    public let name: String
    /// The key that picks it in the pane's shell menu ("1", "2", ...).
    public let hotkey: String
    /// Absolute path of the executable, or nil when it is not installed.
    public let executable: String?

    public var isInstalled: Bool { executable != nil }

    /// The surface command: a login shell, so ~/.zprofile (Homebrew, mise)
    /// and friends load the way they do in a normal terminal tab.
    public var command: String? {
        executable.map { "\($0) -l" }
    }
}

/// The Ghostty config for panes running `choice`: the user's flattened
/// config with the shell's `command` appended (later values win).
///
/// The command goes in the config rather than on the surface because this
/// libghostty build drops a per-surface command and starts the default
/// shell; an app-level `command` is always honoured.
public enum ShellConfig {
    /// Shells whose Ghostty integration scripts libghostty-spm bundles.
    /// For any other shell Ghostty would inject an integration that is not
    /// there (nushell: `use ghostty *` fails on every start), so it is
    /// turned off; nushell emits the same OSC 133/7 markers on its own.
    static let integratedShells: Set<String> = ["zsh", "bash"]

    public static func render(base: String?, choice: ShellChoice) -> String? {
        guard let command = choice.command else { return nil }
        var text = base ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "\n# ghostgrid: shell for panes started as \(choice.name)\ncommand = \(command)\n"
        if !integratedShells.contains(choice.name) {
            text += "shell-integration = none\n"
        }
        return text
    }
}

/// The shells offered in every new pane, in menu order.
public enum ShellCatalog {
    /// Candidate locations per shell, best first. The app may be launched
    /// from Finder with a minimal PATH, so these are explicit paths. A
    /// Homebrew bash wins over macOS's bash 3.2.
    static let known: [(name: String, candidates: [String])] = [
        ("zsh", ["/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"]),
        ("nushell", ["/opt/homebrew/bin/nu", "/usr/local/bin/nu", "~/.cargo/bin/nu"]),
        ("bash", ["/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/bash"]),
    ]

    public static func resolve(home: String, isExecutable: (String) -> Bool) -> [ShellChoice] {
        known.enumerated().map { index, shell in
            let found = shell.candidates
                .map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
                .first(where: isExecutable)
            return ShellChoice(name: shell.name, hotkey: String(index + 1), executable: found)
        }
    }

    /// The shell remembered from the last menu pick, if it is still
    /// installed; nil means show the menu instead.
    public static func remembered(_ name: String?, in choices: [ShellChoice]) -> ShellChoice? {
        guard let name else { return nil }
        return choices.first { $0.name == name && $0.isInstalled }
    }

    /// The installed choice a key press selects, if any.
    public static func choice(forKey key: String, in choices: [ShellChoice]) -> ShellChoice? {
        choices.first { $0.hotkey == key && $0.isInstalled }
    }
}
