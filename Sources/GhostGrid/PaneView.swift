import AppKit
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

    override func layout() {
        super.layout()
        terminal.frame = bounds
        terminal.fitToSize()
    }

    func focus() {
        window?.makeFirstResponder(terminal)
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
    static let idle = NSColor(srgbRed: 0x45 / 255, green: 0x47 / 255, blue: 0x5A / 255, alpha: 0.6) // surface1
}
