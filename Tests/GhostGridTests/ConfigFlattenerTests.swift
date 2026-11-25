import Foundation
import Testing
@testable import GhostGridCore

struct ConfigFlattenerTests {
    /// A temporary config directory with the given files.
    private func directory(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostgrid-tests-\(UUID().uuidString)", isDirectory: true)
        for (name, contents) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Non-comment, non-blank lines of the flattened output.
    private func settings(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @Test func includesLoadAfterTheIncludingFileInOrder() throws {
        // Ghostty loads config-file includes after the whole including file,
        // in the order listed, so a later include wins over the main file.
        let dir = try directory([
            "config.ghostty": "font-size = 12\nconfig-file = a.ghostty\nconfig-file = b.ghostty\ncursor-style = block\n",
            "a.ghostty": "font-size = 13\n",
            "b.ghostty": "font-size = 14\n",
        ])
        let out = try ConfigFlattener.flatten(dir.appendingPathComponent("config.ghostty"))
        #expect(settings(out) == ["font-size = 12", "cursor-style = block", "font-size = 13", "font-size = 14"])
    }

    @Test func nestedIncludesResolveRelativeToTheirOwnFile() throws {
        let dir = try directory([
            "config": "config-file = sub/one.ghostty\n",
            "sub/one.ghostty": "config-file = two.ghostty\nfont-size = 1\n",
            "sub/two.ghostty": "font-size = 2\n",
        ])
        let out = try ConfigFlattener.flatten(dir.appendingPathComponent("config"))
        #expect(settings(out) == ["font-size = 1", "font-size = 2"])
    }

    @Test func optionalMissingIncludeIsSkippedButRequiredOneFails() throws {
        let dir = try directory([
            "ok": "config-file = ?missing.ghostty\nfont-size = 1\n",
            "bad": "config-file = missing.ghostty\n",
        ])
        #expect(settings(try ConfigFlattener.flatten(dir.appendingPathComponent("ok"))) == ["font-size = 1"])
        #expect(throws: ConfigFlattener.Error.self) {
            try ConfigFlattener.flatten(dir.appendingPathComponent("bad"))
        }
    }

    @Test func quotedIncludePathsWork() throws {
        let dir = try directory([
            "config": "config-file = \"my file.ghostty\"\n",
            "my file.ghostty": "font-size = 9\n",
        ])
        #expect(settings(try ConfigFlattener.flatten(dir.appendingPathComponent("config"))) == ["font-size = 9"])
    }

    @Test func includeCyclesAreBroken() throws {
        let dir = try directory([
            "a": "config-file = b\nfont-size = 1\n",
            "b": "config-file = a\nfont-size = 2\n",
        ])
        #expect(settings(try ConfigFlattener.flatten(dir.appendingPathComponent("a"))) == ["font-size = 1", "font-size = 2"])
    }

    @Test func relativeFilePathsBecomeAbsolute() throws {
        let dir = try directory([
            "config": "config-file = fx/effects.ghostty\ncustom-shader = top.glsl\n",
            "fx/effects.ghostty": "custom-shader = shaders/trail.glsl\ncustom-shader = /abs/x.glsl\ncustom-shader = ~/home.glsl\n",
        ])
        let out = settings(try ConfigFlattener.flatten(dir.appendingPathComponent("config")))
        let base = dir.standardizedFileURL.path
        #expect(out == [
            "custom-shader = \(base)/top.glsl",
            "custom-shader = \(base)/fx/shaders/trail.glsl",
            "custom-shader = /abs/x.glsl",
            "custom-shader = ~/home.glsl",
        ])
    }

    @Test func otherLinesPassThroughUnchanged() throws {
        let dir = try directory([
            "config": "theme = light:Catppuccin Latte,dark:Catppuccin Mocha Black\nkeybind = global:ctrl+grave_accent=toggle_quick_terminal\n",
        ])
        let out = settings(try ConfigFlattener.flatten(dir.appendingPathComponent("config")))
        #expect(out == [
            "theme = light:Catppuccin Latte,dark:Catppuccin Mocha Black",
            "keybind = global:ctrl+grave_accent=toggle_quick_terminal",
        ])
    }
}
