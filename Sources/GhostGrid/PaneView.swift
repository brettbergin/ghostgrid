import AppKit
import GhostGridCore
import GhosttyTerminal

/// A Ghostty terminal view that reports when it takes keyboard focus.
@MainActor
final class PaneTerminalView: AppTerminalView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// One grid cell: a rounded container around a live Ghostty surface, with a
/// border that lights up while the pane has focus.
@MainActor
final class PaneView: NSView {
    let terminal = PaneTerminalView(frame: .zero)
    private(set) var title = ""
    private(set) var workingDirectory: String?

    var onFocus: ((PaneView) -> Void)?
    var onTitleChange: ((PaneView) -> Void)?
    var onExit: ((PaneView) -> Void)?

    var isFocusedPane = false {
        didSet {
            guard isFocusedPane != oldValue else { return }
            animateBorder(to: isFocusedPane ? Palette.focus : Palette.idle,
                          width: isFocusedPane ? 2 : 1)
        }
    }

    init(controller: TerminalController, workingDirectory: String?) {
        self.workingDirectory = workingDirectory
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Palette.idle.cgColor

        terminal.delegate = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: workingDirectory,
            envVars: ["GHOSTGRID": "1"],
        )
        terminal.controller = controller
        terminal.onFocus = { [weak self] in
            guard let self else { return }
            onFocus?(self)
        }
        addSubview(terminal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // While a resize animates, the terminal already has its final size
        // and a transform scales it to the box; resizing it here would undo that.
        guard contentAnimation == 0 else { return }
        terminal.frame = bounds
        terminal.fitToSize()
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
        terminal.frame = CGRect(origin: .zero, size: new)
        terminal.fitToSize()
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
        window?.makeFirstResponder(terminal)
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

extension PaneView: TerminalSurfaceTitleDelegate, TerminalSurfacePwdDelegate, TerminalSurfaceCloseDelegate {
    func terminalDidChangeTitle(_ title: String) {
        self.title = title
        onTitleChange?(self)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        workingDirectory = path
    }

    func terminalDidClose(processAlive _: Bool) {
        onExit?(self)
    }
}

/// Catppuccin Mocha accents, matching the dotfiles rice.
enum Palette {
    static let focus = NSColor(srgbRed: 0x89 / 255, green: 0xB4 / 255, blue: 0xFA / 255, alpha: 1)  // blue
    static let flash = NSColor(srgbRed: 0xB4 / 255, green: 0xBE / 255, blue: 0xFE / 255, alpha: 1) // lavender
    static let idle = NSColor(srgbRed: 0x45 / 255, green: 0x47 / 255, blue: 0x5A / 255, alpha: 0.6) // surface1
}
