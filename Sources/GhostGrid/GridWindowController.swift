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

    /// Ctrl+Tab and Ctrl+Shift+Tab (next and previous tab) do not reliably
    /// reach the menu as key equivalents: AppKit may take them for moving
    /// between views, and the terminal for Ghostty's own tab keys (which
    /// ghostgrid does not act on). The menu gets the first look.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48, event.modifierFlags.contains(.control),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        super.sendEvent(event)
    }
}

/// One tab: its own grid of panes, and the name and color you gave it.
@MainActor
final class WindowTab {
    /// Names the tab while it is dragged between windows.
    let id = UUID()
    let grid: GridView
    var name: String?
    var color: TabColor?
    /// When this tab last went to the background: its badge shows only
    /// what happened after. nil: it has not been in front yet.
    var lastSeen: Date?

    init(grid: GridView) {
        self.grid = grid
    }
}

/// A ghostgrid window: tabs (TabStrip), each a grid of panes, with the tab
/// bar in the titlebar once there is more than one tab (or the only one has
/// a name or color). Only the tab in front is shown.
@MainActor
final class GridWindowController: NSWindowController, NSWindowDelegate {
    private let controllerFor: ControllerProvider
    private(set) var tabs = TabStrip<WindowTab>([])
    private let gridArea = NSView()
    private let tabBar = TabBarView()
    private var gridTop: NSLayoutConstraint!
    private var barHeight: NSLayoutConstraint!
    private var barLeading: NSLayoutConstraint!
    /// A tab is being renamed: the bar stays visible meanwhile.
    private var renaming = false
    /// A tab or pane is being dragged somewhere: every window shows its bar
    /// so it can be dropped on any of them.
    private var showingBarForDrag = false

    var onClose: ((GridWindowController) -> Void)?
    /// The window, its tabs or a grid changed in a way worth saving.
    var onChange: (() -> Void)?
    /// Every window, front to back (where dragged tabs and panes can go).
    var allWindows: (() -> [GridWindowController])?
    /// A tab was dragged out of every tab bar and dropped at a screen point:
    /// it moves to a new window there.
    var onTearOff: ((GridWindowController, Int, NSPoint?) -> Void)?

    /// The grid of the tab in front (nil only while the window has no tab).
    var grid: GridView? { tabs.selectedTab?.grid }

