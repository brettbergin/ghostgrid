import AppKit
import GhostGridCore

/// The menu a new pane shows before it starts a shell.
/// Keys: the number picks that shell at once; Up/Down and Return pick the
/// highlighted one; Escape cancels (the pane closes). Clicking a row works too.
@MainActor
final class ShellPickerView: NSView {
    var onPick: ((ShellChoice) -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: (() -> Void)?

    private let choices: [ShellChoice]
    private var selected: Int
    private var rows: [RowView] = []
    private let card = NSView()

    /// `preferred` (the remembered shell) starts highlighted, so Return
    /// picks it again.
    init(choices: [ShellChoice], preferred: ShellChoice? = nil) {
        self.choices = choices
        selected = preferred.flatMap { choices.firstIndex(of: $0) }
            ?? choices.firstIndex(where: \.isInstalled) ?? 0
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
            onCancel?()
        case 36, 76: // return, keypad enter
            pick(selected)
        case 126: // up
            move(-1)
        case 125: // down
            move(1)
        default:
            let key = event.charactersIgnoringModifiers ?? ""
            if let choice = ShellCatalog.choice(forKey: key, in: choices),
               let index = choices.firstIndex(of: choice)
            {
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
        let installed = choices.indices.filter { choices[$0].isInstalled }
        guard let position = installed.firstIndex(of: selected), !installed.isEmpty else { return }
        selected = installed[(position + step + installed.count) % installed.count]
        render()
    }

    private func pick(_ index: Int) {
        guard choices.indices.contains(index), choices[index].isInstalled else {
            NSSound.beep()
            return
        }
        selected = index
        render()
        onPick?(choices[index])
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

        let title = label("New pane: pick a shell", size: 13, color: Palette.subtext)
        let hint = label("1-\(choices.count) to choose   up/down + return   esc to cancel",
                         size: 11, color: Palette.overlay)
        rows = choices.map { RowView(choice: $0, font: Palette.mono(14)) }

        let stack = NSStackView(views: [title] + rows + [hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: title)
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

/// One line of the menu: hotkey, name, and the path (or "not installed").
@MainActor
private final class RowView: NSView {
    private let choice: ShellChoice
    private let text = NSTextField(labelWithString: "")

    var isSelected = false {
        didSet { update() }
    }

    init(choice: ShellChoice, font: NSFont) {
        self.choice = choice
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
        let installed = choice.isInstalled
        let string = NSMutableAttributedString()
        func add(_ part: String, _ color: NSColor) {
            string.append(NSAttributedString(string: part, attributes: [.foregroundColor: color, .font: text.font!]))
        }
        add(" \(choice.hotkey) ", installed ? Palette.focus : Palette.overlay)
        add(" \(choice.name.padding(toLength: 9, withPad: " ", startingAt: 0))", installed ? Palette.text : Palette.overlay)
        add(" \(choice.executable ?? "not installed")", installed ? Palette.subtext : Palette.overlay)
        text.attributedStringValue = string
        layer?.backgroundColor = (isSelected && installed ? Palette.focus.withAlphaComponent(0.18) : .clear).cgColor
    }
}
