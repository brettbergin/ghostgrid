import Testing
@testable import GhostGridCore

/// Contract for the helper's log when something stops it (a Quit request or
/// a signal): the line names who sent it, by process ID and executable, and
/// what started that process, so a lost shell can be traced to its cause.
struct QuitSenderTests {
    @Test func aSenderIsNamedWithWhatStartedIt() {
        let sender = QuitSender(pid: 812, path: "/usr/bin/osascript", parentPID: 640, parentPath: "/bin/zsh")
        #expect(sender.description == "from pid 812 /usr/bin/osascript (started by pid 640 /bin/zsh)")
    }

    @Test func launchdHasNoParentToName() {
        #expect(QuitSender(pid: 1, path: "/sbin/launchd", parentPID: 0, parentPath: nil).description
            == "from pid 1 /sbin/launchd")
    }

    @Test func aSenderAlreadyGoneIsStillNamedByItsID() {
        #expect(QuitSender(pid: 4242, path: nil, parentPID: nil, parentPath: nil).description
            == "from pid 4242 (no longer running)")
    }

    @Test func anEventWithoutASenderSaysSo() {
        #expect(QuitSender(pid: nil, path: nil, parentPID: nil, parentPath: nil).description == "from an unknown sender")
        #expect(QuitSender(pid: 0, path: nil, parentPID: nil, parentPath: nil).description == "from an unknown sender")
    }
}
