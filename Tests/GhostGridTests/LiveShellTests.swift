import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif
import Testing
@testable import GhostGridCore

/// Contract for shells that survive quitting, app side: each saved pane
/// remembers its running shell, live shells come back even when windows
/// would not, and panes get Ghostty's shell-integration features.
struct LiveShellTests {
    @Test func aPaneRemembersItsRunningShell() throws {
        let session = Session(windows: [.init(frame: .zero, tabs: [.init(panes: [
            .init(shell: "zsh", workingDirectory: "/tmp", sessionID: "abc"),
            .init(shell: "bash", workingDirectory: nil),
        ])])])
        let decoded = try #require(Session.decode(try session.encoded()))
        #expect(decoded.windows[0].tabs[0].panes.map(\.sessionID) == ["abc", nil])
        #expect(decoded.liveSessionIDs == ["abc"])
        let old = #"{"version":1,"windows":[{"frame":[[0,0],[10,10]],"panes":[{"shell":"zsh"}]}]}"#
        #expect(Session.decode(Data(old.utf8))?.windows[0].tabs[0].panes[0].sessionID == nil, "older files still load")
    }

    @Test func liveShellsComeBackUnlessRestoreIsOff() {
        // macOS closes windows on quit by default; kept shells still return.
        #expect(SessionPolicy.shouldRestore(windowSaveState: nil, systemKeepsWindows: false, keepsShells: true))
        #expect(SessionPolicy.shouldRestore(windowSaveState: "default", systemKeepsWindows: false, keepsShells: true))
        #expect(!SessionPolicy.shouldRestore(windowSaveState: "never", systemKeepsWindows: true, keepsShells: true))
        // Without kept shells: window-save-state as before.
        #expect(!SessionPolicy.shouldRestore(windowSaveState: nil, systemKeepsWindows: false, keepsShells: false))
        #expect(SessionPolicy.shouldRestore(windowSaveState: "always", systemKeepsWindows: false, keepsShells: false))
    }

    @Test func shellFeaturesFollowTheGhosttyConfig() {
        #expect(ShellLaunch.features(config: nil) == "cursor,title,path", "Ghostty's defaults")
        #expect(ShellLaunch.features(config: "no-cursor,sudo") == "sudo,title,path")
        #expect(ShellLaunch.features(config: " sudo , no-title , ssh-env ") == "cursor,sudo,ssh-env,path")
        #expect(ShellLaunch.features(config: "false") == "")
        #expect(ShellLaunch.features(config: "true") == "cursor,sudo,title,ssh-env,ssh-terminfo,path")
    }

    @Test func integrationIsOnlyForBundledShellsAndCanBeTurnedOff() {
        #expect(ShellLaunch.usesIntegration(shell: "zsh", config: nil))
        #expect(ShellLaunch.usesIntegration(shell: "bash", config: "detect"))
        #expect(!ShellLaunch.usesIntegration(shell: "nushell", config: nil))
        #expect(!ShellLaunch.usesIntegration(shell: "zsh", config: "none"))
    }
}
