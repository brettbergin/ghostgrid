/// Broadcast typing: keystrokes and pastes in the focused pane go to every
/// other pane of its window too (Shell > Broadcast Input).
public enum Broadcast {
    /// The panes (grid indices) that also get what is typed in `source`:
    /// none while broadcast is off, otherwise every other pane running a
    /// shell (`running`; a pane still showing its menu has none).
    public static func targets(from source: Int?, running: [Bool], enabled: Bool) -> [Int] {
        guard enabled, let source, running.indices.contains(source) else { return [] }
        return running.indices.filter { $0 != source && running[$0] }
    }

    /// Whether a key is repeated in the other panes. Command chords are
    /// ghostgrid's and macOS's shortcuts (close, new pane, copy), not
    /// typing: they act once, on the focused pane.
    public static func mirrors(command: Bool) -> Bool {
        !command
    }
}