    init(controllerFor: @escaping ControllerProvider) {
        self.controllerFor = controllerFor
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

        gridArea.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(gridArea)
        glass.addSubview(tabBar)
        gridTop = gridArea.topAnchor.constraint(equalTo: glass.safeAreaLayoutGuide.topAnchor)
        barHeight = tabBar.heightAnchor.constraint(equalToConstant: 28)
        barLeading = tabBar.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 80)
        NSLayoutConstraint.activate([
            gridTop,
            gridArea.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            gridArea.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            gridArea.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            tabBar.bottomAnchor.constraint(equalTo: gridArea.topAnchor),
            tabBar.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -8),
            barHeight,
            barLeading,
        ])

        super.init(window: window)
        window.delegate = self
        window.center()
        wireTabBar()
        updateChrome()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Tabs

    /// Opens a tab right after the one in front and brings it to the front,
    /// starting one pane in `directory` (default: the folder of the pane you
    /// were in). With `chooseShell`, the pane shows the shell menu.
    func addTab(chooseShell: Bool = false, directory: String? = nil) {
        let folder = directory ?? grid?.focused?.workingDirectory
        let tab = makeTab()
        tabs.add(tab)
        showSelected()
        tab.grid.addPane(chooseShell: chooseShell, directory: folder)
        tabsChanged()
    }

    func select(at index: Int) {
        guard index != tabs.selected || !(tabs.selectedTab?.grid.isShowing ?? false) else { return }
        tabs.select(at: index)
        showSelected()
        onChange?()
    }

    /// Cmd+1...8: that tab; Cmd+9: the last.
    func select(number: Int) {
        let before = tabs.selected
        tabs.select(number: number)
        if tabs.selected != before { showSelected(); onChange?() }
    }

    func selectNext(_ step: Int) {
        guard tabs.count > 1 else { return }
        tabs.selectNext(step)
        showSelected()
        onChange?()
    }

    func moveTab(from: Int, to: Int) {
        tabs.move(from: from, to: to)
        tabsChanged()
    }

    /// Closes a tab and ends its shells; the last tab closes the window.
    func closeTab(at index: Int) {
        removeTab(at: index, endShells: true)
    }

    func closeOtherTabs(keeping index: Int) {
        guard let keep = tabs.tabs.indices.contains(index) ? tabs.tabs[index] : nil else { return }
        for other in tabs.tabs.reversed() where other !== keep {
            if let position = tabs.tabs.firstIndex(where: { $0 === other }) { removeTab(at: position, endShells: true) }
        }
    }

    func beginRename(at index: Int) {
        renaming = true
        updateChrome()
        window?.contentView?.layoutSubtreeIfNeeded()
        tabBar.beginRename(at: index)
    }

    func setColor(_ color: TabColor?, at index: Int) {
        guard tabs.tabs.indices.contains(index) else { return }
        tabs.tabs[index].color = color
        tabsChanged()
    }

    /// The tab in front's color (Tab > Tab Color shows it checked).
    var selectedColor: TabColor? { tabs.selectedTab?.color }

    /// Ends every tab's shells (the window is closing for good, or
    /// ghostgrid is quitting without keeping shells).
    func endAllShells() {
        tabs.tabs.forEach { $0.grid.endAllShells() }
    }

    private func makeTab() -> WindowTab {
        let grid = GridView(controllerFor: controllerFor)
        let tab = WindowTab(grid: grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        gridArea.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: gridArea.topAnchor),
            grid.leadingAnchor.constraint(equalTo: gridArea.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: gridArea.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: gridArea.bottomAnchor),
        ])
        grid.isShowing = false // until it is brought to the front
        window?.contentView?.layoutSubtreeIfNeeded()
        wire(tab)
        return tab
    }

    /// Points a tab's grid at this window (again, when it moved here).
    private func wire(_ tab: WindowTab) {
        let grid = tab.grid
        grid.onChange = { [weak self] in self?.onChange?() }
        // The tab's last pane closed (its shell already ended).
        grid.onEmpty = { [weak self, weak tab] in
            guard let self, let tab, let index = tabs.tabs.firstIndex(where: { $0 === tab }) else { return }
            removeTab(at: index, endShells: false)
        }
        grid.onTitleChange = { [weak self, weak tab] _ in
            if let self, tab === tabs.selectedTab { updateTitle() }
        }
        grid.onBroadcastChange = { [weak self, weak tab] _ in
            if let self, tab === tabs.selectedTab { updateTitle() }
        }
        grid.onActivityChange = { [weak self] in self?.refreshBar() }
        grid.onPaneDragOver = { [weak self, weak tab] _, point in
            guard let self, let tab else { return false }
            return paneDragOver(from: tab, at: point)
        }
        grid.onPaneDrop = { [weak self, weak tab] pane, point in
            guard let self, let tab else { return false }
            return paneDrop(pane, from: tab, at: point)
        }
    }

    // MARK: - Moving tabs and panes between tabs and windows

    /// Takes a tab out of this window, its shells still running, for another
    /// window to take in. The window stays open until `closeIfEmpty`.
    func detachTab(at index: Int) -> WindowTab? {
        guard let tab = tabs.close(at: index) else { return nil }
        tab.grid.removeFromSuperview()
        if !tabs.isEmpty {
            showSelected()
            tabsChanged()
        }
        return tab
    }

    /// Takes in a tab from another window at `index` and brings it to the
    /// front, with its window.
    func attachTab(_ tab: WindowTab, at index: Int) {
        tab.grid.translatesAutoresizingMaskIntoConstraints = false
        tab.grid.isShowing = false
        gridArea.addSubview(tab.grid)
        NSLayoutConstraint.activate([
            tab.grid.topAnchor.constraint(equalTo: gridArea.topAnchor),
            tab.grid.leadingAnchor.constraint(equalTo: gridArea.leadingAnchor),
            tab.grid.trailingAnchor.constraint(equalTo: gridArea.trailingAnchor),
            tab.grid.bottomAnchor.constraint(equalTo: gridArea.bottomAnchor),
        ])
        wire(tab)
        tabs.insert(tab, at: index)
        window?.contentView?.layoutSubtreeIfNeeded()
        showSelected()
        tabsChanged()
        window?.makeKeyAndOrderFront(nil)
    }

    /// A window whose last tab moved elsewhere closes, ending nothing (once
    /// its own tab drag, if any, is over).
    func closeIfEmpty() {
        if tabs.isEmpty, !tabBar.isDraggingOut { window?.close() }
    }

    /// A tab from any window dropped on this window's bar at `index`.
    private func acceptTab(id: UUID, at index: Int) {
        if let own = tabs.tabs.firstIndex(where: { $0.id == id }) {
            moveTab(from: own, to: min(index, tabs.count - 1))
            return
        }
        guard let source = allWindows?().first(where: { $0.tabs.tabs.contains { $0.id == id } }),
              let sourceIndex = source.tabs.tabs.firstIndex(where: { $0.id == id }),
              let tab = source.detachTab(at: sourceIndex)
        else { return }
        attachTab(tab, at: index)
        source.closeIfEmpty()
    }

    /// Tab > Move Tab to New Window.
    func moveSelectedTabToNewWindow() {
        onTearOff?(self, tabs.selected, nil)
    }

    /// The tab under a screen point in this window's bar, while it shows.
    private func tabIndex(atScreen point: NSPoint) -> Int? {
        guard let window, !tabBar.isHidden else { return nil }
        return tabBar.index(at: tabBar.convert(window.convertPoint(fromScreen: point), from: nil))
    }

    /// The tab (in any window) a pane dragged to `point` would move to; not
    /// the tab it is in.
    private func paneTarget(from tab: WindowTab, at point: NSPoint) -> (GridWindowController, WindowTab)? {
        for controller in allWindows?() ?? [self] {
            guard let index = controller.tabIndex(atScreen: point) else { continue }
            let target = controller.tabs.tabs[index]
            return target === tab ? nil : (controller, target)
        }
        return nil
    }

    private func paneDragOver(from tab: WindowTab, at point: NSPoint) -> Bool {
        let target = paneTarget(from: tab, at: point)
        for controller in allWindows?() ?? [self] {
            controller.showBarForDrag(true)
            let lit = controller === target?.0 ? target.flatMap { t in controller.tabs.tabs.firstIndex { $0 === t.1 } } : nil
            controller.tabBar.paneTarget = lit
        }
        return target != nil
    }

    /// A pane dropped by its header: onto a tab in some window's bar, it
    /// moves there (its shell still running) and that tab comes to the front.
    private func paneDrop(_ pane: PaneView, from tab: WindowTab, at point: NSPoint) -> Bool {
        let target = paneTarget(from: tab, at: point)
        for controller in allWindows?() ?? [self] {
            controller.tabBar.paneTarget = nil
            controller.showBarForDrag(false)
        }
        guard let (controller, destination) = target else { return false }
        // Out first: the tab (and window) it leaves may close, ending nothing.
        tab.grid.detach(pane)
        guard let index = controller.tabs.tabs.firstIndex(where: { $0 === destination }) else { return true }
        controller.tabs.select(at: index)
        controller.showSelected()
        destination.grid.adopt(pane)
        controller.tabsChanged()
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }

    /// Shows the bar while something is dragged (see showingBarForDrag).
    func showBarForDrag(_ show: Bool) {
        guard show != showingBarForDrag else { return }
        showingBarForDrag = show
        updateChrome()
    }

    private func removeTab(at index: Int, endShells: Bool) {
        guard let tab = tabs.close(at: index) else { return }
        if endShells { tab.grid.endAllShells() }
        tab.grid.removeFromSuperview()
        guard !tabs.isEmpty else {
            window?.close()
            return
        }
        showSelected()
        tabsChanged()
    }

    /// Shows the selected tab's grid and hides the others, giving the
    /// keyboard to its focused pane.
    private func showSelected() {
        let selected = tabs.selectedTab
        for tab in tabs.tabs where tab !== selected {
            if tab.grid.isShowing { tab.lastSeen = Date() }
            tab.grid.isShowing = false
        }
        guard let selected else { return }
        selected.grid.isShowing = true
        window?.contentView?.layoutSubtreeIfNeeded()
        selected.grid.focusCurrent()
        updateTitle()
        refreshBar()
    }

    private func tabsChanged() {
        updateChrome()
        refreshBar()
        onChange?()
    }

    // MARK: - Tab bar

    private func wireTabBar() {
        tabBar.onSelect = { [weak self] in self?.select(at: $0) }
        tabBar.onClose = { [weak self] in self?.closeTab(at: $0) }
        tabBar.onCloseOthers = { [weak self] in self?.closeOtherTabs(keeping: $0) }
        tabBar.onMove = { [weak self] in self?.moveTab(from: $0, to: $1) }
        tabBar.onColor = { [weak self] index, color in self?.setColor(color, at: index) }
        tabBar.onRename = { [weak self] index, name in
            guard let self else { return }
            if tabs.tabs.indices.contains(index) { tabs.tabs[index].name = name }
            finishRename()
        }
        tabBar.onRenameCancel = { [weak self] in self?.finishRename() }
        tabBar.onDropTab = { [weak self] id, index in self?.acceptTab(id: id, at: index) }
        tabBar.onTearOff = { [weak self] index, point in
            guard let self else { return }
            onTearOff?(self, index, point)
        }
        tabBar.onDragOutChange = { [weak self] dragging in
            guard let self else { return }
            for controller in allWindows?() ?? [self] { controller.showBarForDrag(dragging) }
            // Its last tab went to another window during the drag.
            if !dragging { closeIfEmpty() }
        }
    }

    private func finishRename() {
        renaming = false
        tabsChanged()
        grid?.focusCurrent()
    }

    private func refreshBar() {
        tabBar.items = tabs.tabs.enumerated().map { index, tab in
            let selected = index == tabs.selected
            return TabBarView.Item(
                id: tab.id, title: TabTitle.display(name: tab.name, position: index), name: tab.name, color: tab.color,
                selected: selected,
                badge: selected ? nil : TabActivity.badge(for: tab.grid.activities, since: tab.lastSeen),
            )
        }
    }

    /// The bar shows with two or more tabs (or a named or colored one, or
    /// while renaming), in the titlebar beside the traffic lights; in full
    /// screen, where there is no titlebar, above the panes.
    private func updateChrome() {
        guard let window else { return }
        let only = tabs.tabs.count == 1 ? tabs.tabs.first : nil
        let customized = only.map { $0.name != nil || $0.color != nil } ?? false
        let visible = renaming || (showingBarForDrag && !tabs.isEmpty)
            || TabBarLayout.shows(count: tabs.count, onlyTabCustomized: customized)
        tabBar.isHidden = !visible
        // The title would sit under the tabs.
        window.titleVisibility = visible ? .hidden : .visible
        let placed = TabBarPlacement.place(
            fullScreen: window.styleMask.contains(.fullScreen) || enteringFullScreen,
            titlebarHeight: window.frame.height - window.contentLayoutRect.height,
            buttonsMaxX: window.standardWindowButton(.zoomButton)?.frame.maxX ?? 68,
            visible: visible,
        )
        barHeight.constant = placed.barHeight
        gridTop.constant = placed.gridTop
        barLeading.constant = placed.leading
    }

    private func updateTitle() {
        let title = grid?.title ?? ""
        let base = title.isEmpty ? "ghostgrid" : title
        window?.title = grid?.broadcasting == true ? "BROADCAST: " + base : base
    }

    // MARK: - Session

    /// This window as saved: its frame, and each tab's name, color and grid.
    func snapshot() -> Session.Window? {
        guard let window else { return nil }
        let saved = tabs.tabs.map { tab in
            var saved = tab.grid.snapshot()
            saved.name = tab.name
            saved.color = tab.color
            return saved
        }
        return Session.Window(frame: window.frame, tabs: saved, selectedTab: tabs.selected)
    }

    /// Rebuilds a saved window's tabs, without animation.
    func restore(_ saved: Session.Window) {
        for savedTab in saved.tabs {
            let tab = makeTab()
            tab.name = savedTab.name
            tab.color = savedTab.color
            tabs.add(tab)
            tab.grid.restore(savedTab)
        }
        tabs.select(at: saved.selectedTab ?? 0)
        showSelected()
        tabsChanged()
    }

    // MARK: - Window

    func windowDidMove(_: Notification) { onChange?() }
    func windowDidResize(_: Notification) { onChange?() }
    /// Set from the moment full screen is requested, so the bar is already
    /// in place while the window animates into it.
    private var enteringFullScreen = false

    func windowWillEnterFullScreen(_: Notification) {
        enteringFullScreen = true
        updateChrome()
    }

    func windowDidEnterFullScreen(_: Notification) {
        enteringFullScreen = false
        updateChrome()
    }

    func windowDidFailToEnterFullScreen(_: NSWindow) {
        enteringFullScreen = false
        updateChrome()
    }

    func windowDidExitFullScreen(_: Notification) { updateChrome() }

    func windowWillClose(_: Notification) {
        onClose?(self)
    }
}
