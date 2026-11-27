import Foundation

/// A window's tabs in order, and which one is selected. Each tab holds its
/// own grid of panes; the window shows only the selected one.
///
/// A new tab opens right after the selected one and is selected. Closing the
/// selected tab selects the one to its right (the new last one when it was
/// last); closing or moving any other tab keeps the same tab selected.
/// Requests for tabs that do not exist are ignored.
public struct TabStrip<Tab> {
    public private(set) var tabs: [Tab]
    /// Index of the selected tab; 0 when there are none.
    public private(set) var selected: Int

    /// `selected` is clamped to the tabs given.
    public init(_ tabs: [Tab], selected: Int = 0) {
        self.tabs = tabs
        self.selected = min(max(selected, 0), max(tabs.count - 1, 0))
    }

    public var isEmpty: Bool { tabs.isEmpty }
    public var count: Int { tabs.count }

    public var selectedTab: Tab? {
        tabs.indices.contains(selected) ? tabs[selected] : nil
    }

    /// Opens `tab` right after the selected one and selects it.
    public mutating func add(_ tab: Tab) {
        let index = tabs.isEmpty ? 0 : selected + 1
        tabs.insert(tab, at: index)
        selected = index
    }

    /// Removes the tab at `index` and returns it (nil when there is none).
    @discardableResult public mutating func close(at index: Int) -> Tab? {
        guard tabs.indices.contains(index) else { return nil }
        let removed = tabs.remove(at: index)
        if index < selected {
            selected -= 1
        } else if index == selected {
            // The tab to the right slid into this place; past the end, the
            // new last tab.
            selected = min(selected, max(tabs.count - 1, 0))
        }
        return removed
    }

    /// Moves the tab at `from` so it ends up at `to`; the selected tab stays
    /// selected wherever it lands.
    public mutating func move(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        if selected == from {
            selected = to
        } else if from < selected, to >= selected {
            selected -= 1
        } else if from > selected, to <= selected {
            selected += 1
        }
    }

    public mutating func select(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selected = index
    }

    /// Cmd+1...8 select that tab (when there is one); Cmd+9 the last tab.
    public mutating func select(number: Int) {
        guard !tabs.isEmpty else { return }
        select(at: number == 9 ? tabs.count - 1 : number - 1)
    }

    /// Next (1) or previous (-1) tab, wrapping around.
    public mutating func selectNext(_ step: Int) {
        guard !tabs.isEmpty else { return }
        selected = ((selected + step) % tabs.count + tabs.count) % tabs.count
    }
}

extension TabStrip: Equatable where Tab: Equatable {}
extension TabStrip: Sendable where Tab: Sendable {}

/// What a tab is called: the name you gave it, or "Tab N" by its position,
/// so it matches its Cmd+N shortcut.
public enum TabTitle {
    public static func display(name: String?, position: Int) -> String {
        name.flatMap(normalized) ?? "Tab \(position + 1)"
    }

