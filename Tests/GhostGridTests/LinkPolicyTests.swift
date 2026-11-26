import Foundation
import Testing
@testable import GhostGridCore

struct LinkPolicyTests {
    private func open(_ raw: String, cwd: String? = "/Users/me/code", existing: Set<String> = []) -> URL? {
        LinkPolicy.url(for: raw, workingDirectory: cwd, home: "/Users/me") { existing.contains($0) }
    }

    @Test func webMailAndFileLinksOpen() {
        #expect(open("https://ghostty.org/docs")?.absoluteString == "https://ghostty.org/docs")
        #expect(open("http://localhost:3000")?.host == "localhost")
        #expect(open("mailto:me@example.com")?.scheme == "mailto")
        #expect(open("file:///tmp/x.txt")?.path == "/tmp/x.txt")
    }

    @Test func otherSchemesAreRefused() {
        #expect(open("javascript:alert(1)") == nil)
        #expect(open("vscode://file/etc/passwd") == nil)
        #expect(open("x-apple.systempreferences:com.apple.preference") == nil)
    }

    @Test func barePathsOpenOnlyWhenTheyExist() {
        #expect(open("/etc/hosts", existing: ["/etc/hosts"])?.path == "/etc/hosts")
        #expect(open("/nope") == nil)
    }

    @Test func relativeAndHomePathsResolve() {
        #expect(open("README.md", existing: ["/Users/me/code/README.md"])?.path == "/Users/me/code/README.md")
        #expect(open("../notes.txt", existing: ["/Users/me/notes.txt"])?.path == "/Users/me/notes.txt")
        #expect(open("~/x", existing: ["/Users/me/x"])?.path == "/Users/me/x")
        #expect(open("README.md", cwd: nil) == nil)
    }
}

struct GhosttyConfigValuesTests {
    let config = GhosttyConfigValues("""
    # comment = ignored
    mouse-hide-while-typing = true
    unfocused-split-opacity = 0.85
    unfocused-split-opacity = 0.7
    font-family = "JetBrainsMono NF"
    """)

    @Test func lastValueWinsAndTypesParse() {
        #expect(config.bool("mouse-hide-while-typing", default: false))
        #expect(config.double("unfocused-split-opacity", default: 1) == 0.7)
        #expect(config.string("font-family") == "JetBrainsMono NF")
    }

    @Test func missingOrInvalidFallsBack() {
        #expect(!config.bool("copy-on-select", default: false))
        #expect(config.double("nope", default: 0.5) == 0.5)
        #expect(config.string("# comment") == nil)
    }
}
