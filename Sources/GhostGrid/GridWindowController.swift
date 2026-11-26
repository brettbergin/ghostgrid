import AppKit
import GhostGridCore
import GhosttyTerminal

/// Gives the app's menu shortcuts priority over the terminal, which would
/// otherwise take Cmd+T, Cmd+W and friends as Ghostty keybindings.
@MainActor
final class GridWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class GridWindowController: NSWindowController, NSWindowDelegate {
    let grid: GridView
    var onClose: ((GridWindowController) -> Void)?

    init(controllerFor: @escaping ControllerProvider) {
        grid = GridView(controllerFor: controllerFor)
        let window = GridWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        window.title = "ghostgrid"
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false

        // Frosted glass behind the panes; Ghostty's background-opacity lets
        // it show through each terminal.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        window.contentView = glass

        grid.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: glass.safeAreaLayoutGuide.topAnchor),
            grid.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])

        super.init(window: window)
        window.delegate = self
        window.center()

        grid.onTitleChange = { [weak window] title in
            window?.title = title.isEmpty ? "ghostgrid" : title
        }
        grid.onEmpty = { [weak self] in self?.window?.close() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func windowWillClose(_: Notification) {
        onClose?(self)
    }
}
