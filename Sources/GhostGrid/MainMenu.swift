import AppKit

/// The menu bar. Its shortcuts are the app's keybindings: GridWindow gives
/// them priority over Ghostty's, so they work while a terminal has focus.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu("ghostgrid", [
            item("About ghostgrid", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Open Configuration", #selector(AppDelegate.openConfiguration(_:)), ","),
            item("Reload Configuration", #selector(AppDelegate.reloadConfiguration(_:)), ",", [.command, .shift]),
            .separator(),
            item("Hide ghostgrid", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit ghostgrid", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        menu.addItem(submenu("Shell", [
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n"),
            item("New Pane", #selector(AppDelegate.newPane(_:)), "t"),
            item("New Pane", #selector(AppDelegate.newPane(_:)), "d", alternate: true),
            item("New Pane with Shell...", #selector(AppDelegate.newPaneChoosingShell(_:)), "t", [.command, .shift]),
            .separator(),
            item("Close Pane", #selector(AppDelegate.closePane(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ]))
        menu.addItem(submenu("Pane", [
            item("Zoom Pane", #selector(AppDelegate.toggleZoom(_:)), "\r", [.command, .shift]),
            .separator(),
            item("Next Pane", #selector(AppDelegate.nextPane(_:)), "]"),
            item("Previous Pane", #selector(AppDelegate.previousPane(_:)), "["),
            .separator(),
            item("Focus Left", #selector(AppDelegate.focusLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]),
            item("Focus Right", #selector(AppDelegate.focusRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]),
            item("Focus Up", #selector(AppDelegate.focusUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
            item("Focus Down", #selector(AppDelegate.focusDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
        ] + paneNumberItems()))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            // Ghostty's own shortcut for full screen.
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "\r", alternate: true),
        ])
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        alternate: Bool = false,
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        // A hidden second shortcut for the same command.
        if alternate { item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true }
        return item
    }

    /// Cmd+1...9 focus the pane at that position (Ghostty's goto_tab keys).
    private static func paneNumberItems() -> [NSMenuItem] {
        [.separator()] + (1...9).map { number in
            let entry = item("Focus Pane \(number)", #selector(AppDelegate.focusPaneNumber(_:)), "\(number)")
            entry.tag = number - 1
            return entry
        }
    }

    private static func arrow(_ key: Int) -> String {
        String(Character(UnicodeScalar(UInt16(key))!))
    }
}
