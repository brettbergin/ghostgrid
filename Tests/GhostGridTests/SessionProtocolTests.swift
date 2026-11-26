import Foundation
import Testing
@testable import GhostGridCore

/// Contract for shells that survive quitting (PR 2): the wire format between
/// ghostgrid and sessiond, the bounded output history a reattach replays, and
/// how each shell is launched.
struct SessionProtocolTests {
    let all: [SessionMessage] = [
        .hello(version: 1),
        .create(SessionLaunch(id: "a", executable: "/bin/zsh", arguments: ["-zsh"], environment: ["TERM": "xterm-ghostty"],
                              workingDirectory: "/tmp", columns: 120, rows: 40)),
        .attach(id: "a"),
        .input(Data([0x6C, 0x73, 0x0D])),
        .resize(columns: 132, rows: 43, width: 1320, height: 860),
        .terminate,
        .welcome(version: 1),
        .attached(id: "a", replay: Data("\u{1B}cprompt\n".utf8)),
        .output(Data((0...255).map { UInt8($0) })),
        .exited(code: 130),
        .failure("no such session"),
    ]

    @Test func everyMessageRoundTrips() {
        var decoder = SessionFrameDecoder()
        let decoded = decoder.append(all.map { $0.encoded() }.reduce(Data(), +))
        #expect(decoded == all)
        #expect(!decoder.isBroken)
    }

    @Test func framesSurviveAnySplit() {
        let stream = all.map { $0.encoded() }.reduce(Data(), +)
        for chunk in [1, 2, 3, 7, 64] {
            var decoder = SessionFrameDecoder()
            var decoded: [SessionMessage] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunk, stream.count)
                decoded += decoder.append(stream.subdata(in: offset..<end))
                offset = end
            }
            #expect(decoded == all, "chunk \(chunk)")
        }
    }

    @Test func garbageBreaksTheStream() {
        var decoder = SessionFrameDecoder()
        #expect(decoder.append(Data([0, 0, 0, 2, 0xEE, 0])).isEmpty)
        #expect(decoder.isBroken)
        var huge = SessionFrameDecoder()
        _ = huge.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(huge.isBroken)
    }
}

struct OutputHistoryTests {
    @Test func replayStartsWithAResetAndKeepsEverythingWhenSmall() {
        var history = OutputHistory(capacity: 100)
        history.append(Data("hello\n".utf8))
        history.append(Data("world".utf8))
        #expect(history.replay == Data("\u{1B}chello\nworld".utf8))
    }

    @Test func keepsOnlyTheNewestBytesAndStartsAtALineBoundary() {
        var history = OutputHistory(capacity: 16)
        history.append(Data("first line\nsecond line\nthird\n".utf8))
        let replay = String(decoding: history.replay, as: UTF8.self)
        #expect(replay.hasPrefix("\u{1B}c"))
        #expect(!replay.contains("first"))
        #expect(replay.hasSuffix("third\n"))
        #expect(history.replay.count <= 16 + 2)
    }
}

struct ShellLaunchTests {
    let resources = ShellLaunch.Resources(ghostty: "/R/Ghostty", terminfo: "/R/terminfo", features: "cursor,title", integration: true)
    let base = ["HOME": "/Users/me", "PATH": "/usr/bin:/bin"]

    private func shell(_ name: String, _ path: String) -> ShellChoice {
        ShellChoice(name: name, hotkey: "1", executable: path)
    }

    @Test func zshIsALoginShellWithGhosttysIntegration() throws {
        let launch = try #require(ShellLaunch.launch(id: "s1", shell: shell("zsh", "/bin/zsh"), base: base,
                                                     resources: resources, workingDirectory: "/tmp"))
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.arguments == ["-zsh"])
        #expect(launch.environment["ZDOTDIR"] == "/R/Ghostty/shell-integration/zsh")
        #expect(launch.environment["TERM"] == "xterm-ghostty")
        #expect(launch.environment["TERMINFO"] == "/R/terminfo")
        #expect(launch.environment["GHOSTTY_SHELL_FEATURES"] == "cursor,title")
        #expect(launch.environment["GHOSTGRID_SESSION"] == "s1")
        #expect(launch.environment["PATH"] == "/usr/bin:/bin", "the base environment is kept")
        #expect(launch.workingDirectory == "/tmp")
    }

    @Test func aUsersZdotdirIsHandedToTheIntegration() throws {
        let launch = try #require(ShellLaunch.launch(id: "s", shell: shell("zsh", "/bin/zsh"),
                                                     base: base.merging(["ZDOTDIR": "/Users/me/.zsh"]) { $1 },
                                                     resources: resources, workingDirectory: nil))
        #expect(launch.environment["GHOSTTY_ZSH_ZDOTDIR"] == "/Users/me/.zsh")
    }

    @Test func bashRunsInPosixModeWithEnvPointingAtTheIntegration() throws {
        let launch = try #require(ShellLaunch.launch(id: "s", shell: shell("bash", "/opt/homebrew/bin/bash"), base: base,
                                                     resources: resources, workingDirectory: nil))
        #expect(launch.arguments == ["-bash", "--posix"])
        #expect(launch.environment["ENV"] == "/R/Ghostty/shell-integration/bash/ghostty.bash")
        #expect(launch.environment["GHOSTTY_BASH_INJECT"] == "1")
        #expect(launch.environment["HISTFILE"] == "/Users/me/.bash_history")
        #expect(launch.environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] == "1")
    }

    @Test func nushellUsesItsOwnLoginFlagAndNoInjection() throws {
        let launch = try #require(ShellLaunch.launch(id: "s", shell: shell("nushell", "/opt/homebrew/bin/nu"), base: base,
                                                     resources: resources, workingDirectory: nil))
        #expect(launch.arguments == ["nu", "-l"])
        #expect(launch.environment["ZDOTDIR"] == nil && launch.environment["ENV"] == nil)
    }

    @Test func integrationOffMeansAPlainLoginShell() throws {
        var off = resources
        off.integration = false
        let launch = try #require(ShellLaunch.launch(id: "s", shell: shell("zsh", "/bin/zsh"), base: base,
                                                     resources: off, workingDirectory: nil))
        #expect(launch.arguments == ["-zsh"])
        #expect(launch.environment["ZDOTDIR"] == nil)
    }

    @Test func aMissingShellCannotLaunch() {
        #expect(ShellLaunch.launch(id: "s", shell: ShellChoice(name: "zsh", hotkey: "1", executable: nil), base: base,
                                   resources: resources, workingDirectory: nil) == nil)
    }
}
