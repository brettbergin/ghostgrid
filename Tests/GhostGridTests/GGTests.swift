import Foundation
import Testing

/// Contract for `gg` (Scripts/gg) bundled in the app, so the Homebrew cask
/// can link it onto PATH: run through a link to the copy inside an app, it
/// opens that app (wherever it was installed); GHOSTGRID_APP still wins.
/// `open` is a stand-in that prints its arguments, one per line.
struct GGTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scripts/gg").path

    private struct Install {
        let root: String
        var app: String { root + "/Applications/Fake.app" }
        var linked: String { root + "/brew/bin/gg" }
        var folder: String { root + "/project" }
    }

    /// An app holding gg at Contents/Resources/bin/gg, linked from a bin
    /// folder the way the cask's `binary` stanza links it.
    private func install() throws -> Install {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gg-test-\(UUID().uuidString)").path
        let install = Install(root: root)
        let fm = FileManager.default
        for dir in [install.app + "/Contents/Resources/bin", root + "/brew/bin", root + "/stub", install.folder] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try fm.copyItem(atPath: Self.script, toPath: install.app + "/Contents/Resources/bin/gg")
        try fm.createSymbolicLink(atPath: install.linked, withDestinationPath: install.app + "/Contents/Resources/bin/gg")
        try Data("#!/bin/sh\nfor arg; do printf '%s\\n' \"$arg\"; done\n".utf8)
            .write(to: URL(fileURLWithPath: root + "/stub/open"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/stub/open")
        return install
    }

    private func run(_ path: String, _ arguments: [String], in install: Install, app: String? = nil) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path] + arguments
        var environment = ["PATH": install.root + "/stub:/usr/bin:/bin", "HOME": install.root]
        environment["GHOSTGRID_APP"] = app
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: install.folder)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
    }

    @Test func linkedGGOpensTheAppItLivesIn() throws {
        let install = try install()
        defer { try? FileManager.default.removeItem(atPath: install.root) }
        let opened = try run(install.linked, [install.folder], in: install)
        #expect(opened.count == 3)
        #expect(opened.first == "-a")
        #expect(opened.dropFirst().first?.hasSuffix("/Applications/Fake.app") == true, "\(opened)")
        #expect(opened.last == install.folder)
    }

    @Test func ghostgridAppStillWins() throws {
        let install = try install()
        defer { try? FileManager.default.removeItem(atPath: install.root) }
        let elsewhere = install.root + "/Other.app"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        #expect(try run(install.linked, [install.folder], in: install, app: elsewhere) == ["-a", elsewhere, install.folder])
    }

    @Test func aFileIsNotAFolder() throws {
        let install = try install()
        defer { try? FileManager.default.removeItem(atPath: install.root) }
        FileManager.default.createFile(atPath: install.folder + "/notes.txt", contents: Data())
        #expect(try run(install.linked, [install.folder + "/notes.txt"], in: install).isEmpty, "nothing is opened")
    }
}
