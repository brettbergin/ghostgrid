import AppKit
import GhostGridCore
import GhosttyTerminal

/// Holds every pane in a window and keeps them in a balanced, animated grid.
@MainActor
final class GridView: NSView {
    private let controller: TerminalController
    private(set) var panes: [PaneView] = []
    private(set) weak var focused: PaneView?
    private var zoomed: PaneView?

    let gap: CGFloat = 8
    let duration: TimeInterval = 0.28
    /// Fast start, soft landing.
    private let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)

    var onEmpty: (() -> Void)?
    var onTitleChange: ((String) -> Void)?

    init(controller: TerminalController) {
        self.controller = controller
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

    func addPane() {
        let pane = PaneView(controller: controller, workingDirectory: focused?.workingDirectory)
        pane.onFocus = { [weak self] in self?.paneDidFocus($0) }
        pane.onTitleChange = { [weak self] pane in
            guard let self, pane === focused else { return }
            onTitleChange?(pane.title)
        }
        pane.onExit = { [weak self] in self?.remove($0) }

        zoomed = nil
        panes.append(pane)
        let targets = targetFrames()

        // Enter from a slightly smaller box at the pane's own spot, fading in.
        let target = targets[panes.count - 1]
        pane.frame = target.insetBy(dx: target.width * 0.08, dy: target.height * 0.08)
        pane.alphaValue = 0
        addSubview(pane)

        apply(targets, animated: true)
        pane.focus()
    }

    func closeFocused() {
        guard let focused else { return }
        remove(focused)
    }

    private func remove(_ pane: PaneView) {
        guard let index = panes.firstIndex(of: pane) else { return }
        panes.remove(at: index)
        if zoomed === pane { zoomed = nil }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration * 0.7
            context.timingFunction = curve
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
            pane.terminal.setSurfaceVisible(zoomed == nil || pane === zoomed)
        }

        guard animated else {
            update()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = curve
            context.allowsImplicitAnimation = true
            update()
        }
    }
}
