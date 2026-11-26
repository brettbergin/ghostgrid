import Foundation
import Testing
@testable import GhostGridCore

struct LaunchCatalogTests {
    private func resolve(_ entries: [LauncherEntry] = LaunchCatalog.defaults, _ installed: Set<String> = []) -> [LaunchApp] {
        LaunchCatalog.resolve(entries, home: "/Users/me") { installed.contains($0) }
    }

    @Test func defaultsAreTheFiveSuggestedApps() {
        let apps = resolve()
        #expect(apps.map(\.name) == ["opencode", "claude", "btop", "lazygit", "yazi"])
        #expect(apps.map(\.hotkey) == ["1", "2", "3", "4", "5"])
        #expect(apps[4].command == "y")
    }

    @Test func findsProgramsInHomebrewAndPerUserLocations() {
        let apps = resolve(LaunchCatalog.defaults, ["/opt/homebrew/bin/btop", "/Users/me/.local/bin/claude", "/opt/homebrew/bin/yazi"])
        #expect(apps[2].executable == "/opt/homebrew/bin/btop")
        #expect(apps[1].executable == "/Users/me/.local/bin/claude")
        #expect(apps[4].isFound, "y is checked as yazi")
        #expect(!apps[0].isFound)
    }

    @Test func customEntriesUseTheCommandsFirstWord() {
        let apps = resolve([LauncherEntry(name: "k9s", command: "k9s --readonly")], ["/opt/homebrew/bin/k9s"])
        #expect(apps[0].isFound)
        #expect(apps[0].command == "k9s --readonly")
    }

    @Test func aliasesStayUsableWhenNotFound() {
        let apps = resolve([LauncherEntry(name: "deploy", command: "dpl")])
        #expect(!apps[0].isFound)
        #expect(LaunchCatalog.choice(forKey: "1", in: apps)?.command == "dpl")
    }

    @Test func blankCommandsAreDroppedAndTheMenuStopsAtNine() {
        var entries = (1...12).map { LauncherEntry(name: "app\($0)", command: "app\($0)") }
        entries.insert(LauncherEntry(name: "blank", command: "   "), at: 0)
        let apps = resolve(entries)
        #expect(apps.count == 9)
        #expect(apps.first?.name == "app1")
        #expect(apps.last?.hotkey == "9")
        #expect(LaunchCatalog.choice(forKey: "0", in: apps) == nil)
    }

    @Test func emptyNamesFallBackToTheCommand() {
        #expect(resolve([LauncherEntry(name: " ", command: "htop")])[0].name == "htop")
    }

    @Test func storedEntriesRoundTripAndBadDataMeansDefaults() {
        let custom = [LauncherEntry(name: "k9s", command: "k9s", summary: "cluster")]
        #expect(LaunchCatalog.decode(LaunchCatalog.encode(custom)) == custom)
        #expect(LaunchCatalog.decode(nil).map(\.name) == LaunchCatalog.defaults.map(\.name))
        #expect(LaunchCatalog.decode(Data("nope".utf8)).count == 5)
        #expect(LaunchCatalog.decode(LaunchCatalog.encode([])).isEmpty, "an emptied list stays empty")
    }
}
