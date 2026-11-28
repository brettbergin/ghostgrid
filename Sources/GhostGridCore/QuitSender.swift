/// Who asked ghostgrid-sessiond to stop (a Quit request or a signal), as
/// its log names them: the process, its executable, and what started it, so
/// shells that ended can be traced to their cause. Only the process ID
/// comes with the request; the rest is looked up when it arrives, and the
/// sender may already be gone.
public struct QuitSender: CustomStringConvertible, Sendable {
    public var pid: Int32?
    public var path: String?
    public var parentPID: Int32?
    public var parentPath: String?

    public init(pid: Int32?, path: String?, parentPID: Int32?, parentPath: String?) {
        self.pid = pid
        self.path = path
        self.parentPID = parentPID
        self.parentPath = parentPath
    }

    /// "from pid 812 /usr/bin/osascript (started by pid 640 /bin/zsh)".
    public var description: String {
        guard let pid, pid > 0 else { return "from an unknown sender" }
        guard let path else { return "from pid \(pid) (no longer running)" }
        var text = "from pid \(pid) \(path)"
        if let parentPID, parentPID > 0 {
            text += " (started by pid \(parentPID) \(parentPath ?? "(no longer running)"))"
        }
        return text
    }
}
