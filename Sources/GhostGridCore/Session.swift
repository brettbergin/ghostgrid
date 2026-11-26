import CoreGraphics
import Foundation

/// What ghostgrid saves on quit and rebuilds on launch: each window's
/// frame and its panes in grid order (shell and working directory), plus
/// which pane had focus and which was zoomed. Scrollback is not saved,
/// matching Ghostty's window-save-state.
public struct Session: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var windows: [Window]

    public init(windows: [Window]) {
        version = Self.currentVersion
        self.windows = windows
    }

    public struct Window: Codable, Equatable, Sendable {
        /// Screen coordinates (AppKit, origin bottom-left).
        public var frame: CGRect
        public var panes: [Pane]
        public var focused: Int?
        public var zoomed: Int?

        public init(frame: CGRect, panes: [Pane], focused: Int? = nil, zoomed: Int? = nil) {
            self.frame = frame
            self.panes = panes
            self.focused = focused
            self.zoomed = zoomed
        }
    }

    public struct Pane: Codable, Equatable, Sendable {
        /// ShellChoice name ("zsh", "nushell", "bash").
        public var shell: String
        public var workingDirectory: String?

        public init(shell: String, workingDirectory: String?) {
            self.shell = shell
            self.workingDirectory = workingDirectory
        }
    }

    /// Windows worth restoring: with at least one pane, and focus/zoom
    /// indices that point at a pane (dropped otherwise).
    public var restorable: [Window] {
        windows.compactMap { window in
            guard !window.panes.isEmpty else { return nil }
            var window = window
            if let focused = window.focused, !window.panes.indices.contains(focused) { window.focused = nil }
            if let zoomed = window.zoomed, !window.panes.indices.contains(zoomed) { window.zoomed = nil }
            return window
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// nil for unreadable data or a version this build does not know.
    public static func decode(_ data: Data) -> Session? {
        guard let session = try? JSONDecoder().decode(Session.self, from: data),
              session.version == currentVersion
        else { return nil }
        return session
    }
}

/// Whether to restore the last session, following Ghostty's
/// `window-save-state`: "always" restores, "never" does not, and "default"
/// (or unset) follows macOS's "Close windows when quitting an application"
/// setting, which ghostgrid sees as `systemKeepsWindows`.
public enum SessionPolicy {
    public static func shouldRestore(windowSaveState: String?, systemKeepsWindows: Bool) -> Bool {
        switch windowSaveState?.lowercased() {
        case "always": true
        case "never": false
        default: systemKeepsWindows
        }
    }

    /// A saved window frame placed back on screen: kept when enough of it
    /// is visible on some screen, otherwise moved onto the first screen
    /// (shrunk to fit), so a window saved on a disconnected display is not
    /// lost off-screen. nil when there are no screens.
    public static func fit(_ frame: CGRect, screens: [CGRect], minimumVisible: CGFloat = 0.3) -> CGRect? {
        guard let main = screens.first, frame.width > 0, frame.height > 0 else { return screens.first }
        let area = frame.width * frame.height
        for screen in screens {
            let overlap = frame.intersection(screen)
            if !overlap.isNull, overlap.width * overlap.height >= area * minimumVisible {
                return frame
            }
        }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
