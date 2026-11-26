import AppKit
import GhostGridCore
import GhosttyTerminal

/// Holds every pane in a window and keeps them in a balanced, animated grid.
@MainActor
final class GridView: NSView {
    private let controllerFor: ControllerProvider
    private(set) var panes: [PaneView] = []
    private(set) weak var focused: PaneView?
    private var zoomed: PaneView?
    /// This window's arrangement (Pane > Layout); new windows start with the
    /// Settings default.
    private(set) var mode: GridLayout.Mode = GhostGridSettings.shared.defaultLayout
    /// A pane being dragged by its header, and where it was grabbed.
    private var dragging: (pane: PaneView, grab: CGPoint)?
    private weak var dropTarget: PaneView?

    private var settings: GhostGridSettings { .shared }

    /// Space between panes (Settings > Grid).
    var gap: CGFloat { CGFloat(settings.gap) }
    /// Grid changes (add, zoom, rebalance) use the Settings animation style;
    /// frames and terminal content share one curve so the text stays locked
    /// to its box. nil: animations off.
    private var springCurve: CubicBezier? { settings.animation.curve }
    var springDuration: TimeInterval { settings.animation.duration * GridView.slowdown }
    private func timing(_ curve: CubicBezier) -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
    }
    /// Closing: fast start, soft landing, no overshoot (instant when off).
    var closeDuration: TimeInterval { settings.animation == .off ? 0 : 0.22 * GridView.slowdown }

    /// GHOSTGRID_SLOW_ANIMATIONS=8 plays every animation 8x slower, for tuning.
    static let slowdown: TimeInterval = ProcessInfo.processInfo
        .environment["GHOSTGRID_SLOW_ANIMATIONS"].flatMap(TimeInterval.init).map { max($0, 1) } ?? 1
    private let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    /// Looked up once per new pane, so a shell installed while the app
    /// runs shows up in the next menu.
    private var shells: [ShellChoice] {
        ShellCatalog.resolve(home: NSHomeDirectory()) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var onEmpty: (() -> Void)?
    /// Something worth saving changed (panes, focus, zoom, a folder).
    var onChange: (() -> Void)?
    var onTitleChange: ((String) -> Void)?

    init(controllerFor: @escaping ControllerProvider) {
        self.controllerFor = controllerFor
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: GhostGridSettings.didChange, object: nil,
        )
    }

    /// A new gap or animation style applies to open grids right away.
    @objc private func settingsChanged() {
        apply(targetFrames(), animated: true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Window resizes track the grid directly; only pane changes animate.
        apply(targetFrames(), animated: false)
    }

    // MARK: - Panes

    /// Adds a pane. With `chooseShell` false it starts the remembered shell
    /// right away (falling back to the menu when there is none); with true
    /// it always shows the menu.
    func addPane(chooseShell: Bool = false, directory: String? = nil) {
        let shells = shells
        let remembered = ShellCatalog.remembered(settings.lastShell, in: shells)
        let startShell = chooseShell || !settings.newPaneUsesLastShell ? nil : remembered
        let pane = PaneView(
            controllerFor: controllerFor,
            workingDirectory: directory ?? focused?.workingDirectory,
            shells: shells,
            shell: startShell,
            preferred: remembered,
            offerApps: startShell == nil && settings.offerAppsAfterZsh,
        )
        wire(pane)

        // Launch out of the pane it was opened from (or the window's centre),
        // as a small card that springs out to its own cell.
        let parent = focused.map { $0.layer?.presentation()?.frame ?? $0.frame } ?? bounds
        zoomed = nil
        panes.append(pane)
        let targets = targetFrames()
        let target = targets[panes.count - 1]
        let start = CGSize(width: target.width * 0.3, height: target.height * 0.3)
        pane.frame = CGRect(
            x: parent.midX - start.width / 2, y: parent.midY - start.height / 2,
            width: start.width, height: start.height,
        )
        pane.alphaValue = 0
        addSubview(pane, positioned: .above, relativeTo: nil)

        apply(targets, animated: true)
        pane.focus()
        onChange?()
        // After focus, so it plays over the focus border animation.
        pane.flashArrival(duration: springDuration + 0.3)
    }

    func closeFocused() {
        guard let focused else { return }
        remove(focused)
    }

    private func wire(_ pane: PaneView) {
        pane.onShellPicked = { [weak self] shell in
            self?.settings.lastShell = shell.name
            self?.onChange?()
        }
        pane.onFocus = { [weak self] in self?.paneDidFocus($0) }
        pane.onTitleChange = { [weak self] pane in
            guard let self, pane === focused else { return }
            onTitleChange?(pane.title)
        }
        pane.onWorkingDirectoryChange = { [weak self] _ in self?.onChange?() }
        pane.onHeaderDrag = { [weak self] pane, phase, point in self?.headerDrag(pane, phase, point) }
        pane.onExit = { [weak self] in self?.remove($0) }
    }

    // MARK: - Session

    /// The panes worth saving, in grid order: those running a shell (a
    /// pane still showing its menu is skipped), with focus and zoom.
    func snapshot() -> (panes: [Session.Pane], focused: Int?, zoomed: Int?, layout: GridLayout.Mode) {
        var saved: [Session.Pane] = []
        var focusedIndex: Int?
        var zoomedIndex: Int?
        for pane in panes {
            guard let shell = pane.shell else { continue }
            if pane === focused { focusedIndex = saved.count }
            if pane === zoomed { zoomedIndex = saved.count }
            saved.append(.init(shell: shell.name, workingDirectory: pane.workingDirectory))
        }
        return (saved, focusedIndex, zoomedIndex, mode)
    }

    /// Rebuilds a saved window's panes, without animation. A saved shell
    /// that is no longer installed gets the shell menu instead.
    func restore(_ window: Session.Window) {
        let shells = shells
        for saved in window.panes {
            let shell = shells.first { $0.name == saved.shell && $0.isInstalled }
            let pane = PaneView(
                controllerFor: controllerFor,
                workingDirectory: saved.workingDirectory,
                shells: shells,
                shell: shell,
                preferred: ShellCatalog.remembered(settings.lastShell, in: shells),
            )
            wire(pane)
            panes.append(pane)
            addSubview(pane)
        }
        zoomed = window.zoomed.map { panes[$0] }
        mode = window.layout ?? .grid
        apply(targetFrames(), animated: false)
        (window.focused.map { panes[$0] } ?? panes.last)?.focus()
    }

    private func remove(_ pane: PaneView) {
        guard let index = panes.firstIndex(of: pane) else { return }
        panes.remove(at: index)
        if zoomed === pane { zoomed = nil }

        pane.shrinkContent(by: 0.84, duration: closeDuration, curve: ease)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = closeDuration
            context.timingFunction = ease
            context.allowsImplicitAnimation = true
            let frame = pane.frame
            pane.animator().frame = frame.insetBy(dx: frame.width * 0.08, dy: frame.height * 0.08)
            pane.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { pane.removeFromSuperview() }
        }

        onChange?()
        guard !panes.isEmpty else {
            onEmpty?()
            return
        }
        apply(targetFrames(), animated: true)
        panes[max(0, index - 1)].focus()
    }

    // MARK: - Focus and zoom

    func focusNext(_ step: Int) {
        guard let focused, let index = panes.firstIndex(of: focused), panes.count > 1 else { return }
        let next = (index + step + panes.count) % panes.count
        if zoomed != nil { zoomed = panes[next]; apply(targetFrames(), animated: true) }
        panes[next].focus()
    }

    func focus(_ direction: GridLayout.Direction) {
        guard zoomed == nil, let focused, let index = panes.firstIndex(of: focused) else { return }
        let frames = GridLayout.frames(count: panes.count, in: bounds, gap: gap, mode: mode)
        if let next = GridLayout.neighbor(of: index, in: frames, direction: direction) {
            panes[next].focus()
        }
    }

    /// Focuses the pane at `index` (grid order); while zoomed, zooms it.
    func focusPane(at index: Int) {
        guard panes.indices.contains(index) else { return }
        if zoomed != nil {
            zoomed = panes[index]
            apply(targetFrames(), animated: true)
        }
        panes[index].focus()
    }

    func toggleZoom() {
        guard let focused, panes.count > 1 else { return }
        zoomed = zoomed == nil ? focused : nil
        apply(targetFrames(), animated: true)
        focused.focus()
        onChange?()
    }

    // MARK: - Reordering and layouts

    /// Swaps the focused pane with its neighbour in `direction`; focus moves
    /// with the pane.
    func swapFocused(_ direction: GridLayout.Direction) {
        guard zoomed == nil, let focused, let index = panes.firstIndex(of: focused) else { return }
        let frames = GridLayout.frames(count: panes.count, in: bounds, gap: gap, mode: mode)
        guard let other = GridLayout.neighbor(of: index, in: frames, direction: direction) else { return }
        swapPanes(index, other)
    }

    /// Moves the focused pane to the first slot: the big one in Main + Stack.
    func makeFocusedMain() {
        guard let focused, let index = panes.firstIndex(of: focused), index != 0 else { return }
        swapPanes(index, 0)
    }

    private func swapPanes(_ a: Int, _ b: Int) {
        panes.swapAt(a, b)
        apply(targetFrames(), animated: true)
        focused?.focus()
        onChange?()
    }

    func setMode(_ new: GridLayout.Mode) {
        guard new != mode else { return }
        mode = new
        apply(targetFrames(), animated: true)
        onChange?()
    }

    /// Drag a pane by its header and drop it on another to swap them. The
    /// pane follows the pointer; the pane under it lights up as the target.
    private func headerDrag(_ pane: PaneView, _ phase: PaneHeaderView.DragPhase, _ windowPoint: NSPoint) {
        guard zoomed == nil, panes.count > 1, let index = panes.firstIndex(of: pane) else { return }
        let point = convert(windowPoint, from: nil)
        switch phase {
        case .began:
            dragging = (pane, CGPoint(x: point.x - pane.frame.minX, y: point.y - pane.frame.minY))
            addSubview(pane, positioned: .above, relativeTo: nil)
            pane.animator().alphaValue = 0.92
        case .moved:
            guard let dragging else { return }
            pane.setFrameOrigin(NSPoint(x: point.x - dragging.grab.x, y: point.y - dragging.grab.y))
            let target = GridLayout.index(at: point, in: targetFrames(), excluding: index).map { panes[$0] }
            if target !== dropTarget {
                dropTarget?.isDropTarget = false
                target?.isDropTarget = true
                dropTarget = target
            }
        case .ended:
            dragging = nil
            pane.animator().alphaValue = 1
            let target = dropTarget.flatMap { panes.firstIndex(of: $0) }
            dropTarget?.isDropTarget = false
            dropTarget = nil
            if let target {
                swapPanes(index, target)
            } else {
                apply(targetFrames(), animated: true) // spring back
            }
        }
    }

    private func paneDidFocus(_ pane: PaneView) {
        defer { onChange?() }
        focused = pane
        for candidate in panes {
            candidate.isFocusedPane = candidate === pane
        }
        onTitleChange?(pane.title)
    }

    // MARK: - Layout

    private func targetFrames() -> [CGRect] {
        let grid = GridLayout.frames(count: panes.count, in: bounds, gap: gap, mode: mode)
        guard let zoomed, let zoomIndex = panes.firstIndex(of: zoomed) else { return grid }
        // A zoomed pane takes the whole window; the rest keep their cells.
        var frames = grid
        frames[zoomIndex] = bounds.insetBy(dx: gap, dy: gap)
        return frames
    }

    private func apply(_ frames: [CGRect], animated requested: Bool) {
        guard frames.count == panes.count else { return }
        // Animations off in Settings: set frames directly. (Going through
        // animator() would still animate, with AppKit's default duration.)
        let curve = requested ? springCurve : nil
        let animated = curve != nil
        let update = {
            for (pane, frame) in zip(self.panes, frames) {
                let visible = self.zoomed == nil || pane === self.zoomed
                let target = animated ? pane.animator() : pane
                target.frame = frame
                target.alphaValue = visible ? 1 : 0
            }
        }

        // The zoomed pane draws above its neighbours while it grows.
        if let zoomed { addSubview(zoomed, positioned: .above, relativeTo: nil) }
        for pane in panes {
            pane.terminal?.setSurfaceVisible(zoomed == nil || pane === zoomed)
        }

        guard let curve else {
            update()
            return
        }
        for (pane, frame) in zip(panes, frames) {
            // Start from what is on screen, in case an animation is running.
            let current = pane.layer?.presentation()?.bounds.size ?? pane.frame.size
            pane.animateContent(from: current, to: frame.size, duration: springDuration, curve: curve)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = springDuration
            context.timingFunction = timing(curve)
            context.allowsImplicitAnimation = true
            update()
        }
    }
}
