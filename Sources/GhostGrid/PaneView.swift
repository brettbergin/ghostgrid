import AppKit
import SwiftUI
import GhostGridCore
import GhosttyTerminal

/// The Ghostty app instance whose config runs a given shell.
typealias ControllerProvider = @MainActor (ShellChoice) -> TerminalController

/// A Ghostty terminal view that reports when it takes keyboard focus, and
/// hides the pointer while typing (`mouse-hide-while-typing`, which Ghostty
/// leaves to the host app).
@MainActor
final class PaneTerminalView: AppTerminalView {
    var onFocus: (() -> Void)?
    /// Typing in this terminal, for broadcast to the window's other panes.
    var onInput: ((MirroredInput) -> Void)?

    /// One piece of typing, replayed as is in another pane so that pane
    /// encodes it for its own program (cursor-key modes, kitty keyboard).
    enum MirroredInput {
        case keyDown(NSEvent), keyUp(NSEvent), modifiers(NSEvent), paste(String)
    }

    /// The pane a key is being replayed into, while it is. AppKit's text
    /// input answers a key with `insertText` (and marked text, commands) on
    /// the focused view, whichever view interpreted the key, so without
    /// this the broadcasting pane typed every replayed key a second time
    /// and the other panes got only the bare key.
    private static weak var replaying: PaneTerminalView?

    /// Plays typing from the broadcasting pane into this one.
    func replay(_ input: MirroredInput) {
        switch input {
        case let .keyDown(event):
            Self.replaying = self
            defer { Self.replaying = nil }
            super.keyDown(with: event)
        case let .keyUp(event): super.keyUp(with: event)
        case let .modifiers(event): super.flagsChanged(with: event)
        case let .paste(text): paste(text: text)
        }
    }

