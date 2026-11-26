import AppKit
import GhostGridCore

/// The slim bar at the top of a pane: shell, folder, git branch, and on
/// the right the activity badge (Settings > Panes).
@MainActor
final class PaneHeaderView: NSView {
    static let height: CGFloat = 24

    private let shellLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let branchIcon = NSImageView()
    private let branchLabel = NSTextField(labelWithString: "")
    let badge = ActivityBadgeView()

    var isFocused = false { didSet { restyle() } }

    enum DragPhase { case began, moved, ended }
    /// A click on the header (focuses the pane).
    var onPress: (() -> Void)?
    /// Dragging the header, in window coordinates (swaps panes on drop).
    var onDrag: ((DragPhase, NSPoint) -> Void)?
    private var pressAt: NSPoint?
    private var isDragging = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.card.withAlphaComponent(0.85).cgColor
        let divider = CALayer()
        divider.backgroundColor = Palette.idle.cgColor
        divider.name = "divider"
        layer?.addSublayer(divider)

        for label in [shellLabel, pathLabel, branchLabel] {
            label.font = Palette.mono(11)
            label.lineBreakMode = .byTruncatingHead
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        shellLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch")
        branchIcon.symbolConfiguration = .init(pointSize: 10, weight: .medium)

        let left = NSStackView(views: [shellLabel, pathLabel, branchIcon, branchLabel])
        left.spacing = 6
        left.setCustomSpacing(3, after: branchIcon)
        let row = NSStackView(views: [left, NSView(), badge])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressAt = event.locationInWindow
        isDragging = false
        onPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressAt else { return }
        let point = event.locationInWindow
        if !isDragging {
            // A few points of travel before a click becomes a drag.
            guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
            isDragging = true
            NSCursor.closedHand.push()
            onDrag?(.began, start)
        }
        onDrag?(.moved, point)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            NSCursor.pop()
            onDrag?(.ended, event.locationInWindow)
        }
        pressAt = nil
        isDragging = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func layout() {
        super.layout()
        layer?.sublayers?.first { $0.name == "divider" }?.frame =
            CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    func update(shell: String?, directory: String?, branch: String?) {
        shellLabel.stringValue = shell ?? "new pane"
        pathLabel.stringValue = directory.map { PathDisplay.short($0, home: NSHomeDirectory()) } ?? ""
        branchLabel.stringValue = branch ?? ""
        branchIcon.isHidden = branch == nil
        branchLabel.isHidden = branch == nil
    }

    private func restyle() {
        shellLabel.textColor = isFocused ? Palette.focus : Palette.subtext
        pathLabel.textColor = isFocused ? Palette.text : Palette.subtext
        branchLabel.textColor = Palette.subtext
        branchIcon.contentTintColor = Palette.subtext
    }
}

/// A small pill for something that happened in a pane you were not
/// looking at: a bell, or a long command finishing (green) or failing (red).
@MainActor
final class ActivityBadgeView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    var activity: PaneActivity? {
        didSet {
            guard activity != oldValue else { return }
            render()
            if activity != nil, oldValue == nil { pop() }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        icon.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func render() {
        isHidden = activity == nil
        guard let activity else { return }
        let (symbol, color): (String, NSColor) = switch activity {
        case .bell: ("bell.fill", Palette.bell)
        case .finished where activity.failed: ("xmark", Palette.failure)
        case .finished: ("checkmark", Palette.success)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: activity.label)
        icon.contentTintColor = Palette.card
        label.stringValue = activity.label
        label.textColor = Palette.card
        layer?.backgroundColor = color.cgColor
    }

    /// A quick grow-and-settle so a new badge catches the eye.
    private func pop() {
        guard let layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [0.6, 1.15, 1]
        animation.keyTimes = [0, 0.6, 1]
        animation.duration = 0.3
        layer.add(animation, forKey: "ghostgrid.badge.pop")
    }
}
