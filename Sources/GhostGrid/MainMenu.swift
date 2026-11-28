import AppKit
import GhostGridCore

/// The menu bar. Its shortcuts are the app's keybindings (Keymap):
/// GridWindow gives them priority over Ghostty's, so they work while a
/// terminal has focus.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu("ghostgrid", [
            item("About ghostgrid", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Check for Updates...", #selector(AppDelegate.checkForUpdates(_:))),
            .separator(),
            item("Settings...", #selector(AppDelegate.showSettings(_:)), .showSettings),
            .separator(),
            item("Open Ghostty Configuration", #selector(AppDelegate.openConfiguration(_:)), .openConfiguration),
            item("Reload Ghostty Configuration", #selector(AppDelegate.reloadConfiguration(_:)), .reloadConfiguration),
            .separator(),
            item("Hide ghostgrid", #selector(NSApplication.hide(_:)), .hide),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), .hideOthers),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit ghostgrid", #selector(NSApplication.terminate(_:)), .quit),
        ]))
        menu.addItem(submenu("Shell", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), .newWindow),
            item("New Tab", #selector(AppDelegate.newTab(_:)), .newTab),
            item("New Tab with Shell...", #selector(AppDelegate.newTabChoosingShell(_:)), .newTabChoosingShell),
            item("New Pane", #selector(AppDelegate.newPane(_:)), .newPane),
            item("New Pane with Shell...", #selector(AppDelegate.newPaneChoosingShell(_:)), .newPaneChoosingShell),
            .separator(),
            item("Close Pane", #selector(AppDelegate.closePane(_:)), .closePane),
            item("Close Tab", #selector(AppDelegate.closeTab(_:)), .closeTab),
            item("Close Window", #selector(NSWindow.performClose(_:)), .closeWindow),
            .separator(),
            item("Broadcast Input to All Panes", #selector(AppDelegate.toggleBroadcast(_:)), .toggleBroadcast),
        ]))
        menu.addItem(submenu("Tab", [
            item("Show Next Tab", #selector(AppDelegate.nextTab(_:)), .nextTab),
            item("Show Previous Tab", #selector(AppDelegate.previousTab(_:)), .previousTab),
            .separator(),
            item("Rename Tab...", #selector(AppDelegate.renameTab(_:))),
            colorMenu(),
            .separator(),
            item("Move Tab to New Window", #selector(AppDelegate.moveTabToOwnWindow(_:))),
            item("Close Other Tabs", #selector(AppDelegate.closeOtherTabs(_:))),
        ] + numbered("Show Tab", #selector(AppDelegate.selectTabNumber(_:)), Keymap.selectTab)))
        menu.addItem(submenu("Pane", [
            item("Zoom Pane", #selector(AppDelegate.toggleZoom(_:)), .toggleZoom),
            item("Command Blocks", #selector(AppDelegate.toggleCommandBlocks(_:)), .toggleCommandBlocks),
            item("Copy Last Command Output", #selector(AppDelegate.copyLastCommandOutput(_:)), .copyLastCommandOutput),
            item("Explain Last Failure", #selector(AppDelegate.explainLastFailure(_:)), .explainLastFailure),
            .separator(),
            item("Next Pane", #selector(AppDelegate.nextPane(_:)), .nextPane),
            item("Previous Pane", #selector(AppDelegate.previousPane(_:)), .previousPane),
            .separator(),
            item("Focus Left", #selector(AppDelegate.focusLeft(_:)), .focusLeft),
            item("Focus Right", #selector(AppDelegate.focusRight(_:)), .focusRight),
            item("Focus Up", #selector(AppDelegate.focusUp(_:)), .focusUp),
            item("Focus Down", #selector(AppDelegate.focusDown(_:)), .focusDown),
            .separator(),
            item("Swap Left", #selector(AppDelegate.swapLeft(_:)), .swapLeft),
            item("Swap Right", #selector(AppDelegate.swapRight(_:)), .swapRight),
            item("Swap Up", #selector(AppDelegate.swapUp(_:)), .swapUp),
            item("Swap Down", #selector(AppDelegate.swapDown(_:)), .swapDown),
            item("Make Main Pane", #selector(AppDelegate.makeMain(_:)), .makeMain),
            item("Equalize Panes", #selector(AppDelegate.equalizePanes(_:)), .equalizePanes),
            item("Attention Grid", #selector(AppDelegate.toggleAttentionGrid(_:)), .toggleAttentionGrid),
            .separator(),
            layoutMenu(),
            item("Next Layout", #selector(AppDelegate.cycleLayout(_:)), .cycleLayout),
            item("Rotate Layout", #selector(AppDelegate.rotateLayout(_:)), .rotateLayout),
        ] + numbered("Focus Pane", #selector(AppDelegate.focusPaneNumber(_:)), Keymap.focusPane)))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), .minimize),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), .toggleFullScreen),
        ])
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for item in items {
            menu.addItem(item)
            // A command's other shortcuts (see `item`), right after it.
            if let alternates = item.representedObject as? [NSMenuItem] {
                item.representedObject = nil
                alternates.forEach(menu.addItem)
            }
        }
        parent.submenu = menu
        return parent
    }

    /// A menu item with the command's first shortcut (Keymap); its other
    /// shortcuts become hidden items that still work, which `submenu` adds
    /// right after it.
    private static func item(_ title: String, _ action: Selector, _ command: MenuCommand? = nil) -> NSMenuItem {
        let bindings = command.map(Keymap.bindings(for:)) ?? []
        let main = make(title, action, bindings.first)
        guard bindings.count > 1 else { return main }
        // Alternates ride along as hidden items after the visible one.
        main.representedObject = bindings.dropFirst().map { make(title, action, $0, hidden: true) }
        return main
    }

    private static func make(_ title: String, _ action: Selector, _ binding: KeyBinding?, hidden: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: binding?.key ?? "")
        if let binding { item.keyEquivalentModifierMask = modifiers(binding.modifiers) }
        if hidden {
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        return item
    }

    static func modifiers(_ modifiers: KeyBinding.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    /// Pane > Layout: one item per mode, the current one checked.
    private static func layoutMenu() -> NSMenuItem {
        submenu("Layout", GridLayout.Mode.allCases.enumerated().map { index, mode in
            let entry = item(mode.title, #selector(AppDelegate.setLayout(_:)))
            entry.tag = index
            return entry
        })
    }

    /// Tab > Tab Color: None, then the presets with a swatch; the current
    /// tab's color is checked (tag: index in TabColor.allCases, -1: none).
    private static func colorMenu() -> NSMenuItem {
        let none = item("None", #selector(AppDelegate.setTabColor(_:)))
        none.tag = -1
        return submenu("Tab Color", [none, .separator()] + TabColor.allCases.enumerated().map { index, color in
            let entry = item(color.title, #selector(AppDelegate.setTabColor(_:)))
            entry.tag = index
            entry.image = TabColorSwatch.image(for: color)
            return entry
        })
    }

    /// "<title> 1" ... "<title> 9" with their shortcuts (tag: the number);
    /// 9 is the last.
    private static func numbered(_ title: String, _ action: Selector, _ binding: (Int) -> KeyBinding) -> [NSMenuItem] {
        [.separator()] + (1...9).map { number in
            let entry = make(number == 9 && title == "Show Tab" ? "Show Last Tab" : "\(title) \(number)", action, binding(number))
            entry.tag = number
            return entry
        }
    }
}

/// A small round swatch of a tab color, for menus.
@MainActor
enum TabColorSwatch {
    static func image(for color: TabColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(tab: color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

extension NSColor {
    convenience init(tab color: TabColor) {
        let rgb = color.rgb
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
