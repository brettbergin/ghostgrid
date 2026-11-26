import AppKit

/// The search bar a pane shows for Ghostty's scrollback search (Cmd+F).
/// Typing searches as you go; Return / Shift+Return step to the next /
/// previous match; Escape (or the x) ends the search.
@MainActor
final class SearchBarView: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let close = NSButton()

    var onChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    var text: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            onChange?(newValue)
        }
    }

    var total: Int? { didSet { updateCount() } }
    var selected: Int? { didSet { updateCount() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.card.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Palette.focus.withAlphaComponent(0.6).cgColor

        field.placeholderString = "Search"
        field.font = Palette.mono(13)
        field.textColor = Palette.text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = Palette.subtext

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "End search")
        close.isBordered = false
        close.contentTintColor = Palette.subtext
        close.target = self
        close.action = #selector(closeClicked)

        let stack = NSStackView(views: [field, count, close])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        updateCount()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func closeClicked() {
        onClose?()
    }

    private func updateCount() {
        switch (selected, total) {
        case let (selected?, total?): count.stringValue = "\(selected + 1)/\(total)"
        case let (nil, total?): count.stringValue = "\(total)"
        default: count.stringValue = ""
        }
    }

    func controlTextDidChange(_: Notification) {
        onChange?(field.stringValue)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
