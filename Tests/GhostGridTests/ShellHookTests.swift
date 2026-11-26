import Foundation
import Testing
@testable import GhostGridCore

/// Contract for the command-line report (PR 4): zsh and bash start through
/// ghostgrid's hook files, which run Ghostty's integration and then report
/// each command line before it runs, as OSC 633;E.
struct ShellHookTests {
    let resources = ShellLaunch.Resources(ghostty: "/R/Ghostty", terminfo: "/R/terminfo", features: "", integration: true,
                                          hooks: "/H")

    @Test func zshStartsThroughTheHookDirectory() throws {
        let launch = try #require(ShellLaunch.launch(id: "s", shell: ShellChoice(name: "zsh", hotkey: "1", executable: "/bin/zsh"),
                                                     base: [:], resources: resources, workingDirectory: nil))
        #expect(launch.environment["ZDOTDIR"] == "/H/zsh")
        #expect(launch.environment["GHOSTGRID_GHOSTTY_ZDOTDIR"] == "/R/Ghostty/shell-integration/zsh")
    }

    @Test func bashStartsThroughTheHookFile() throws {
        let launch = try #require(ShellLaunch.launch(id: "s", shell: ShellChoice(name: "bash", hotkey: "3", executable: "/bin/bash"),
                                                     base: [:], resources: resources, workingDirectory: nil))
        #expect(launch.environment["ENV"] == "/H/bash/ghostgrid.bash")
        #expect(launch.environment["GHOSTGRID_GHOSTTY_ENV"] == "/R/Ghostty/shell-integration/bash/ghostty.bash")
    }

    @Test func withoutHooksTheShellsStartAsBefore() throws {
        var plain = resources
        plain.hooks = nil
        let launch = try #require(ShellLaunch.launch(id: "s", shell: ShellChoice(name: "zsh", hotkey: "1", executable: "/bin/zsh"),
                                                     base: [:], resources: plain, workingDirectory: nil))
        #expect(launch.environment["ZDOTDIR"] == "/R/Ghostty/shell-integration/zsh")
        #expect(launch.environment["GHOSTGRID_GHOSTTY_ZDOTDIR"] == nil)
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/usr/bin/bash"])
    func theHookReportsCommandLinesExactly(shell: String) throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gg-hooks-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try ShellHooks.install(in: directory)
        let script = shell.hasSuffix("zsh") ? directory + "/zsh/.zshenv" : directory + "/bash/ghostgrid.bash"
        for command in ["ls -la", "a;b\\c", "two\nlines", "tab\there", "héllo 🌍", "echo '$HOME' \"x\""] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = (shell.hasSuffix("zsh") ? ["-f"] : ["--norc", "--noprofile"])
                + ["-c", "source \"$1\"; _ghostgrid_report_command \"$2\"", "sh", script, command]
            process.environment = ["GHOSTGRID_GHOSTTY_ZDOTDIR": "/nonexistent", "GHOSTGRID_GHOSTTY_ENV": "/dev/null",
                                   "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(output == "\u{1B}]633;E;" + CommandLineReport.escape(command) + "\u{07}", "\(shell): \(command)")
        }
    }
}
