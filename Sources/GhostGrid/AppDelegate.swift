import AppKit
import GhostGridCore
import GhosttyTerminal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One Ghostty app instance per shell, created the first time a pane
    /// picks that shell and shared by every pane running it.
    private var controllers: [String: TerminalController] = [:]
    /// The user's config with includes inlined, read once at launch.
    private lazy var baseConfig: String? = Self.flattenedConfig()
    private var windows: [GridWindowController] = []

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = MainMenu.build()
        newWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    @objc func newWindow(_: Any?) {
        let window = GridWindowController { [unowned self] in controller(for: $0) }
        window.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        windows.append(window)
        window.showWindow(nil)
        window.grid.addPane()
    }

    // MARK: - Pane commands
    //
    // Handled here rather than on the window so the menu works whatever has
    // focus, and even while the app is in the background.

    private var current: GridView? {
        let key = NSApp.keyWindow ?? NSApp.mainWindow
        return (windows.first { $0.window === key } ?? windows.last)?.grid
    }

    @objc func newPane(_: Any?) { current?.addPane() }
    @objc func closePane(_: Any?) { current?.closeFocused() }
    @objc func toggleZoom(_: Any?) { current?.toggleZoom() }
    @objc func nextPane(_: Any?) { current?.focusNext(1) }
    @objc func previousPane(_: Any?) { current?.focusNext(-1) }
    @objc func focusLeft(_: Any?) { current?.focus(.left) }
    @objc func focusRight(_: Any?) { current?.focus(.right) }
    @objc func focusUp(_: Any?) { current?.focus(.up) }
    @objc func focusDown(_: Any?) { current?.focus(.down) }

    /// Loads the user's own Ghostty config (theme, font, shaders, keybinds),
    /// so ghostgrid looks like their Ghostty, plus `command` for `shell`.
    /// The theme is left empty: a non-empty one makes the package re-render
    /// the config into a temp file.
    private func controller(for shell: ShellChoice) -> TerminalController {
        if let existing = controllers[shell.name] { return existing }
        let path = Self.writeConfig(ShellConfig.render(base: baseConfig, choice: shell), name: shell.name)
        let controller = TerminalController(configFilePath: path, theme: TerminalTheme())
        if let issue = controller.lastConfigurationIssue {
            Self.warn("Ghostty config issue (\(shell.name)): \(issue)")
        }
        controllers[shell.name] = controller
        return controller
    }

    /// The user's config with includes inlined (see ConfigFlattener).
    /// GHOSTGRID_CONFIG overrides the entry file.
    private static func flattenedConfig() -> String? {
        guard let source = configPath() else { return nil }
        do {
            return try ConfigFlattener.flatten(URL(fileURLWithPath: source))
        } catch {
            warn("using Ghostty defaults: \(error)")
            return nil
        }
    }

    /// Writes ~/Library/Application Support/ghostgrid/config-<name>.ghostty.
    private static func writeConfig(_ contents: String?, name: String) -> String? {
        guard let contents else { return nil }
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
            ).appendingPathComponent("ghostgrid", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let output = dir.appendingPathComponent("config-\(name).ghostty")
            try contents.write(to: output, atomically: true, encoding: .utf8)
            return output.path
        } catch {
            warn("cannot write config for \(name): \(error)")
            return nil
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("ghostgrid: \(message)\n".utf8))
    }

    private static func configPath() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["GHOSTGRID_CONFIG"] {
            return override
        }
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty")
        for name in ["config.ghostty", "config"] {
            let path = base.appendingPathComponent(name).path
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }
}
