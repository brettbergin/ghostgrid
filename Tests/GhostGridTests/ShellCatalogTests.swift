import Testing
@testable import GhostGridCore

struct ShellCatalogTests {
    private func resolve(_ installed: Set<String>) -> [ShellChoice] {
        ShellCatalog.resolve(home: "/Users/me") { installed.contains($0) }
    }

    @Test func menuOrderAndHotkeys() {
        let choices = resolve([])
        #expect(choices.map(\.name) == ["zsh", "nushell", "bash"])
        #expect(choices.map(\.hotkey) == ["1", "2", "3"])
    }

    @Test func missingShellsAreListedButNotInstalled() {
        let choices = resolve(["/bin/zsh", "/bin/bash"])
        #expect(choices.map(\.isInstalled) == [true, false, true])
        #expect(choices[1].command == nil)
    }

    @Test func homebrewBashBeatsSystemBash() {
        let choices = resolve(["/bin/bash", "/opt/homebrew/bin/bash"])
        #expect(choices[2].executable == "/opt/homebrew/bin/bash")
    }

    @Test func homeRelativeCandidatesExpand() {
        let choices = resolve(["/Users/me/.cargo/bin/nu"])
        #expect(choices[1].executable == "/Users/me/.cargo/bin/nu")
    }

    @Test func commandsStartLoginShells() {
        let choices = resolve(["/bin/zsh", "/opt/homebrew/bin/nu"])
        #expect(choices[0].command == "/bin/zsh -l")
        #expect(choices[1].command == "/opt/homebrew/bin/nu -l")
    }

    @Test func hotkeysPickOnlyInstalledShells() {
        let choices = resolve(["/bin/zsh", "/bin/bash"])
        #expect(ShellCatalog.choice(forKey: "1", in: choices)?.name == "zsh")
        #expect(ShellCatalog.choice(forKey: "3", in: choices)?.name == "bash")
        #expect(ShellCatalog.choice(forKey: "2", in: choices) == nil)
        #expect(ShellCatalog.choice(forKey: "9", in: choices) == nil)
    }
}

struct ShellConfigTests {
    private let bash = ShellChoice(name: "bash", hotkey: "3", executable: "/opt/homebrew/bin/bash")

    @Test func appendsTheCommandAfterTheUserConfig() {
        let text = ShellConfig.render(base: "font-size = 14", choice: bash)!
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.first == "font-size = 14")
        #expect(lines.last == "command = /opt/homebrew/bin/bash -l")
    }

    @Test func worksWithoutAUserConfig() {
        #expect(ShellConfig.render(base: nil, choice: bash)?.hasSuffix("command = /opt/homebrew/bin/bash -l\n") == true)
    }

    @Test func missingShellHasNoConfig() {
        #expect(ShellConfig.render(base: "x = 1", choice: ShellChoice(name: "nushell", hotkey: "2", executable: nil)) == nil)
    }
}

struct ShellIntegrationTests {
    @Test func nushellTurnsOffGhosttyInjectionAndBashKeepsIt() {
        let nu = ShellConfig.render(base: "", choice: ShellChoice(name: "nushell", hotkey: "2", executable: "/opt/homebrew/bin/nu"))!
        let bash = ShellConfig.render(base: "", choice: ShellChoice(name: "bash", hotkey: "3", executable: "/bin/bash"))!
        #expect(nu.contains("shell-integration = none"))
        #expect(!bash.contains("shell-integration"))
    }
}
