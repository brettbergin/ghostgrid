/// A menu shortcut: the key equivalent (as NSMenuItem takes it) and its
/// modifiers. Shifted symbols are written as the symbol ("}" is
/// Cmd+Shift+]), as AppKit matches them.
public struct KeyBinding: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }

    public var description: String {
        let names: [(Modifiers, String)] = [(.control, "Ctrl+"), (.option, "Opt+"), (.shift, "Shift+"), (.command, "Cmd+")]
        let prefix = names.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let special: [String: String] = ["\r": "Return", "\t": "Tab", Keymap.left: "Left", Keymap.right: "Right",
                                         Keymap.up: "Up", Keymap.down: "Down"]
        return prefix + (special[key] ?? key)
    }
}

/// The menu commands that have shortcuts.
public enum MenuCommand: String, CaseIterable, Sendable {
    case newWindow, newTab, newTabChoosingShell, newPane, newPaneChoosingShell
    case closePane, closeTab, closeWindow, toggleBroadcast
    case nextTab, previousTab
    case toggleZoom, toggleCommandBlocks, copyLastCommandOutput, explainLastFailure
    case nextPane, previousPane, focusLeft, focusRight, focusUp, focusDown
    case swapLeft, swapRight, swapUp, swapDown, makeMain, equalizePanes, toggleAttentionGrid
    case cycleLayout, rotateLayout
    case showSettings, openConfiguration, reloadConfiguration, hide, hideOthers, quit
    case minimize, toggleFullScreen
}

/// ghostgrid's keyboard: the menu bar's shortcuts, which win over Ghostty's
/// keybindings while a terminal has focus. Tabs follow terminal convention
/// (Ghostty, iTerm2, Safari); panes keep their keys, except new pane (Cmd+D)
/// and Focus Pane N (Cmd+Option+1-9).
public enum Keymap {
    // NSUpArrowFunctionKey ... as NSMenuItem key equivalents.
    static let up = String(UnicodeScalar(0xF700)!)
    static let down = String(UnicodeScalar(0xF701)!)
    static let left = String(UnicodeScalar(0xF702)!)
    static let right = String(UnicodeScalar(0xF703)!)

    /// A command's shortcuts: the first is shown in the menu, the rest work
    /// too (hidden alternates).
    public static func bindings(for command: MenuCommand) -> [KeyBinding] {
        typealias K = KeyBinding
        return switch command {
        case .newWindow: [K("n")]
        case .newTab: [K("t")]
        case .newTabChoosingShell: [K("t", [.command, .shift])]
        case .newPane: [K("d")]
        case .newPaneChoosingShell: [K("d", [.command, .shift])]
        case .closePane: [K("w")]
        case .closeTab: [K("w", [.command, .option])]
        case .closeWindow: [K("w", [.command, .shift])]
        case .toggleBroadcast: [K("i", [.command, .option])]
        case .nextTab: [K("}"), K("\t", .control)]
        case .previousTab: [K("{"), K("\t", [.control, .shift])]
        case .toggleZoom: [K("\r", [.command, .shift])]
        case .toggleCommandBlocks: [K("b", [.command, .shift])]
        case .copyLastCommandOutput: [K("c", [.command, .option, .shift])]
        case .explainLastFailure: [K("e", [.command, .shift])]
        case .nextPane: [K("]")]
        case .previousPane: [K("[")]
        case .focusLeft: [K(left, [.command, .option])]
        case .focusRight: [K(right, [.command, .option])]
        case .focusUp: [K(up, [.command, .option])]
        case .focusDown: [K(down, [.command, .option])]
        case .swapLeft: [K(left, [.command, .shift])]
        case .swapRight: [K(right, [.command, .shift])]
        case .swapUp: [K(up, [.command, .shift])]
        case .swapDown: [K(down, [.command, .shift])]
        case .makeMain: [K("m", [.command, .shift])]
        case .equalizePanes: [K("=", [.command, .control])]
        case .toggleAttentionGrid: [K("a", [.command, .control])]
        case .cycleLayout: [K("l", [.command, .shift])]
        case .rotateLayout: [K("r", [.command, .control])]
        case .showSettings: [K(",")]
        case .openConfiguration: [K(",", [.command, .option])]
        case .reloadConfiguration: [K(",", [.command, .shift])]
        case .hide: [K("h")]
        case .hideOthers: [K("h", [.command, .option])]
        case .quit: [K("q")]
        case .minimize: [K("m")]
        // Ghostty's own full-screen shortcut is the alternate.
        case .toggleFullScreen: [K("f", [.command, .control]), K("\r")]
        }
    }

    /// Cmd+1...9: that tab (Cmd+9: the last one).
    public static func selectTab(_ number: Int) -> KeyBinding { KeyBinding("\(number)") }

    /// Cmd+Option+1...9: the pane at that position in the current tab.
    public static func focusPane(_ number: Int) -> KeyBinding { KeyBinding("\(number)", [.command, .option]) }

    /// Every shortcut with the command it belongs to.
    public static var everyBinding: [(name: String, binding: KeyBinding)] {
        MenuCommand.allCases.flatMap { command in bindings(for: command).map { (command.rawValue, $0) } }
            + (1...9).map { ("selectTab\($0)", selectTab($0)) }
            + (1...9).map { ("focusPane\($0)", focusPane($0)) }
    }
}
