import AppKit
import GhostGridCore

/// One line of a pane menu.
struct MenuItem {
    let hotkey: String
    let name: String
    /// Shown dimmed after the name (a path, a description).
    let detail: String
    let isEnabled: Bool
}

extension MenuItem {
    init(_ shell: ShellChoice) {
        self.init(hotkey: shell.hotkey, name: shell.name,
                  detail: shell.executable ?? "not installed", isEnabled: shell.isInstalled)
    }

    /// Launcher apps stay pickable when their program is not found: the
    /// command may be an alias or a function (Settings > zsh app launcher).
    init(_ app: LaunchApp) {
        let detail = app.isFound ? app.summary : [app.summary, "(not found)"].filter { !$0.isEmpty }.joined(separator: " ")
        self.init(hotkey: app.hotkey, name: app.name, detail: detail, isEnabled: true)
    }
}

/// The menu card a pane shows before it starts: the shell menu, then for
/// zsh (on Cmd+Shift+T) the app menu.
/// Keys: a number picks that item at once; Up/Down and Return pick the
/// highlighted one; Escape calls onEscape. Clicking a row works too.
@MainActor
final class ChoiceMenuView: NSView {
    var onPick: ((Int) -> Void)?
    var onEscape: (() -> Void)?
    var onFocus: (() -> Void)?

    private let items: [MenuItem]
    private let title: String
    private let hint: String
    private var selected: Int
    private var rows: [RowView] = []
    private let card = NSView()

    init(title: String, hint: String, items: [MenuItem], selected: Int? = nil) {
        self.title = title
        self.hint = hint
        self.items = items
        self.selected = selected.flatMap { items.indices.contains($0) && items[$0].isEnabled ? $0 : nil }
            ?? items.firstIndex(where: \.isEnabled) ?? 0
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.paneBackground.cgColor
        buildCard()
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return true
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // escape
            onEscape?()
        case 36, 76: // return, keypad enter
            pick(selected)
        case 126: // up
            move(-1)
        case 125: // down
            move(1)
        default:
            let key = event.charactersIgnoringModifiers ?? ""
            if let index = items.firstIndex(where: { $0.hotkey == key && $0.isEnabled }) {
                pick(index)
            } else {
                NSSound.beep()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let index = rows.firstIndex(where: { $0.convert($0.bounds, to: self).contains(point) }) {
            pick(index)
        }
    }

    private func move(_ step: Int) {
        let enabled = items.indices.filter { items[$0].isEnabled }
        guard let position = enabled.firstIndex(of: selected), !enabled.isEmpty else { return }
        selected = enabled[(position + step + enabled.count) % enabled.count]
        render()
    }

    private func pick(_ index: Int) {
        guard items.indices.contains(index), items[index].isEnabled else {
            NSSound.beep()
            return
        }
        selected = index
        render()
        onPick?(index)
    }

    // MARK: - Drawing

    private func buildCard() {
        card.wantsLayer = true
        card.layer?.backgroundColor = Palette.card.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.idle.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let titleLabel = label(title, size: 13, color: Palette.subtext)
        let hintLabel = label(hint, size: 11, color: Palette.overlay)
        rows = items.map { RowView(item: $0, font: Palette.mono(14)) }

        let stack = NSStackView(views: [titleLabel] + rows + [hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: titleLabel)
        if let last = rows.last { stack.setCustomSpacing(12, after: last) }
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ] + rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32) })
    }

    private func render() {
        for (index, row) in rows.enumerated() {
            row.isSelected = index == selected
        }
    }

    private func label(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: .medium)
        field.textColor = color
        return field
    }
}

/// One line of the menu: hotkey, name, and detail.
@MainActor
private final class RowView: NSView {
    private let item: MenuItem
    private let text = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet { update() }
    }

    init(item: MenuItem, font: NSFont) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        text.font = font
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        update()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func update() {
        let enabled = item.isEnabled
        let string = NSMutableAttributedString()
        func add(_ part: String, _ color: NSColor) {
            string.append(NSAttributedString(string: part, attributes: [.foregroundColor: color, .font: text.font!]))
        }
        add(" \(item.hotkey) ", enabled ? Palette.focus : Palette.overlay)
        add(" \(item.name.padding(toLength: 9, withPad: " ", startingAt: 0))", enabled ? Palette.text : Palette.overlay)
        add(" \(item.detail)", enabled ? Palette.subtext : Palette.overlay)
        text.attributedStringValue = string
        layer?.backgroundColor = (isSelected && enabled ? Palette.focus.withAlphaComponent(0.18) : .clear).cgColor
    }
}