    /// The pane text input should reach: the one a key is being replayed
    /// into, if that is another pane.
    private var textInputTarget: PaneTerminalView? {
        guard let target = Self.replaying, target !== self else { return nil }
        return target
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let target = textInputTarget { return target.insertText(string, replacementRange: replacementRange) }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let target = textInputTarget {
            return target.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        if let target = textInputTarget { return target.unmarkText() }
        super.unmarkText()
    }

    override func hasMarkedText() -> Bool {
        textInputTarget?.hasMarkedText() ?? super.hasMarkedText()
    }

    override func markedRange() -> NSRange {
        textInputTarget?.markedRange() ?? super.markedRange()
    }

    override func selectedRange() -> NSRange {
        textInputTarget?.selectedRange() ?? super.selectedRange()
    }

    override func doCommand(by selector: Selector) {
        if let target = textInputTarget { return target.doCommand(by: selector) }
        super.doCommand(by: selector)
    }

    private func mirrors(_ event: NSEvent) -> Bool {
        Broadcast.mirrors(command: event.modifierFlags.contains(.command))
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        if mirrors(event) { onInput?(.keyUp(event)) }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        onInput?(.modifiers(event))
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        if let text = NSPasteboard.general.string(forType: .string) { onInput?(.paste(text)) }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        if mirrors(event) { onInput?(.keyDown(event)) }
        if GhosttyOptions.shared.mouseHideWhileTyping {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// A view that draws but never takes clicks (overlays).
@MainActor
final class PassthroughView: NSView {
    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// One grid cell: a rounded container that first shows a menu, then
/// a live Ghostty surface running the chosen shell, with a border that
/// lights up while the pane has focus.
@MainActor
final class PaneView: NSView {
    /// The running terminal, once a shell has been picked.
    private(set) var terminal: PaneTerminalView?
    private var choiceMenu: ChoiceMenuView?
    private let controllerFor: ControllerProvider
    private(set) var title = "New pane"
    private(set) var workingDirectory: String?
    /// The shell this pane runs, once picked.
    private(set) var shell: ShellChoice?
    /// A command to type at the shell's first prompt (an app from the menu).
    private var pendingCommand: String?
    /// The shell's id in ghostgrid-sessiond, while it runs there.
    private(set) var sessionID: String?
    /// The connection to sessiond carrying this pane's shell.
    private var client: SessionClient?
    private var startedAt = Date()
    /// Commands run in this pane, read from its output (commands as blocks).
    let blocks = CommandBlockStore()
    private var blocksPanel: NSHostingView<CommandBlocksView>?
    /// When the shell last printed anything (attention grid).
    private(set) var lastOutputAt: Date?
    /// Something here wants you (a bell, a notification, a command that
    /// finished while you looked away), until you focus the pane. Kept
    /// whether or not badges show it.
    private(set) var needsYou = false {
        didSet { if needsYou != oldValue { onAttentionChange?(self) } }
    }
    /// needsYou changed: the grid re-weighs at once instead of on its tick.
    var onAttentionChange: ((PaneView) -> Void)?

    /// When the pane last changed size. A shell redraws its prompt after a
    /// resize; that is not news, and counting it would let the attention
    /// grid's own moves keep the pane "active".
    private var resizedAt = Date.distantPast

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { resizedAt = Date() }
        super.setFrameSize(newSize)
    }

    private func outputArrived() {
        let now = Date()
        if now.timeIntervalSince(resizedAt) > 1 { lastOutputAt = now }
    }

    /// How much this pane wants room right now (attention grid).
    func attentionLevel(now: Date) -> AttentionLevel {
        AttentionGrid.level(lastOutput: lastOutputAt, waiting: needsYou, focused: isFocusedPane, now: now)
    }

    private var explainPanel: ExplainPanelView?
    private var explainTask: Task<Void, Never>?
    /// Dims the pane while it is not focused (`unfocused-split-opacity`).
    private let dimView = PassthroughView()
    /// Shown while a search runs (Cmd+F, Ghostty's start_search).
    private var searchBar: SearchBarView?
    /// Shell, folder and branch on top (Settings > Panes > headers).
    private var header: PaneHeaderView?
    /// The activity badge when headers are off: a pill in the corner.
    private var cornerBadge: ActivityBadgeView?
    private var branch: String?
    /// Something that happened while you were not looking at this pane.
    private var activity: PaneActivity? {
        didSet { (header?.badge ?? cornerBadge)?.activity = activity }
    }
    private var settings: GhostGridSettings { .shared }

    var onFocus: ((PaneView) -> Void)?
    var onTitleChange: ((PaneView) -> Void)?
    var onExit: ((PaneView) -> Void)?
    /// The header is being dragged (to swap panes), in window coordinates.
    var onHeaderDrag: ((PaneView, PaneHeaderView.DragPhase, NSPoint) -> Void)?

    /// Lit while a dragged pane hovers over this one.
    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            restyleBorder()
        }
    }

    /// Broadcast typing is on in this pane's window: a red border and
    /// header, so it is obvious that keys go everywhere.
    var isBroadcasting = false {
        didSet {
            guard isBroadcasting != oldValue else { return }
            restyleBorder()
            header?.isBroadcasting = isBroadcasting
        }
    }

    /// Typing in this pane while broadcast may be on (GridView decides).
    var onInput: ((PaneView, PaneTerminalView.MirroredInput) -> Void)?

    /// Replays typing from the broadcasting pane.
    func replay(_ input: PaneTerminalView.MirroredInput) {
        terminal?.replay(input)
    }

    private func restyleBorder() {
        let color = isDropTarget ? Palette.flash : isBroadcasting ? Palette.failure
            : isFocusedPane ? Palette.focus : Palette.idle
        animateBorder(to: color, width: isDropTarget ? 4 : (isFocusedPane || isBroadcasting) ? 2 : 1)
    }

    /// The shell reported a new working directory (saved in the session).
    var onWorkingDirectoryChange: ((PaneView) -> Void)?
    /// Called when the user picks a shell in this pane's menu.
    var onShellPicked: ((ShellChoice) -> Void)?
    /// The pane's shell in sessiond changed (started, replaced, ended).
    var onSessionChange: ((PaneView) -> Void)?

    var isFocusedPane = false {
        didSet {
            guard isFocusedPane != oldValue else { return }
            restyleBorder()
            updateDim(animated: true)
            header?.isFocused = isFocusedPane
            if isFocusedPane {
                activity = nil
                needsYou = false
            }
        }
    }

    /// Whatever currently fills the pane: a menu, then the terminal.
    private var content: NSView? { terminal ?? choiceMenu }

    /// Starts `shell` at once when given; otherwise shows the shell menu
    /// with `preferred` highlighted. With `offerApps`, picking zsh shows a
    /// second menu of command-line apps to launch in it (Escape: plain zsh).
    init(
        controllerFor: @escaping ControllerProvider,
        workingDirectory: String?,
        shells: [ShellChoice],
        shell: ShellChoice? = nil,
        preferred: ShellChoice? = nil,
        offerApps: Bool = false,
        sessionID: String? = nil,
    ) {
        self.controllerFor = controllerFor
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Palette.idle.cgColor

        dimView.wantsLayer = true
        dimView.alphaValue = 0
        addSubview(dimView)
        updateDim(animated: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(optionsChanged), name: GhosttyOptions.didChange, object: nil,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: GhostGridSettings.didChange, object: nil,
        )
        applyChromeSettings()
        blocks.onStart = { [weak self] _ in self?.hideExplain() }
        blocks.onFinish = { [weak self] block in
            guard let self, settings.explainFailures, isFocusedPane else { return }
            if ExplainPolicy.offers(exitCode: block.exitCode, command: block.command) { showExplain(for: block, focus: false) }
        }

        if let shell {
            start(shell)
        } else {
            showShellMenu(shells, preferred: preferred, offerApps: offerApps)
        }
    }

    // MARK: - Menus

    private func showShellMenu(_ shells: [ShellChoice], preferred: ShellChoice?, offerApps: Bool) {
        let menu = ChoiceMenuView(
            title: "New pane: pick a shell",
            hint: "1-\(shells.count) to choose   up/down + return   esc to cancel",
            items: shells.map(MenuItem.init),
            selected: preferred.flatMap { shells.firstIndex(of: $0) },
        )
        menu.onPick = { [weak self] index in
            guard let self else { return }
            let shell = shells[index]
            onShellPicked?(shell)
            if offerApps, shell.name == "zsh" {
                showAppMenu(for: shell)
            } else {
                start(shell)
            }
        }
        menu.onEscape = { [weak self] in
            guard let self else { return }
            onExit?(self)
        }
        show(menu)
    }

    private func showAppMenu(for shell: ShellChoice) {
        let apps = LaunchCatalog.resolve(settings.launcherEntries, home: NSHomeDirectory()) {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        // An emptied launcher list (Settings) means a plain zsh.
        guard !apps.isEmpty else {
            start(shell)
            return
        }
        let menu = ChoiceMenuView(
            title: "\(shell.name): launch an app",
            hint: "1-\(apps.count) to launch   esc for a plain \(shell.name)",
            items: apps.map(MenuItem.init),
        )
        menu.onPick = { [weak self] index in
            self?.start(shell, then: apps[index].command)
        }
        menu.onEscape = { [weak self] in
            self?.start(shell)
        }
        show(menu)
    }

    private func show(_ menu: ChoiceMenuView) {
        menu.onFocus = { [weak self] in
            guard let self else { return }
            onFocus?(self)
        }
        choiceMenu?.removeFromSuperview()
        choiceMenu = menu
        menu.frame = bounds
        addSubview(menu, positioned: .below, relativeTo: dimView)
        window?.makeFirstResponder(menu)
    }

    // MARK: - Terminal

    /// Replaces the menu with a terminal running `shell`, and types
    /// `command` at its first prompt when given.
    private func start(_ shell: ShellChoice, then command: String? = nil) {
        guard terminal == nil, shell.isInstalled else { return }
        self.shell = shell
        pendingCommand = command
        let terminal = PaneTerminalView(frame: bounds)
        terminal.delegate = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: sessionBackend(for: shell) ?? .exec,
            workingDirectory: workingDirectory,
            envVars: [
                "GHOSTGRID": "1",
                "GHOSTGRID_SHELL": shell.name,
                // macOS bash 3.2 otherwise prints a "default shell is now zsh" notice.
                "BASH_SILENCE_DEPRECATION_WARNING": "1",
            ],
        )
        // The shell comes from the controller's config; see ShellConfig.
        terminal.controller = controllerFor(shell)
        terminal.onFocus = { [weak self] in
            guard let self else { return }
            onFocus?(self)
        }
        terminal.onInput = { [weak self] input in
            guard let self else { return }
            onInput?(self, input)
        }
        addSubview(terminal, positioned: .below, relativeTo: dimView)
        self.terminal = terminal
        choiceMenu?.removeFromSuperview()
        choiceMenu = nil
        title = shell.name
        onTitleChange?(self)
        refreshBranch()
        needsLayout = true
        layoutSubtreeIfNeeded()
        focus()
        if command != nil {
            // Normally sent when the shell reports its first prompt (OSC 7,
            // see terminalDidChangeWorkingDirectory); this is the fallback.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.sendPendingCommand()
            }
        }
    }

    // MARK: - Shell in sessiond

    /// The pane's shell lives in ghostgrid-sessiond, not under the app: a
    /// host-managed terminal whose bytes go over the helper's socket. It
    /// reattaches to `sessionID` when the pane was restored with one.
    /// nil when the helper cannot be reached: the pane then runs its shell
    /// directly, as before (it ends when the app quits).
    private func sessionBackend(for shell: ShellChoice) -> TerminalSessionBackend? {
        let client = SessionClient()
        let pipe = SessionPipe(client: client)
        let host = InMemoryTerminalSession(
            write: { data in
                DispatchQueue.main.async { MainActor.assumeIsolated { pipe.client?.send(.input(data)) } }
            },
            resize: { viewport in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        pipe.client?.resize(
                            columns: viewport.columns, rows: viewport.rows,
                            width: UInt16(clamping: viewport.widthPixels), height: UInt16(clamping: viewport.heightPixels),
                        )
                    }
                }
            },
        )
        let attaching = sessionID
        var first: SessionMessage?
        if let attaching {
            first = .attach(id: attaching)
        } else if let launch = makeLaunch(shell) {
            sessionID = launch.id
            client.pendingCreate = launch // started at the pane's first size
        } else {
            return nil
        }
        client.onAttached = { [weak self] replay in
            host.receiveReplay(replay)
            self?.blocks.replace(with: replay)
        }
        client.onOutput = { [weak self] data in
            host.receive(data)
            self?.blocks.feed(data)
            self?.outputArrived()
        }
        client.onExit = { [weak self] code in
            guard let self else { return }
            sessionID = nil
            onSessionChange?(self)
            let runtime = UInt64(max(0, Date().timeIntervalSince(startedAt)) * 1000)
            host.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: runtime)
        }
        client.onFailure = { [weak self, weak client] reason in
            guard let self, let client else { return }
            if reason == "no such session", attaching != nil, sessionID == attaching, let launch = makeLaunch(shell) {
                // The kept shell is gone (a reboot, or it exited while
                // ghostgrid was closed): start a fresh one in its place.
                sessionID = launch.id
                onSessionChange?(self)
                client.pendingCreate = launch
                client.startPending()
                return
            }
            // Another ghostgrid took the shell, or the helper went away:
            // say so in the pane and leave the shell alone.
            sessionID = nil
            self.client = nil
            client.close()
            onSessionChange?(self)
            host.receive(Data("\r\n\u{1B}[2m[ghostgrid: \(reason)]\u{1B}[0m\r\n".utf8))
        }
        guard client.open(first) else {
            sessionID = attaching
            return nil
        }
        self.client = client
        startedAt = Date()
        if attaching == nil {
            onSessionChange?(self)
            // Should the pane never report a size, start anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak client] in client?.startPending() }
        }
        return .inMemory(host)
    }

    private func makeLaunch(_ shell: ShellChoice) -> SessionLaunch? {
        let values = GhosttyOptions.shared.values
        let resources = ShellLaunch.Resources(
            ghostty: GhosttyRuntimeResources.directoryURL?.path ?? "",
            terminfo: GhosttyRuntimeResources.terminfoDirectoryURL?.path ?? "",
            features: ShellLaunch.features(config: values.string("shell-integration-features")),
            integration: ShellLaunch.usesIntegration(shell: shell.name, config: values.string("shell-integration")),
            hooks: HookFiles.directory,
        )
        var base = ProcessInfo.processInfo.environment
        // The app's own launch context, not the shell's.
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID", "OLDPWD", "SHLVL", "_"] {
            base[key] = nil
        }
        return ShellLaunch.launch(
            id: UUID().uuidString, shell: shell, base: base, resources: resources,
            workingDirectory: workingDirectory ?? NSHomeDirectory(),
        )
    }

    /// Ends the pane's shell for good (closing the pane or its window).
    func endShell() {
        guard let client else { return }
        if sessionID != nil { client.send(.terminate) }
        client.close()
        self.client = nil
        sessionID = nil
    }

    /// Types the pending command as keystrokes and presses Enter.
    /// Keystrokes rather than a paste: a paste that arrives before the line
    /// editor is reading shows its bracketed-paste markers (^[[200~) as text.
    private func sendPendingCommand() {
        guard let command = pendingCommand, let terminal else { return }
        let presses = command.compactMap { TerminalKeyPress(typing: $0) }
        guard presses.count == command.count, let first = presses.first,
              terminal.sendKey(first) // false: no surface yet; try again later
        else { return }
        pendingCommand = nil
        for press in presses.dropFirst() {
            terminal.sendKey(press)
        }
        terminal.sendKey(.enter)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        dimView.frame = bounds
        layoutChrome(for: bounds.size)
        layoutSearchBar()
        blocksPanel?.frame = contentRect(for: bounds.size).insetBy(dx: 6, dy: 6)
        layoutExplainPanel()
        // While a resize animates, the terminal already has its final size
        // and a transform scales it to the box; resizing it here would undo that.
        guard contentAnimation == 0 else { return }
        content?.frame = contentRect(for: bounds.size)
        terminal?.fitToSize()
    }

    // MARK: - Animated resize

    /// Non-zero while a content animation runs; bumped by each new one so a
    /// superseded animation's completion does not unfreeze the newer one.
    private var contentAnimation = 0
    private var contentGeneration = 0

    /// Call when the pane's frame is about to animate from `old` to `new`
    /// size. The terminal jumps to the final size once (a single reflow),
    /// then a uniform sublayer transform scales it to cover `old` and eases to
    /// identity on the same curve as the frame. The text moves with the box
    /// instead of snapping, and is crisp when the animation lands.
    func animateContent(from old: CGSize, to new: CGSize, duration: TimeInterval, curve: CubicBezier) {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0, old != new, let layer else { return }
        content?.frame = contentRect(for: new)
        layoutChrome(for: new)
        terminal?.fitToSize()
        // Sampled along the same curve as the frame, so the content covers
        // the box exactly at every moment, overshoot included.
        let animation = CAKeyframeAnimation(keyPath: "sublayerTransform")
        animation.values = ContentScale.keyframes(from: old, to: new, curve: curve)
            .map { CATransform3DMakeScale($0, $0, 1) }
        animation.calculationMode = .linear
        animation.duration = duration
        install(animation, final: CATransform3DIdentity, on: layer, duration: duration)
    }

    /// Scales the content by `factor` without resizing the terminal, for a
    /// pane that is going away.
    func shrinkContent(by factor: CGFloat, duration: TimeInterval, curve: CAMediaTimingFunction) {
        runContentAnimation(
            from: CATransform3DIdentity,
            to: CATransform3DMakeScale(factor, factor, 1),
            duration: duration,
            curve: curve,
        )
    }

    private func runContentAnimation(
        from: CATransform3D,
        to: CATransform3D,
        duration: TimeInterval,
        curve: CAMediaTimingFunction,
    ) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = curve
        install(animation, final: to, on: layer, duration: duration)
    }

    private func install(_ animation: CAAnimation, final: CATransform3D, on layer: CALayer, duration: TimeInterval) {
        // Anchor at the origin, which is the top-left corner because the view
        // is flipped: content scales about the corner its first line is in.
        layer.anchorPoint = .zero
        layer.sublayerTransform = final
        layer.add(animation, forKey: "ghostgrid.content")

        contentGeneration += 1
        let generation = contentGeneration
        contentAnimation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, contentGeneration == generation else { return }
            contentAnimation = 0
            layer.sublayerTransform = CATransform3DIdentity
            needsLayout = true
        }
    }

    func focus() {
        window?.makeFirstResponder(searchBar?.field ?? content)
    }

    // MARK: - Header and activity badges

    private var headerHeight: CGFloat { header == nil ? 0 : PaneHeaderView.height }

    /// The terminal (or menu) area: everything below the header.
    private func contentRect(for size: CGSize) -> CGRect {
        CGRect(x: 0, y: headerHeight, width: size.width, height: max(size.height - headerHeight, 0))
    }

    private func layoutChrome(for size: CGSize) {
        header?.frame = CGRect(x: 0, y: 0, width: size.width, height: PaneHeaderView.height)
        if let cornerBadge {
            let fit = cornerBadge.fittingSize
            cornerBadge.frame = CGRect(x: size.width - fit.width - 8, y: 8, width: fit.width, height: fit.height)
        }
    }

    @objc private func settingsChanged() {
        applyChromeSettings()
    }

    /// Adds or removes the header and corner badge to match Settings.
    private func applyChromeSettings() {
        let wantsHeader = settings.showPaneHeaders
        if wantsHeader, header == nil {
            let view = PaneHeaderView()
            view.isFocused = isFocusedPane
            view.isBroadcasting = isBroadcasting
            view.onPress = { [weak self] in self?.focus() }
            view.onDrag = { [weak self] phase, point in
                guard let self else { return }
                onHeaderDrag?(self, phase, point)
            }
            addSubview(view) // above the terminal and the dim layer
            header = view
        } else if !wantsHeader, let view = header {
            view.removeFromSuperview()
            header = nil
        }
        if wantsHeader, let badge = cornerBadge {
            badge.removeFromSuperview()
            cornerBadge = nil
        } else if !wantsHeader, cornerBadge == nil {
            let badge = ActivityBadgeView()
            addSubview(badge)
            cornerBadge = badge
        }
        if !settings.showActivityBadges { activity = nil }
        (header?.badge ?? cornerBadge)?.activity = activity
        updateHeader()
        needsLayout = true
    }

    private func updateHeader() {
        header?.update(shell: shell?.name, directory: workingDirectory, branch: branch)
    }

    /// Re-reads the branch (after a cd, a command, or focusing the pane:
    /// `git switch` changes it without changing the folder).
    private func refreshBranch() {
        let fm = FileManager.default
        branch = workingDirectory.flatMap { directory in
            GitBranch.read(
                from: directory,
                fileExists: { fm.fileExists(atPath: $0) },
                isDirectory: { path in
                    var isDirectory: ObjCBool = false
                    return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                },
                readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
            )
        }
        updateHeader()
    }

    /// Whether you are looking at this pane: focused in its grid, in the
    /// key window of the active app.
    private var isWatched: Bool {
        isFocusedPane && window?.isKeyWindow == true && NSApp.isActive
    }

    private func note(_ new: PaneActivity) {
        guard !isWatched else { return }
        needsYou = true
        guard settings.showActivityBadges else { return }
        activity = new
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window,
            )
        }
    }

    /// Coming back to the window clears the focused pane's badge.
    @objc private func windowBecameKey() {
        if isFocusedPane { activity = nil }
    }

    // MARK: - Unfocused dimming

    @objc private func optionsChanged() {
        updateDim(animated: false)
    }

    /// Ghostty fades unfocused splits toward the background by
    /// 1 - unfocused-split-opacity; panes do the same.
    private func updateDim(animated: Bool) {
        let opacity = GhosttyOptions.shared.unfocusedOpacity
        dimView.layer?.backgroundColor = Palette.paneBackground.withAlphaComponent(1).cgColor
        let target: CGFloat = isFocusedPane ? 0 : CGFloat(1 - opacity)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                dimView.animator().alphaValue = target
            }
        } else {
            dimView.alphaValue = target
        }
    }

    // MARK: - Bell

    /// Ghostty's bell: flash the border, and bounce the Dock icon when
    /// ghostgrid is in the background.
    private func ringBell() {
        if let layer {
            let color = CABasicAnimation(keyPath: "borderColor")
            color.fromValue = Palette.bell.cgColor
            color.toValue = (isFocusedPane ? Palette.focus : Palette.idle).cgColor
            let width = CABasicAnimation(keyPath: "borderWidth")
            width.fromValue = 4
            width.toValue = isFocusedPane ? 2 : 1
            for animation in [color, width] {
                animation.duration = 0.6
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "ghostgrid.bell.\(animation.keyPath ?? "")")
            }
        }
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: - Command blocks

    /// Shows or hides the pane's command list (Pane > Command Blocks).
    func toggleBlocks() {
        if let panel = blocksPanel {
            blocksPanel = nil
            blocks.isWatched = false
            panel.removeFromSuperview()
            window?.makeFirstResponder(terminal)
            return
        }
        let actions = CommandBlockActions(
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            rerun: { [weak self] command in
                self?.toggleBlocks()
                self?.run(command)
            },
            close: { [weak self] in self?.toggleBlocks() },
        )
        blocks.isWatched = true
        let panel = NSHostingView(rootView: CommandBlocksView(store: blocks, actions: actions))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 8
        panel.layer?.masksToBounds = true
        addSubview(panel, positioned: .above, relativeTo: nil)
        blocksPanel = panel
        needsLayout = true
    }

    // MARK: - Explain failures

    /// Pane > Explain Last Failure: explains the last failed command (or
    /// focuses its panel if it is already up), so Return runs the fix.
    @discardableResult
    func explainLastFailure() -> Bool {
        if let panel = explainPanel {
            window?.makeFirstResponder(panel)
            return true
        }
        guard let block = blocks.all.last(where: { ExplainPolicy.offers(exitCode: $0.exitCode, command: $0.command) })
        else { return false }
        showExplain(for: block, focus: true)
        return true
    }

    private func showExplain(for block: CommandBlock, focus: Bool) {
        guard let command = block.command, let exitCode = block.exitCode else { return }
        hideExplain()
        let model = ExplainModel(blockID: block.id, command: command, exitCode: exitCode)
        let panel = ExplainPanelView(model: model)
        panel.onRun = { [weak self] fix in
            self?.hideExplain()
            self?.run(fix)
        }
        panel.onDismiss = { [weak self] in self?.hideExplain() }
        panel.onForward = { [weak self] event in self?.terminal?.keyDown(with: event) }
        addSubview(panel, positioned: .above, relativeTo: nil)
        explainPanel = panel
        layoutExplainPanel()
        if focus { window?.makeFirstResponder(panel) }
        let failure = FailedCommand(command: command, output: block.output, exitCode: exitCode,
                                    shell: shell?.name ?? "zsh", directory: workingDirectory)
        explainTask = LocalModel.explain(failure, thinking: { [weak model] in
            model?.isThinking = true
        }, update: { [weak self, weak model] explanation in
            model?.explanation = explanation
            self?.layoutExplainPanel()
        }, finish: { [weak self, weak model] error in
            model?.status = error.map { .failed($0) } ?? .done
            self?.layoutExplainPanel()
        })
    }

    private func hideExplain() {
        explainTask?.cancel()
        explainTask = nil
        guard let panel = explainPanel else { return }
        explainPanel = nil
        let hadFocus = window?.firstResponder === panel
        panel.removeFromSuperview()
        if hadFocus { window?.makeFirstResponder(terminal) }
    }

    private func layoutExplainPanel() {
        guard let panel = explainPanel else { return }
        let area = contentRect(for: bounds.size).insetBy(dx: 8, dy: 8)
        panel.frame = CGRect(x: area.minX, y: 0, width: area.width, height: 10)
        panel.layoutSubtreeIfNeeded()
        let height = min(panel.fittingHeight, area.height * 0.6)
        panel.frame = CGRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
    }

    /// Copies the output of the last finished command; false when there is none.
    @discardableResult
    func copyLastOutput() -> Bool {
        guard let block = blocks.all.last(where: \.isFinished) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.output, forType: .string)
        return true
    }

    /// Types `command` at the prompt and runs it. Several lines go in as
    /// one paste, so the shell gets them as a whole.
    private func run(_ command: String) {
        guard let terminal else { return }
        focus()
        if command.contains("\n") {
            terminal.paste(text: command)
            terminal.sendKey(.enter)
        } else {
            pendingCommand = command
            sendPendingCommand()
        }
    }

    // MARK: - Search

    private func showSearch(needle: String?) {
        if searchBar == nil {
            let bar = SearchBarView()
            bar.onChange = { [weak self] text in
                _ = self?.terminal?.performBindingAction("search:\(text)")
            }
            bar.onNext = { [weak self] in _ = self?.terminal?.performBindingAction("navigate_search:next") }
            bar.onPrevious = { [weak self] in _ = self?.terminal?.performBindingAction("navigate_search:previous") }
            bar.onClose = { [weak self] in
                _ = self?.terminal?.performBindingAction("end_search")
                self?.hideSearch()
            }
            searchBar = bar
            addSubview(bar)
            layoutSearchBar()
        }
        if let needle, !needle.isEmpty { searchBar?.text = needle }
        window?.makeFirstResponder(searchBar?.field)
    }

    private func hideSearch() {
        guard let bar = searchBar else { return }
        searchBar = nil
        bar.removeFromSuperview()
        window?.makeFirstResponder(terminal)
    }

    private func layoutSearchBar() {
        guard let bar = searchBar else { return }
        let size = bar.fittingSize
        let width = min(max(size.width, 260), bounds.width - 16)
        bar.frame = CGRect(x: bounds.maxX - width - 8, y: headerHeight + 8, width: width, height: size.height)
    }

    /// A bright border that cools to the focus blue as the pane lands.
    func flashArrival(duration: TimeInterval) {
        guard let layer else { return }
        let color = CABasicAnimation(keyPath: "borderColor")
        color.fromValue = Palette.flash.cgColor
        color.toValue = Palette.focus.cgColor
        let width = CABasicAnimation(keyPath: "borderWidth")
        width.fromValue = 5
        width.toValue = 2
        for animation in [color, width] {
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "ghostgrid.flash.\(animation.keyPath ?? "")")
        }
    }

    private func animateBorder(to color: NSColor, width: CGFloat) {
        guard let layer else { return }
        let duration = 0.18
        for (key, value) in [("borderColor", color.cgColor as Any), ("borderWidth", width as Any)] {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            animation.toValue = value
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: key)
        }
        layer.borderColor = color.cgColor
        layer.borderWidth = width
    }
}

