import Testing
@testable import GhostGridCore

struct GitBranchTests {
    /// A fake file system: directories and file contents by path.
    struct FS {
        var dirs: Set<String> = []
        var files: [String: String] = [:]

        func branch(_ from: String) -> String? {
            GitBranch.read(
                from: from,
                fileExists: { dirs.contains($0) || files[$0] != nil },
                isDirectory: { dirs.contains($0) },
                readFile: { files[$0] },
            )
        }
    }

    @Test func readsTheBranchFromTheNearestRepository() {
        let fs = FS(dirs: ["/r/.git"], files: ["/r/.git/HEAD": "ref: refs/heads/main\n"])
        #expect(fs.branch("/r") == "main")
        #expect(fs.branch("/r/src/deep") == "main")
        #expect(fs.branch("/elsewhere") == nil)
    }

    @Test func followsWorktreeGitFiles() {
        let fs = FS(
            dirs: ["/main/.git/worktrees/feat"],
            files: [
                "/wt/.git": "gitdir: /main/.git/worktrees/feat\n",
                "/main/.git/worktrees/feat/HEAD": "ref: refs/heads/brettbergin/feat\n",
            ],
        )
        #expect(fs.branch("/wt") == "brettbergin/feat")
    }

    @Test func relativeGitdirResolvesAgainstTheRepo() {
        let fs = FS(
            dirs: ["/super/.git/modules/sub"],
            files: ["/super/sub/.git": "gitdir: ../.git/modules/sub", "/super/.git/modules/sub/HEAD": "ref: refs/heads/dev"],
        )
        #expect(fs.branch("/super/sub") == "dev")
    }

    @Test func headParsing() {
        #expect(GitBranch.branch(fromHead: "ref: refs/heads/a/b") == "a/b")
        #expect(GitBranch.branch(fromHead: "0123456789abcdef0123456789abcdef01234567") == "0123456")
        #expect(GitBranch.branch(fromHead: "garbage") == nil)
    }
}

struct PathDisplayTests {
    @Test func homeBecomesTilde() {
        #expect(PathDisplay.short("/Users/me", home: "/Users/me") == "~")
        #expect(PathDisplay.short("/Users/me/code/x", home: "/Users/me") == "~/code/x")
        #expect(PathDisplay.short("/Users/meow", home: "/Users/me") == "/Users/meow")
    }

    @Test func longPathsKeepTheirEnd() {
        let short = PathDisplay.short("/Users/me/a/very/long/path/to/some/project/src", home: "/Users/me", maxLength: 20)
        #expect(short.count == 20)
        #expect(short.hasPrefix("…"))
        #expect(short.hasSuffix("project/src"))
    }
}

struct PaneActivityTests {
    @Test func onlyLongCommandsInUnfocusedPanesBadge() {
        let tenSeconds: UInt64 = 10_000_000_000
        #expect(PaneActivity.forFinishedCommand(exitCode: 0, durationNanos: tenSeconds, paneFocused: true) == nil)
        #expect(PaneActivity.forFinishedCommand(exitCode: 0, durationNanos: 1_000_000_000, paneFocused: false) == nil)
        #expect(PaneActivity.forFinishedCommand(exitCode: 0, durationNanos: tenSeconds, paneFocused: false) != nil)
    }

    @Test func labelsAndFailure() {
        #expect(PaneActivity.bell.label == "bell")
        #expect(PaneActivity.finished(exitCode: 0, seconds: 12.4).label == "12s")
        #expect(PaneActivity.finished(exitCode: nil, seconds: 65).label == "1m 05s")
        #expect(PaneActivity.finished(exitCode: 2, seconds: 30).label == "exit 2")
        #expect(PaneActivity.finished(exitCode: 2, seconds: 30).failed)
        #expect(!PaneActivity.finished(exitCode: 0, seconds: 30).failed)
        #expect(!PaneActivity.bell.failed)
    }
}
