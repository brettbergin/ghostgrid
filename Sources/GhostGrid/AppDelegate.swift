import AppKit
import GhostGridCore
import GhosttyTerminal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// One Ghostty app instance per shell, created the first time a pane
    /// picks that shell and shared by every pane running it.
    private var controllers: [String: TerminalController] = [:]
    private var controllerShells: [String: ShellChoice] = [:]
    /// The user's config with includes inlined; read at launch and again
    /// on Reload Configuration.
    private lazy var baseConfig: String? = Self.flattenedConfig()
    private var windows: [GridWindowController] = []
    /// Folders opened before launch finished (gg, Dock drops), opened as
    /// panes once the windows exist.
    private var pendingFolders: [String] = []
    private var launched = false

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = MainMenu.build()
        GhosttyOptions.shared.update(from: baseConfig)
        launched = true
        let folders = pendingFolders
        pendingFolders = []
        if !restoreSession() {
            // A folder opened at launch becomes the first pane.
            let window = makeWindow()
            window.showWindow(nil)
            window.grid.addPane(directory: folders.first)
            for folder in folders.dropFirst() { window.grid.addPane(directory: folder) }
        } else {
            for folder in folders { current?.addPane(directory: folder) }
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// `gg <dir>` (open -a ghostgrid <dir>) and folders dropped on the Dock
    /// icon: a new pane in that folder, in the front window (a new window
    /// when there is none). A file opens a pane in its folder.
    func application(_: NSApplication, open urls: [URL]) {
        let folders = urls.filter(\.isFileURL).map { url -> String in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
        }
        guard launched else {
            pendingFolders += folders
            return
        }
        NSApp.activate()
        for folder in folders {
            if let grid = current {
                grid.addPane(directory: folder)
                grid.window?.makeKeyAndOrderFront(nil)
            } else {
                let window = makeWindow()
                window.showWindow(nil)
                window.grid.addPane(directory: folder)
            }
        }
    }

    /// Quitting, as opposed to closing windows one by one.
    private var terminating = false

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        terminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_: Notification) {
        terminating = true
        saveSession()
        if !GhostGridSettings.shared.keepShellsRunning {
            windows.forEach { $0.grid.endAllShells() }
        }
    }

    @objc func newWindow(_: Any?) {
        let window = makeWindow()
        window.showWindow(nil)
        window.grid.addPane()
    }

    private func makeWindow() -> GridWindowController {
        let window = GridWindowController { [unowned self] in controller(for: $0) }
        window.onClose = { [weak self] closed in
            // Closing a window ends its shells; quitting may keep them.
            if self?.terminating == false { closed.grid.endAllShells() }
            self?.windows.removeAll { $0 === closed }
            self?.scheduleSave()
        }
        window.onChange = { [weak self] in self?.scheduleSave() }
        window.grid.onChange = { [weak self] in self?.scheduleSave() }
        windows.append(window)
        return window
    }

    // MARK: - Session restore (Ghostty's window-save-state)

    private var saveScheduled = false

    /// Rebuilds the last session's windows when window-save-state allows
    /// it. False when there was nothing to restore.
    private func restoreSession() -> Bool {
        guard let session = SessionStore.load() else { return false }
        let policy = SessionPolicy.shouldRestore(
            windowSaveState: GhosttyOptions.shared.values.string("window-save-state"),
            systemKeepsWindows: UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows"),
            keepsShells: !session.liveSessionIDs.isEmpty,
        )
        guard policy else {
            // Kept shells nobody will come back to.
            SessionClient.terminate(session.liveSessionIDs)
            return false
        }
        guard !session.restorable.isEmpty else { return false }
        let screens = NSScreen.screens.map(\.visibleFrame)
        for saved in session.restorable {
            let window = makeWindow()
            if let frame = SessionPolicy.fit(saved.frame, screens: screens) {
                window.window?.setFrame(frame, display: false)
            }
            window.showWindow(nil)
            window.grid.restore(saved)
        }
        return true
    }

    /// Saves soon, coalescing bursts (typing cd, dragging a window).
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.saveScheduled = false
            self?.saveSession()
        }
    }

    private func saveSession() {
        let saved: [Session.Window] = windows.compactMap { controller in
            guard let window = controller.window else { return nil }
            let grid = controller.grid.snapshot()
            return Session.Window(
                frame: window.frame, panes: grid.panes, focused: grid.focused, zoomed: grid.zoomed, layout: grid.layout,
                weights: grid.weights, rows: grid.rows, rotated: grid.rotated ? true : nil,
            )
        }
        SessionStore.save(Session(windows: saved))
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
    @objc func newPaneChoosingShell(_: Any?) { current?.addPane(chooseShell: true) }
    @objc func closePane(_: Any?) { current?.closeFocused() }
    @objc func toggleZoom(_: Any?) { current?.toggleZoom() }
    /// Cmd+Shift+B: the focused pane's commands, foldable, to copy, rerun or share.
    @objc func toggleCommandBlocks(_: Any?) { current?.focused?.toggleBlocks() }
    /// Pane > Attention Grid: panes that need you grow (Settings > Grid).
    @objc func toggleAttentionGrid(_: Any?) { GhostGridSettings.shared.attentionGrid.toggle() }

    /// Cmd+Shift+E: why the last failed command failed, from the local model.
    @objc func explainLastFailure(_: Any?) {
        if current?.focused?.explainLastFailure() != true { NSSound.beep() }
    }
    /// Cmd+Opt+Shift+C: the last finished command's output to the clipboard.
    @objc func copyLastCommandOutput(_: Any?) {
        if current?.focused?.copyLastOutput() != true { NSSound.beep() }
    }
    /// Cmd+Opt+I: type into every pane of the window at once.
    @objc func toggleBroadcast(_: Any?) { current?.broadcasting.toggle() }
    @objc func nextPane(_: Any?) { current?.focusNext(1) }
    @objc func previousPane(_: Any?) { current?.focusNext(-1) }
    @objc func focusLeft(_: Any?) { current?.focus(.left) }
    @objc func focusRight(_: Any?) { current?.focus(.right) }
    @objc func focusUp(_: Any?) { current?.focus(.up) }
    @objc func focusDown(_: Any?) { current?.focus(.down) }
    @objc func swapLeft(_: Any?) { current?.swapFocused(.left) }
    @objc func swapRight(_: Any?) { current?.swapFocused(.right) }
    @objc func swapUp(_: Any?) { current?.swapFocused(.up) }
    @objc func swapDown(_: Any?) { current?.swapFocused(.down) }
    @objc func makeMain(_: Any?) { current?.makeFocusedMain() }
    @objc func equalizePanes(_: Any?) { current?.equalize() }

    /// Pane > Layout > Grid / Main + Stack / Columns (tag: index in Mode.allCases).
    @objc func setLayout(_ sender: NSMenuItem) {
        current?.setMode(GridLayout.Mode.allCases[sender.tag])
    }

    @objc func rotateLayout(_: Any?) { current?.toggleRotation() }

    @objc func cycleLayout(_: Any?) {
        guard let grid = current else { return }
        grid.setMode(grid.mode.next)
    }

    /// Checks the current window's layout in the Layout menu.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setLayout(_:)) {
            item.state = current?.mode == GridLayout.Mode.allCases[item.tag] ? .on : .off
        }
        if item.action == #selector(toggleAttentionGrid(_:)) {
            item.state = GhostGridSettings.shared.attentionGrid ? .on : .off
        }
        if item.action == #selector(rotateLayout(_:)) {
            item.state = current?.rotated == true ? .on : .off
        }
        if item.action == #selector(toggleBroadcast(_:)) {
            item.state = current?.broadcasting == true ? .on : .off
        }
        return true
    }

    /// Cmd+1...9: the pane at that position (menu item tag, 0-based).
    @objc func focusPaneNumber(_ sender: NSMenuItem) { current?.focusPane(at: sender.tag) }

    // MARK: - Configuration

    /// Cmd+Shift+,: re-read the user's Ghostty config (includes inlined
    /// again) into every running shell's Ghostty instance. Ghostty's own
    /// reload would re-read ghostgrid's generated copy, not the user's files.
    @objc func reloadConfiguration(_: Any?) {
        baseConfig = Self.flattenedConfig()
        GhosttyOptions.shared.update(from: baseConfig)
        for (name, controller) in controllers {
            guard let shell = controllerShells[name],
                  let path = Self.writeConfig(ShellConfig.render(base: baseConfig, choice: shell), name: name)
            else { continue }
            if !controller.updateConfigSource(.file(path)), let issue = controller.lastConfigurationIssue {
                Self.warn("Ghostty config issue (\(name)): \(issue)")
            }
        }
    }

    /// ghostgrid > Settings... (Cmd+,).
    @objc func showSettings(_: Any?) {
        SettingsWindowController.shared.present()
    }

    /// Cmd+Option+,: open the user's Ghostty config, in VS Code when installed.
    @objc func openConfiguration(_: Any?) {
        guard let path = Self.configPath() else { return }
        let url = URL(fileURLWithPath: path)
        let editor = ["com.microsoft.VSCode", "com.apple.TextEdit"]
            .lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
        if let editor {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

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
        controllerShells[shell.name] = shell
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

    fileprivate static func warn(_ message: String) {
        FileHandle.standardError.write(Data("ghostgrid: \(message)\n".utf8))
    }

    private static func configPath() -> String? {
        GhosttyConfigLocation.path
    }
}

/// ~/Library/Application Support/ghostgrid/session.json
@MainActor
enum SessionStore {
    static var url: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true,
        ).appendingPathComponent("ghostgrid/session.json")
    }

    static func load() -> Session? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return Session.decode(data)
    }

    static func save(_ session: Session) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try session.encoded().write(to: url, options: .atomic)
        } catch {
            AppDelegate.warn("cannot save session: \(error)")
        }
    }
}
