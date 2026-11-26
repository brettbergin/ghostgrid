import AppKit
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

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
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
    /// Dims the pane while it is not focused (`unfocused-split-opacity`).
    private let dimView = PassthroughView()
    /// Shown while a search runs (Cmd+F, Ghostty's start_search).
    private var searchBar: SearchBarView?

    var onFocus: ((PaneView) -> Void)?
    var onTitleChange: ((PaneView) -> Void)?
    var onExit: ((PaneView) -> Void)?
    /// Called when the user picks a shell in this pane's menu.
    var onShellPicked: ((ShellChoice) -> Void)?

    var isFocusedPane = false {
        didSet {
            guard isFocusedPane != oldValue else { return }
            animateBorder(to: isFocusedPane ? Palette.focus : Palette.idle,
                          width: isFocusedPane ? 2 : 1)
            updateDim(animated: true)
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
    ) {
        self.controllerFor = controllerFor
        self.workingDirectory = workingDirectory
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
        let apps = LaunchCatalog.resolve(home: NSHomeDirectory()) {
            FileManager.default.isExecutableFile(atPath: $0)
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
            backend: .exec,
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
        addSubview(terminal, positioned: .below, relativeTo: dimView)
        self.terminal = terminal
        choiceMenu?.removeFromSuperview()
        choiceMenu = nil
        title = shell.name
        onTitleChange?(self)
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
        layoutSearchBar()
        // While a resize animates, the terminal already has its final size
        // and a transform scales it to the box; resizing it here would undo that.
        guard contentAnimation == 0 else { return }
        content?.frame = bounds
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
        content?.frame = CGRect(origin: .zero, size: new)
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
        bar.frame = CGRect(x: bounds.maxX - width - 8, y: 8, width: width, height: size.height)
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
    TerminalSurfaceDesktopNotificationDelegate, TerminalSurfaceSearchDelegate
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
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        Notifier.post(title: title.isEmpty ? self.title : title, body: body)
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
        workingDirectory = path
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
