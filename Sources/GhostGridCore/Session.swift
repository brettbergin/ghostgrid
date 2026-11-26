import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif

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
        /// nil in sessions saved before layouts existed: grid.
        public var layout: GridLayout.Mode?
        /// Divider adjustments (resizable panes); nil: balanced.
        public var weights: LayoutWeights?

        public init(
            frame: CGRect, panes: [Pane], focused: Int? = nil, zoomed: Int? = nil, layout: GridLayout.Mode? = nil,
            weights: LayoutWeights? = nil,
        ) {
            self.weights = weights
            self.frame = frame
            self.panes = panes
            self.focused = focused
            self.zoomed = zoomed
            self.layout = layout
        }
    }

    public struct Pane: Codable, Equatable, Sendable {
        /// ShellChoice name ("zsh", "nushell", "bash").
        public var shell: String
        public var workingDirectory: String?
        /// The shell still running in ghostgrid-sessiond (shells that
        /// survive quitting); nil when it was not kept.
        public var sessionID: String?

        public init(shell: String, workingDirectory: String?, sessionID: String? = nil) {
            self.shell = shell
            self.workingDirectory = workingDirectory
            self.sessionID = sessionID
        }
    }

    /// Every pane's kept shell, in window and grid order.
    public var liveSessionIDs: [String] {
        windows.flatMap { $0.panes.compactMap(\.sessionID) }
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
    /// With shells kept running across quits, the windows come back to
    /// show them whatever macOS's setting says; only "never" opts out
    /// (and then the kept shells are ended).
    public static func shouldRestore(windowSaveState: String?, systemKeepsWindows: Bool, keepsShells: Bool) -> Bool {
        if keepsShells, windowSaveState?.lowercased() != "never" { return true }
        return shouldRestore(windowSaveState: windowSaveState, systemKeepsWindows: systemKeepsWindows)
    }

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
