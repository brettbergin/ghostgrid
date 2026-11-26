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

    let gap: CGFloat = 8
    /// Grid changes (add, zoom, rebalance): a quick spring that overshoots
    /// a little and settles. Frames and terminal content share one curve so
    /// the text stays locked to its box.
    let springDuration: TimeInterval = 0.46 * GridView.slowdown
    private let springCurve = CubicBezier(0.32, 1.42, 0.6, 1)
    private var spring: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(springCurve.x1), Float(springCurve.y1),
                              Float(springCurve.x2), Float(springCurve.y2))
    }
    /// Closing: fast start, soft landing, no overshoot.
    let closeDuration: TimeInterval = 0.22 * GridView.slowdown

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
    var onTitleChange: ((String) -> Void)?

    init(controllerFor: @escaping ControllerProvider) {
        self.controllerFor = controllerFor
        super.init(frame: .zero)
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
    func addPane(chooseShell: Bool = false) {
        let shells = shells
        let remembered = ShellCatalog.remembered(ShellMemory.last, in: shells)
        let pane = PaneView(
            controllerFor: controllerFor,
            workingDirectory: focused?.workingDirectory,
            shells: shells,
            shell: chooseShell ? nil : remembered,
            preferred: remembered,
        )
        pane.onShellPicked = { ShellMemory.last = $0.name }
        pane.onFocus = { [weak self] in self?.paneDidFocus($0) }
        pane.onTitleChange = { [weak self] pane in
            guard let self, pane === focused else { return }
            onTitleChange?(pane.title)
        }
        pane.onExit = { [weak self] in self?.remove($0) }

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
        // After focus, so it plays over the focus border animation.
        pane.flashArrival(duration: springDuration + 0.3)
    }

    func closeFocused() {
        guard let focused else { return }
        remove(focused)
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
        let frames = GridLayout.frames(count: panes.count, in: bounds, gap: gap)
        if let next = GridLayout.neighbor(of: index, in: frames, direction: direction) {
            panes[next].focus()
        }
    }

    func toggleZoom() {
        guard let focused, panes.count > 1 else { return }
        zoomed = zoomed == nil ? focused : nil
        apply(targetFrames(), animated: true)
        focused.focus()
    }

    private func paneDidFocus(_ pane: PaneView) {
        focused = pane
        for candidate in panes {
            candidate.isFocusedPane = candidate === pane
        }
        onTitleChange?(pane.title)
    }

    // MARK: - Layout

    private func targetFrames() -> [CGRect] {
        let grid = GridLayout.frames(count: panes.count, in: bounds, gap: gap)
        guard let zoomed, let zoomIndex = panes.firstIndex(of: zoomed) else { return grid }
        // A zoomed pane takes the whole window; the rest keep their cells.
        var frames = grid
        frames[zoomIndex] = bounds.insetBy(dx: gap, dy: gap)
        return frames
    }

    private func apply(_ frames: [CGRect], animated: Bool) {
        guard frames.count == panes.count else { return }
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

        guard animated else {
            update()
            return
        }
        for (pane, frame) in zip(panes, frames) {
            // Start from what is on screen, in case an animation is running.
            let current = pane.layer?.presentation()?.bounds.size ?? pane.frame.size
            pane.animateContent(from: current, to: frame.size, duration: springDuration, curve: springCurve)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = springDuration
            context.timingFunction = spring
            context.allowsImplicitAnimation = true
            update()
        }
    }
}
