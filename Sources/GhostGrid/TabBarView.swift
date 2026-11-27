import AppKit
import GhostGridCore

/// The tabs along the top of a window, in the titlebar beside the traffic
/// lights. Click a tab to show it, double-click to rename it, drag it along
/// the bar to move it, right-click for its color and more. Tabs share the
/// bar's width (TabBarLayout); when they no longer fit, the bar scrolls.
/// Empty space in the bar still drags (and double-click zooms) the window.
@MainActor
final class TabBarView: NSView, NSTextFieldDelegate {
    struct Item: Equatable {
        var title: String
        /// The name you gave the tab (what renaming starts from).
        var name: String?
        var color: TabColor?
        var selected: Bool
        /// What happened in the tab while it was in the background.
        var badge: PaneActivity?
    }

    static let layout = TabBarLayout(minimumWidth: 96, maximumWidth: 220, spacing: 4)

    var items: [Item] = [] {
        didSet { if items != oldValue { sync() } }
    }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onCloseOthers: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    /// A rename finished: the tab and its new name (nil: back to "Tab N").
    var onRename: ((Int, String?) -> Void)?
    /// A rename was cancelled (Escape).
    var onRenameCancel: (() -> Void)?
    var onColor: ((Int, TabColor?) -> Void)?

    private var views: [TabItemView] = []
    /// How far the tabs are scrolled, when they are wider than the bar.
    private var scroll: CGFloat = 0
    /// A press on a tab, and once it moved far enough, the drag.
    private var press: (index: Int, x: CGFloat)?
    private var drag: (index: Int, grab: CGFloat, target: Int)?
    private var editor: NSTextField?
    private var editing: Int?
    private var cancelled = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Only the tabs take clicks; the rest of the bar falls through to the
    /// titlebar, which drags and zooms the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        if let editor, editor.frame.contains(local) { return super.hitTest(point) }
        guard views.contains(where: { $0.frame.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Items

    private func sync() {
        while views.count < items.count {
            let view = TabItemView()
            view.bar = self
            addSubview(view)
            views.append(view)
        }
        while views.count > items.count {
            views.removeLast().removeFromSuperview()
        }
        for (index, view) in views.enumerated() {
            view.index = index
            view.item = items[index]
        }
        if let editing, !items.indices.contains(editing) { endRename(commit: false) }
        revealSelected()
        needsLayout = true
    }

    private var contentWidth: CGFloat {
        Self.layout.contentWidth(count: views.count, width: bounds.width)
    }

    /// Scrolls just enough to show the selected tab.
    private func revealSelected() {
        guard let index = items.firstIndex(where: \.selected) else { return }
        let slot = Self.layout.frames(count: items.count, width: bounds.width)[index]
        if slot.minX < scroll { scroll = slot.minX }
        if slot.minX + slot.width > scroll + bounds.width { scroll = slot.minX + slot.width - bounds.width }
    }

    override func layout() {
        super.layout()
        scroll = min(max(scroll, 0), max(0, contentWidth - bounds.width))
        place(animated: false)
    }

    private func itemFrame(_ slot: TabBarLayout.Slot) -> CGRect {
        let height = min(bounds.height - 6, 24)
        return CGRect(x: slot.minX - scroll, y: ((bounds.height - height) / 2).rounded(), width: slot.width, height: height)
    }

    /// Puts each tab in its slot; while one is dragged, the others make
    /// room where it would land.
    private func place(animated: Bool) {
        let slots = Self.layout.frames(count: views.count, width: bounds.width)
        var order = Array(views.indices)
        if let drag {
            order.remove(at: drag.index)
            order.insert(drag.index, at: drag.target)
        }
        let update = {
            for (slot, index) in zip(slots, order) where index != self.drag?.index {
                let view = self.views[index]
                (animated ? view.animator() : view).frame = self.itemFrame(slot)
            }
            if let editing = self.editing, let editor = self.editor, self.views.indices.contains(editing) {
                editor.frame = self.views[editing].frame.insetBy(dx: 8, dy: 3)
            }
        }
        guard animated else { return update() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            update()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard contentWidth > bounds.width else { return super.scrollWheel(with: event) }
        let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        scroll -= delta
        needsLayout = true
    }

    // MARK: - Clicking and dragging tabs

    fileprivate func itemDown(_ view: TabItemView, _ event: NSEvent) {
        if event.clickCount == 2 {
            beginRename(at: view.index)
            return
        }
        press = (view.index, convert(event.locationInWindow, from: nil).x)
        onSelect?(view.index)
    }

    fileprivate func itemDragged(_ view: TabItemView, _ event: NSEvent) {
        guard let press, views.indices.contains(press.index) else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if drag == nil {
            // A few points of travel before a click becomes a drag.
            guard abs(x - press.x) > 4, views.count > 1 else { return }
            drag = (press.index, press.x - views[press.index].frame.minX, press.index)
            addSubview(views[press.index], positioned: .above, relativeTo: nil)
            NSCursor.closedHand.push()
        }
        guard var drag else { return }
        let dragged = views[drag.index]
        let minX = min(max(x - drag.grab, -dragged.frame.width / 2), bounds.width - dragged.frame.width / 2)
        dragged.setFrameOrigin(NSPoint(x: minX, y: dragged.frame.minY))
        let target = Self.layout.dropIndex(forMiddle: minX + dragged.frame.width / 2 + scroll, count: views.count,
                                           width: bounds.width)
        if target != drag.target {
            drag.target = target
            self.drag = drag
            place(animated: true)
        }
    }

    fileprivate func itemUp(_: TabItemView, _: NSEvent) {
        press = nil
        guard let drag else { return }
        self.drag = nil
        NSCursor.pop()
        if drag.target != drag.index {
            onMove?(drag.index, drag.target)
        }
        place(animated: true)
    }

    fileprivate func closeClicked(_ view: TabItemView) {
        onClose?(view.index)
    }

    // MARK: - Context menu

    fileprivate func contextMenu(for view: TabItemView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(entry("Rename Tab...", #selector(menuRename(_:)), view.index))
        let colors = NSMenu()
        let none = entry("None", #selector(menuColor(_:)), view.index)
        none.tag = -1
        none.state = view.item.color == nil ? .on : .off
        colors.addItem(none)
        colors.addItem(.separator())
        for (offset, color) in TabColor.allCases.enumerated() {
            let item = entry(color.title, #selector(menuColor(_:)), view.index)
            item.tag = offset
            item.image = TabColorSwatch.image(for: color)
            item.state = view.item.color == color ? .on : .off
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Tab Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(.separator())
        menu.addItem(entry("Close Tab", #selector(menuClose(_:)), view.index))
        let others = entry("Close Other Tabs", #selector(menuCloseOthers(_:)), view.index)
        others.isEnabled = items.count > 1
        menu.addItem(others)
        return menu
    }

    private func entry(_ title: String, _ action: Selector, _ index: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = index
        return item
    }

    @objc private func menuRename(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        beginRename(at: index)
    }

    @objc private func menuColor(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onColor?(index, TabColor.allCases.indices.contains(sender.tag) ? TabColor.allCases[sender.tag] : nil)
    }

    @objc private func menuClose(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onClose?(index)
    }

    @objc private func menuCloseOthers(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        onCloseOthers?(index)
    }

    // MARK: - Renaming

    /// Edits the tab's name in place: Return keeps it, Escape cancels, an
    /// empty name goes back to "Tab N".
    func beginRename(at index: Int) {
        guard items.indices.contains(index) else { return }
        if editor != nil { endRename(commit: true) }
        layoutSubtreeIfNeeded()
        let field = NSTextField(string: items[index].name ?? "")
        field.placeholderString = TabTitle.display(name: nil, position: index)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.alignment = .center
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = Palette.card
        field.textColor = Palette.text
        field.delegate = self
        field.frame = views[index].frame.insetBy(dx: 8, dy: 3)
        addSubview(field, positioned: .above, relativeTo: nil)
        editor = field
        editing = index
        cancelled = false
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endRename(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_: Notification) {
        endRename(commit: !cancelled)
    }

    private func endRename(commit: Bool) {
        guard let field = editor, let index = editing else { return }
        cancelled = !commit
        editor = nil
        editing = nil
        field.delegate = nil
        field.removeFromSuperview()
        if commit, items.indices.contains(index) {
            onRename?(index, TabTitle.normalized(field.stringValue))
        } else {
            onRenameCancel?()
        }
    }
}

/// One tab in the bar: its title, color, badge, and a close button that
/// shows on hover (and on the tab in front).
@MainActor
final class TabItemView: NSView {
    fileprivate weak var bar: TabBarView?
    fileprivate var index = 0
    var item = TabBarView.Item(title: "", selected: false) {
        didSet { if item != oldValue { restyle() } }
    }

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let badge = ActivityBadgeView()
    private var hovering = false {
        didSet { if hovering != oldValue { restyle() } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        for view in [label, closeButton, badge] as [NSView] { addSubview(view) }
        restyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        closeButton.frame = CGRect(x: 6, y: (bounds.height - side) / 2, width: side, height: side)
        let badgeSize = badge.fittingSize
        badge.frame = CGRect(x: bounds.width - badgeSize.width - 6, y: (bounds.height - badgeSize.height) / 2,
                             width: badgeSize.width, height: badgeSize.height)
        let inset: CGFloat = 24
        let height = label.fittingSize.height
        label.frame = CGRect(x: inset, y: (bounds.height - height) / 2, width: max(bounds.width - inset * 2, 0), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with _: NSEvent) { hovering = true }
    override func mouseExited(with _: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) { bar?.itemDown(self, event) }
    override func mouseDragged(with event: NSEvent) { bar?.itemDragged(self, event) }
    override func mouseUp(with event: NSEvent) { bar?.itemUp(self, event) }
    override func menu(for _: NSEvent) -> NSMenu? { bar?.contextMenu(for: self) }

    /// A middle click closes the tab, as in browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { bar?.closeClicked(self) } else { super.otherMouseUp(with: event) }
    }

    @objc private func closeClicked() { bar?.closeClicked(self) }

    private func restyle() {
        label.stringValue = item.title
        toolTip = item.title
        let tint = item.color.map { NSColor(tab: $0) }
        let background: NSColor
        let text: NSColor
        switch (tint, item.selected) {
        case let (tint?, true):
            background = tint.withAlphaComponent(0.9)
            text = Palette.card
        case let (tint?, false):
            background = tint.withAlphaComponent(hovering ? 0.42 : 0.28)
            text = Palette.text
        case (nil, true):
            background = Palette.overlay.withAlphaComponent(0.55)
            text = Palette.text
        case (nil, false):
            background = hovering ? Palette.overlay.withAlphaComponent(0.25) : .clear
            text = Palette.subtext
        }
        layer?.backgroundColor = background.cgColor
        label.textColor = text
        closeButton.contentTintColor = text
        closeButton.isHidden = !(hovering || item.selected)
        badge.activity = item.selected ? nil : item.badge
        badge.isHidden = item.selected || item.badge == nil
        needsLayout = true
    }
}