    /// A name as typed when renaming: trimmed; blank means no name (back to
    /// "Tab N").
    public static func normalized(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The colors a tab can be given (Catppuccin Mocha, like the rest of
/// ghostgrid), in menu order. No color is nil.
public enum TabColor: String, CaseIterable, Codable, Sendable {
    case red, peach, yellow, green, teal, blue, mauve, pink

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// 0xRRGGBB.
    public var rgb: UInt32 {
        switch self {
        case .red: 0xF38BA8
        case .peach: 0xFAB387
        case .yellow: 0xF9E2AF
        case .green: 0xA6E3A1
        case .teal: 0x94E2D5
        case .blue: 0x89B4FA
        case .mauve: 0xCBA6F7
        case .pink: 0xF5C2E7
        }
    }
}

/// The badge a tab shows while you are looking at another tab: the most
/// important of its panes' badges.
public enum TabActivity {
    /// A failed command first, then a bell, then a finished command; the
    /// first pane's among equals. nil when no pane has a badge.
    public static func badge(for panes: [PaneActivity?]) -> PaneActivity? {
        let badges = panes.compactMap(\.self)
        return badges.first(where: \.failed)
            ?? badges.first { $0 == .bell }
            ?? badges.first
    }
}

/// Where tabs sit in the tab bar: they share its width evenly, in whole
/// points, between a minimum and a maximum; when they would be narrower than
/// the minimum they stay at it and the bar scrolls.
public struct TabBarLayout: Sendable {
    public struct Slot: Equatable, Sendable {
        public var minX: CGFloat
        public var width: CGFloat
        public var midX: CGFloat { minX + width / 2 }
    }

    public var minimumWidth: CGFloat
    public var maximumWidth: CGFloat
    public var spacing: CGFloat

    public init(minimumWidth: CGFloat, maximumWidth: CGFloat, spacing: CGFloat) {
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.spacing = spacing
    }

    /// Each tab's width for `count` tabs in a bar `width` wide.
    public func tabWidth(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let share = ((width - spacing * CGFloat(count - 1)) / CGFloat(count)).rounded(.down)
        return min(max(share, minimumWidth), maximumWidth)
    }

    public func frames(count: Int, width: CGFloat) -> [Slot] {
        let tab = tabWidth(count: count, width: width)
        return (0..<max(count, 0)).map { Slot(minX: CGFloat($0) * (tab + spacing), width: tab) }
    }

    /// How wide the tabs are together; more than `width` means the bar scrolls.
    public func contentWidth(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * tabWidth(count: count, width: width) + spacing * CGFloat(count - 1)
    }

    /// The slot a tab dragged along the bar lands in: the one whose middle
    /// is nearest the dragged tab's middle.
    public func dropIndex(forMiddle middle: CGFloat, count: Int, width: CGFloat) -> Int {
        let slots = frames(count: count, width: width)
        guard !slots.isEmpty else { return 0 }
        return slots.indices.min { abs(slots[$0].midX - middle) < abs(slots[$1].midX - middle) } ?? 0
    }

    /// The bar shows with two or more tabs, or with a single tab you named
    /// or colored (so the name or color is visible).
    public static func shows(count: Int, onlyTabCustomized: Bool) -> Bool {
        count > 1 || (count == 1 && onlyTabCustomized)
    }
}

extension TabActivity {
    /// A tab's badge counting only what happened since you last looked at
    /// it (`since`; nil: never, so everything counts).
    public static func badge(for panes: [(activity: PaneActivity?, at: Date?)], since: Date?) -> PaneActivity? {
        badge(for: panes.map { pane in
            guard let since else { return pane.activity }
            return (pane.at.map { $0 >= since } ?? false) ? pane.activity : nil
        })
    }
}

/// Where the tab bar sits. In a window: in the titlebar beside the
/// traffic lights, with the panes where they always were. In full screen
/// there is no titlebar to sit in (the window may still report its height),
/// so the bar goes above the panes, which move down for it only while it
/// shows.
public struct TabBarPlacement: Equatable, Sendable {
    public var barHeight: CGFloat
    /// How far below the top of the safe area the panes start.
    public var gridTop: CGFloat
    /// The bar's left edge, from the window's.
    public var leading: CGFloat

    public static let fullScreenHeight: CGFloat = 30

    public init(barHeight: CGFloat, gridTop: CGFloat, leading: CGFloat) {
        self.barHeight = barHeight
        self.gridTop = gridTop
        self.leading = leading
    }

    public static func place(fullScreen: Bool, titlebarHeight: CGFloat, buttonsMaxX: CGFloat, visible: Bool) -> TabBarPlacement {
        if !fullScreen, titlebarHeight > 0 {
            return TabBarPlacement(barHeight: titlebarHeight, gridTop: 0, leading: buttonsMaxX + 12)
        }
        return TabBarPlacement(barHeight: fullScreenHeight, gridTop: visible ? fullScreenHeight : 0, leading: 8)
    }
}
