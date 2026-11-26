import Testing
@testable import GhostGridCore

struct LaunchCatalogTests {
    private func resolve(_ installed: Set<String>) -> [LaunchApp] {
        LaunchCatalog.resolve(home: "/Users/me") { installed.contains($0) }
    }

    @Test func fiveAppsInOrderWithHotkeys() {
        let apps = resolve([])
        #expect(apps.map(\.name) == ["opencode", "claude", "btop", "lazygit", "yazi"])
        #expect(apps.map(\.hotkey) == ["1", "2", "3", "4", "5"])
    }

    @Test func findsHomebrewAndPerUserInstalls() {
        let apps = resolve(["/opt/homebrew/bin/btop", "/Users/me/.local/bin/claude"])
        #expect(apps[2].executable == "/opt/homebrew/bin/btop")
        #expect(apps[1].executable == "/Users/me/.local/bin/claude")
        #expect(!apps[0].isInstalled)
    }

    @Test func yaziRunsTheCdOnQuitWrapper() {
        let apps = resolve(["/opt/homebrew/bin/yazi"])
        #expect(apps[4].command == "y")
    }

    @Test func hotkeysPickOnlyInstalledApps() {
        let apps = resolve(["/opt/homebrew/bin/lazygit"])
        #expect(LaunchCatalog.choice(forKey: "4", in: apps)?.name == "lazygit")
        #expect(LaunchCatalog.choice(forKey: "1", in: apps) == nil)
        #expect(LaunchCatalog.choice(forKey: "6", in: apps) == nil)
    }
}
