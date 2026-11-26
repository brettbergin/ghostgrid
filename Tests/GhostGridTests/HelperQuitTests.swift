import Testing
@testable import GhostGridCore

/// Contract for the session helper's answer to a Quit Apple event: macOS
/// asks it to quit when ghostgrid quits, which would end every shell, so
/// it declines; it still quits when the user logs out, restarts or shuts
/// down (the event then says why), so it never holds those up.
struct HelperQuitTests {
    /// Four-character codes as Apple events carry them.
    private func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    @Test func aPlainQuitIsDeclined() {
        #expect(!HelperQuitPolicy.allowsQuit(reason: nil))
    }

    @Test(arguments: ["logo", "rlgo", "rrst", "rsdn", "rest", "shut"])
    func logOutRestartAndShutDownAreAllowed(reason: String) {
        #expect(HelperQuitPolicy.allowsQuit(reason: code(reason)), "\(reason)")
    }

    @Test func anUnknownReasonIsDeclined() {
        #expect(!HelperQuitPolicy.allowsQuit(reason: code("abcd")))
    }

    @Test func theReasonIsReadFromTheQuitReasonKeyword() {
        #expect(HelperQuitPolicy.reasonKeyword == code("why?"))
    }
}