extension PaneView: TerminalSurfaceTitleDelegate, TerminalSurfacePwdDelegate, TerminalSurfaceCloseDelegate,
    TerminalSurfaceOpenURLHandlingDelegate, TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate, TerminalSurfaceSearchDelegate,
    TerminalSurfaceCommandFinishedDelegate
{
    /// Cmd-click on a link. The package refuses every link on macOS unless
    /// the host opens it; LinkPolicy vets what the terminal handed over.
    /// Files Ghostty writes itself (.text/.html) stay with Ghostty.
    func terminalShouldHandleOpenURL(_ url: String, kind: TerminalOpenURLKind) -> Bool {
        if kind == .text || kind == .html { return false }
        if let target = LinkPolicy.url(
            for: url, workingDirectory: workingDirectory, home: NSHomeDirectory(),
            fileExists: { FileManager.default.fileExists(atPath: $0) },
        ) {
            NSWorkspace.shared.open(target)
        }
        return true
    }

    func terminalDidRingBell() {
        ringBell()
        note(.bell)
    }

    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        refreshBranch()
        if let finished = PaneActivity.forFinishedCommand(
            exitCode: exitCode, durationNanos: durationNanos, paneFocused: isWatched,
        ) {
            note(finished)
        }
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        Notifier.post(title: title.isEmpty ? self.title : title, body: body)
        // Agents (Claude Code and friends) notify when they wait for you.
        if !isWatched { needsYou = true }
    }

    func terminalDidStartSearch(needle: String?) {
        showSearch(needle: needle)
    }

    func terminalDidEndSearch() {
        hideSearch()
    }

    func terminalDidUpdateSearchTotal(_ total: Int?) {
        searchBar?.total = total
    }

    func terminalDidUpdateSearchSelected(_ selected: Int?) {
        searchBar?.selected = selected
    }

    func terminalDidChangeTitle(_ title: String) {
        self.title = title
        onTitleChange?(self)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        let changed = workingDirectory != path
        workingDirectory = path
        if changed {
            onWorkingDirectoryChange?(self)
            refreshBranch()
        }
        // The shell integration reports the directory just before each
        // prompt; the line editor starts reading right after it.
        if pendingCommand != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.sendPendingCommand()
            }
        }
    }

    func terminalDidClose(processAlive _: Bool) {
        onExit?(self)
    }
}

