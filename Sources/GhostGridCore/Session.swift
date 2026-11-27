import Foundation
#if canImport(CoreGraphics)
    import CoreGraphics // CGRect's Codable conformance on macOS
#endif

/// What ghostgrid saves on quit and rebuilds on launch: each window's
/// frame and its panes in grid order (shell and working directory), plus
/// which pane had focus and which was zoomed. Scrollback is not saved,
/// matching Ghostty's window-save-state.
/// What ghostgrid saves on quit and rebuilds on launch: each window's
/// frame and its tabs in order (which one is selected), and each tab's
/// name, color and panes in grid order (shell, working directory, kept
/// shell), with which pane had focus, which was zoomed and the layout.
/// Scrollback is not saved here (kept shells bring theirs back).
///
/// Version 2 added tabs. A version 1 file (0.2.1 and earlier) loads as one
/// tab per window with everything it had.
public struct Session: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var windows: [Window]

    public init(windows: [Window]) {
        version = Self.currentVersion
        self.windows = windows
    }

    public struct Window: Codable, Equatable, Sendable {
        /// Screen coordinates (AppKit, origin bottom-left).
        public var frame: CGRect
        public var tabs: [Tab]
        /// Index into `tabs`; nil: the first.
        public var selectedTab: Int?

        public init(frame: CGRect, tabs: [Tab], selectedTab: Int? = nil) {
            self.frame = frame
            self.tabs = tabs
            self.selectedTab = selectedTab
        }
    }

    /// One tab: its own grid of panes and how they are arranged.
    public struct Tab: Codable, Equatable, Sendable {
        /// The name you gave it; nil: "Tab N" by position.
        public var name: String?
        public var color: TabColor?
        public var panes: [Pane]
        public var focused: Int?
        public var zoomed: Int?
        /// nil in sessions saved before layouts existed: grid.
        public var layout: GridLayout.Mode?
        /// Divider adjustments (resizable panes); nil: balanced.
        public var weights: LayoutWeights?
        /// The grid's panes per row after rows were moved; nil: balanced.
        public var rows: [Int]?
        /// Rotate Layout: the split the window's shape would pick, turned
        /// (stacked in a wide window); nil: not rotated.
        public var rotated: Bool?

        public init(
            name: String? = nil, color: TabColor? = nil, panes: [Pane], focused: Int? = nil, zoomed: Int? = nil,
            layout: GridLayout.Mode? = nil, weights: LayoutWeights? = nil, rows: [Int]? = nil, rotated: Bool? = nil,
        ) {
            self.name = name
            self.color = color
            self.panes = panes
            self.focused = focused
            self.zoomed = zoomed
            self.layout = layout
            self.weights = weights
            self.rows = rows
            self.rotated = rotated
        }

        private enum CodingKeys: String, CodingKey {
            case name, color, panes, focused, zoomed, layout, weights, rows, rotated
        }

        /// A color this build does not know (saved by a newer one) is
        /// dropped rather than failing the whole session.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            color = (try? container.decodeIfPresent(TabColor.self, forKey: .color)) ?? nil
            panes = try container.decode([Pane].self, forKey: .panes)
            focused = try container.decodeIfPresent(Int.self, forKey: .focused)
            zoomed = try container.decodeIfPresent(Int.self, forKey: .zoomed)
            layout = try container.decodeIfPresent(GridLayout.Mode.self, forKey: .layout)
            weights = try container.decodeIfPresent(LayoutWeights.self, forKey: .weights)
            rows = try container.decodeIfPresent([Int].self, forKey: .rows)
            rotated = try container.decodeIfPresent(Bool.self, forKey: .rotated)
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

    /// Every pane's kept shell, in window, tab and grid order.
    public var liveSessionIDs: [String] {
        windows.flatMap { $0.tabs.flatMap { $0.panes.compactMap(\.sessionID) } }
    }

    /// Windows worth restoring: tabs with at least one pane (focus and zoom
    /// indices that point at no pane are dropped) and windows with at least
    /// one such tab. The selected tab stays selected; when it was dropped,
    /// the tab that took its place (or the new last one) is.
    public var restorable: [Window] {
        windows.compactMap { window in
            var tabs: [Tab] = []
            var selected: Int?
            let wanted = window.selectedTab ?? 0
            for (index, tab) in window.tabs.enumerated() {
                guard !tab.panes.isEmpty else { continue }
                var tab = tab
                if let focused = tab.focused, !tab.panes.indices.contains(focused) { tab.focused = nil }
                if let zoomed = tab.zoomed, !tab.panes.indices.contains(zoomed) { tab.zoomed = nil }
                if index == wanted { selected = tabs.count }
                // The first kept tab at or after a dropped selection.
                if selected == nil, index > wanted { selected = tabs.count }
                tabs.append(tab)
            }
            guard !tabs.isEmpty else { return nil }
            return Window(frame: window.frame, tabs: tabs, selectedTab: selected ?? tabs.count - 1)
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// nil for unreadable data or a version this build does not know.
    /// Version 1 files are brought up to date.
    public static func decode(_ data: Data) -> Session? {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else { return nil }
        switch probe.version {
        case 1:
            return (try? decoder.decode(Version1.self, from: data))?.upgraded
        case currentVersion:
            return try? decoder.decode(Session.self, from: data)
        default:
            return nil
        }
    }

    private struct VersionProbe: Decodable {
        var version: Int
    }

    /// The format before tabs: each window held one grid of panes.
    private struct Version1: Decodable {
        struct Window: Decodable {
            var frame: CGRect
            var panes: [Pane]
            var focused: Int?
            var zoomed: Int?
            var layout: GridLayout.Mode?
            var weights: LayoutWeights?
            var rows: [Int]?
            var rotated: Bool?
        }

        var windows: [Window]

        /// One tab per window, unnamed and uncolored.
        var upgraded: Session {
            Session(windows: windows.map { window in
                Session.Window(frame: window.frame, tabs: [
                    Tab(panes: window.panes, focused: window.focused, zoomed: window.zoomed, layout: window.layout,
                        weights: window.weights, rows: window.rows, rotated: window.rotated),
                ], selectedTab: 0)
            })
        }
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
