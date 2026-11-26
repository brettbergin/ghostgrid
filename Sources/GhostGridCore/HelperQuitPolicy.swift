/// How the session helper answers a Quit Apple event. macOS sends one when
/// ghostgrid quits; obeying it would end every shell, so the helper
/// declines it. A Quit that comes with a log out, restart or shut down
/// says so in its reason, and is obeyed, so the helper never holds those
/// up.
public enum HelperQuitPolicy {
    /// The Quit event's reason (keyAEQuitReason, 'why?').
    public static let reasonKeyword: UInt32 = fourCharacterCode("why?")

    /// kAELogOut, kAEReallyLogOut, kAEShowRestartDialog,
    /// kAEShowShutdownDialog, kAERestart, kAEShutDown.
    static let systemReasons: Set<UInt32> = Set(["logo", "rlgo", "rrst", "rsdn", "rest", "shut"].map(fourCharacterCode))

    public static func allowsQuit(reason: UInt32?) -> Bool {
        reason.map(systemReasons.contains) ?? false
    }

    static func fourCharacterCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