/// Catppuccin Mocha accents, matching the dotfiles rice.
enum Palette {
    static let focus = NSColor(srgbRed: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 1)  // blue
    static let success = NSColor(srgbRed: 0xA6 / 255, green: 0xE3 / 255, blue: 0xA1 / 255, alpha: 1) // green
    static let failure = NSColor(srgbRed: 0xF3 / 255, green: 0x8B / 255, blue: 0xA8 / 255, alpha: 1) // red
    static let bell = NSColor(srgbRed: 0xFA / 255, green: 0xB3 / 255, blue: 0x87 / 255, alpha: 1)   // peach
    static let flash = NSColor(srgbRed: 0xB4 / 255, green: 0xBE / 255, blue: 0xFE / 255, alpha: 1) // lavender
    static let text = NSColor(srgbRed: 0xCD / 255, green: 0xD6 / 255, blue: 0xF4 / 255, alpha: 1)
    static let subtext = NSColor(srgbRed: 0xA6 / 255, green: 0xAD / 255, blue: 0xC8 / 255, alpha: 1)
    static let overlay = NSColor(srgbRed: 0x6C / 255, green: 0x70 / 255, blue: 0x86 / 255, alpha: 1)
    /// Mocha Black, at Ghostty's background-opacity.
    static let paneBackground = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255, alpha: 0.92)
    static let card = NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x25 / 255, alpha: 1) // mantle

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "JetBrainsMono NF", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static let idle = NSColor(srgbRed: 0x45 / 255, green: 0x47 / 255, blue: 0x5A / 255, alpha: 0.6) // surface1
}
