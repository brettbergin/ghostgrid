// One ghostgrid window: its title bar (app menu, tab bar, window buttons),
// its tabs (each a TabGrid) and every command with a shortcut. It sends its
// state to the app process after each change, which saves the session.
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { UserAttentionType } from "@tauri-apps/api/window";
import { reencodeForTarget, broadcastTargets } from "../core/broadcast";
import { bindings, describe, matchKey, type Command } from "../core/keymap";
import { layoutModes, layoutTitle } from "../core/gridLayout";
import { activityFailed, activityLabel } from "../core/paneActivity";
import { normalizedTabName, TabStrip, tabBadgeSince, tabColors, tabColorTitle, tabTitle, TAB_COLORS } from "../core/tabs";
import { api, on, type InitData, type SavedPane, type SavedTab, type SavedWindow, type Settings, type ShellChoice, type TerminalConfig } from "../ipc";
import { BlocksPanel } from "./blocks";
import { debounce, h, ICONS, svgIcon } from "./dom";
import { TabGrid, type GridHost } from "./grid";
import { closeMenus, showMenu, type MenuItem } from "./menu";
import type { PaneHost, PaneView, StartSpec } from "./pane";
import { SettingsPanel } from "./settings";
import { TabBar } from "./tabBar";
import { applyChrome } from "./theme";

const appWindow = getCurrentWebviewWindow();

export class WindowController implements GridHost {
  private tabs = new TabStrip<TabGrid>([]);
  private tabBar: TabBar;
  private gridArea: HTMLDivElement;
  private banner: HTMLDivElement;
  private maximizeButton: HTMLButtonElement;
  private settings: Settings;
  private config: TerminalConfig;
  private shellList: ShellChoice[];
  private blocks: BlocksPanel | null = null;
  private settingsPanel: SettingsPanel | null = null;
  private closing = false;
  private paneHosts = new Map<TabGrid, PaneHost>();
  private save = debounce(() => void this.saveNow(), 250);

  constructor(private root: HTMLElement, private data: InitData) {
    this.settings = data.settings;
    this.config = data.config;
    this.shellList = data.shells;
    applyChrome(this.config.settings);

    this.tabBar = new TabBar({
      select: (i) => this.selectTab(i),
      close: (i) => this.closeTab(i),
      rename: (i, name) => this.renameTab(i, name),
      contextMenu: (i, e) => this.tabMenu(i, e.clientX, e.clientY),
      move: (from, to) => {
        this.tabs.move(from, to);
        this.refresh();
      },
      tearOff: (i, e) => void this.tearOffTab(i, e),
      newTab: () => this.run("newTab"),
    });
    const menuButton = h("button", { class: "title-button app-menu", title: "Menu" }, svgIcon(ICONS.menu));
    menuButton.addEventListener("click", (e) => {
      const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
      showMenu(this.appMenu(), r.left, r.bottom + 2);
    });
    this.maximizeButton = h("button", { class: "title-button", title: "Maximize", onclick: () => void appWindow.toggleMaximize() }, svgIcon(ICONS.maximize));
    const titlebar = h(
      "div",
      { class: "titlebar" },
      menuButton,
      this.tabBar.el,
      h("div", { class: "drag-region", "data-tauri-drag-region": true }),
      h("div", { class: "window-buttons" },
        h("button", { class: "title-button", title: "Minimize", onclick: () => void appWindow.minimize() }, svgIcon(ICONS.minimize)),
        this.maximizeButton,
        h("button", { class: "title-button close", title: "Close window", onclick: () => void api.windowClose() }, svgIcon(ICONS.close)),
      ),
    );
    titlebar.addEventListener("dblclick", (e) => {
      if ((e.target as HTMLElement).classList.contains("drag-region")) void appWindow.toggleMaximize();
    });
    this.gridArea = h("div", { class: "grid-area" });
    this.banner = h("div", { class: "banner hidden" });
    root.append(titlebar, this.banner, this.gridArea);

    window.addEventListener("keydown", (e) => this.keydown(e), true);
    window.addEventListener("focus", () => this.windowFocused());
    window.addEventListener("blur", () => this.refresh());
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => this.applyConfig(this.config));
    void appWindow.onResized(() => {
      void appWindow.isMaximized().then((max) => {
        this.root.classList.toggle("maximized", max);
        this.maximizeButton.replaceChildren(svgIcon(max ? ICONS.restore : ICONS.maximize));
      });
      this.save();
    });
    void appWindow.onMoved(() => this.save());

    void on<Settings>("settings-changed", (s) => this.applySettings(s));
    void on<TerminalConfig>("config-changed", (c) => this.applyConfig(c));
    void on<string[]>("open-dirs", (dirs) => this.openDirs(dirs));
    void on<{ id: number; kind: "tab" | "pane"; x: number; y: number }>("drop-query", (q) => this.answerDrop(q));
    void on<{ kind: "tab" | "pane"; payload: SavedTab | SavedPane; index: number }>("adopt", (a) => this.adopt(a));
    void on<{ version: string; notes: string | null }>("update-available", (u) => this.showUpdate(u.version));

    setInterval(() => this.tickAttention(), 1000);
    this.start();
  }

  private start() {
    const restore = this.data.init.restore;
    if (restore && restore.tabs.length > 0) {
      for (const saved of restore.tabs) {
        const grid = this.makeGrid();
        this.tabs.insert(grid, this.tabs.count);
        grid.restore(saved);
      }
      this.tabs.select(restore.selectedTab ?? 0);
    }
    if (this.data.init.openDirs.length > 0) {
      this.openDirs(this.data.init.openDirs);
    } else if (this.tabs.isEmpty) {
      this.newTab(false, null);
    }
    this.refresh();
    void appWindow.show().then(() => appWindow.setFocus());
  }

  // ---- hosts ------------------------------------------------------------------

  private makeGrid(): TabGrid {
    const grid = new TabGrid(this, this.settings.defaultLayout);
    this.gridArea.append(grid.el);
    grid.show(false);
    return grid;
  }

  paneHost(grid: TabGrid): PaneHost {
    let host = this.paneHosts.get(grid);
    if (host) return host;
    host = {
      settings: () => this.settings,
      config: () => this.config,
      shells: () => this.shellList,
      osBuild: this.data.osBuild,
      isLookedAt: (pane) => document.hasFocus() && this.tabs.selectedTab === grid && grid.focusedPane === pane,
      focusPane: (pane) => grid.focusPane(pane),
      closePane: (pane, terminate) => grid.removePane(pane, terminate),
      paneChanged: () => this.refresh(),
      input: (pane, data) => this.input(grid, pane, data),
      rememberShell: (name) => {
        if (this.settings.lastShell !== name) void api.setSettings({ ...this.settings, lastShell: name });
      },
      headerPointerDown: (pane, e) => grid.headerPointerDown(pane, e),
      contextMenu: (pane, e) => this.paneMenu(grid, pane, e.clientX, e.clientY),
      attention: (pane) => {
        if (!document.hasFocus()) void appWindow.requestUserAttention(UserAttentionType.Informational);
        void pane;
        this.refresh();
      },
      broadcasting: () => grid.broadcast,
    };
    this.paneHosts.set(grid, host);
    return host;
  }

  gridChanged() {
    this.refresh();
  }

  attentionEnabled(): boolean {
    return this.settings.attentionGrid;
  }

  emptied(grid: TabGrid) {
    const index = this.tabs.tabs.indexOf(grid);
    if (index >= 0) this.removeTab(index, false);
  }

  paneDragMoved(_grid: TabGrid, e: PointerEvent | null) {
    this.tabBar.highlight(e ? this.tabBar.tabAt(e.clientX, e.clientY) : null);
  }

  /** A pane let go over a tab of this window's bar moves into that tab; let
   * go outside the window, it moves to the tab under the pointer in
   * another window. */
  async paneDropped(grid: TabGrid, pane: PaneView, e: PointerEvent): Promise<boolean> {
    const tab = this.tabBar.tabAt(e.clientX, e.clientY);
    if (tab !== null) {
      const target = this.tabs.tabs[tab];
      if (target !== grid && grid.detachPane(pane)) {
        target.adoptPane(pane);
        // Emptying the source tab may have shifted the indices.
        this.selectTab(this.tabs.tabs.indexOf(target));
      }
      return true;
    }
    const inside = e.clientX >= 0 && e.clientY >= 0 && e.clientX <= window.innerWidth && e.clientY <= window.innerHeight;
    if (inside) return false;
    const found = await api.dropQuery("pane", e.screenX, e.screenY).catch(() => null);
    const saved = pane.saved();
    if (!found || !pane.sessionId || !saved) return true;
    grid.detachPane(pane);
    pane.dispose(false);
    await api.transfer(found.label, "pane", saved, found.index);
    return true;
  }

  // ---- tabs -------------------------------------------------------------------

  private newTab(chooseShell: boolean, cwd: string | null) {
    const grid = this.makeGrid();
    this.tabs.add(grid);
    this.refresh();
    grid.addPane(this.startSpec(chooseShell, cwd));
  }

  /** The last shell, unless Settings or the shortcut ask for the menu (or
   * it is no longer installed). */
  private startSpec(chooseShell: boolean, cwd: string | null): StartSpec {
    const last = this.settings.lastShell;
    const installed = this.shellList.find((s) => s.name === last && s.executable);
    if (!chooseShell && this.settings.newPaneUsesLastShell && installed) {
      return { kind: "shell", shell: installed.name, cwd };
    }
    return { kind: "menu", highlight: last ?? null, cwd };
  }

  private selectTab(index: number) {
    this.tabs.select(index);
    this.refresh();
  }

  private closeTab(index: number) {
    this.removeTab(index, true);
  }

  private removeTab(index: number, terminate: boolean) {
    const grid = this.tabs.tabs[index];
    if (!grid) return;
    this.tabs.close(index);
    this.paneHosts.delete(grid);
    grid.dispose(terminate);
    if (this.tabs.isEmpty) {
      this.closing = true;
      void this.saveNow().then(() => api.windowClose());
      return;
    }
    this.refresh();
  }

  private renameTab(index: number, name: string | null) {
    const grid = this.tabs.tabs[index];
    if (grid) grid.name = name === null ? null : normalizedTabName(name);
    this.refresh();
  }

  private async tearOffTab(index: number, e: PointerEvent) {
    const grid = this.tabs.tabs[index];
    if (!grid) return;
    const found = await api.dropQuery("tab", e.screenX, e.screenY).catch(() => null);
    if (!found && this.tabs.count === 1) return; // already a window of its own
    const saved = grid.saved();
    this.tabs.close(index);
    this.paneHosts.delete(grid);
    grid.dispose(false);
    if (found) await api.transfer(found.label, "tab", saved, found.index);
    else await api.tabToNewWindow(saved, e.screenX, e.screenY);
    if (this.tabs.isEmpty) {
      this.closing = true;
      await this.saveNow();
      await api.windowClose();
    } else {
      this.refresh();
    }
  }

  private answerDrop(query: { id: number; kind: "tab" | "pane"; x: number; y: number }) {
    const x = query.x - window.screenX;
    const y = query.y - window.screenY;
    const index = query.kind === "tab" ? this.tabBar.insertIndexAt(x, y) : this.tabBar.tabAt(x, y);
    void api.dropAnswer(query.id, index);
  }

  private adopt(a: { kind: "tab" | "pane"; payload: SavedTab | SavedPane; index: number }) {
    if (a.kind === "tab") {
      const grid = this.makeGrid();
      this.tabs.insert(grid, a.index);
      grid.restore(a.payload as SavedTab);
    } else {
      const grid = this.tabs.tabs[a.index] ?? this.tabs.selectedTab;
      if (!grid) return;
      const saved = a.payload as SavedPane;
      this.tabs.select(this.tabs.tabs.indexOf(grid));
      grid.addPane({ kind: "shell", shell: saved.shell, cwd: saved.workingDirectory ?? null, sessionId: saved.sessionID ?? null }, grid.panes.length);
    }
    this.refresh();
  }

  private openDirs(dirs: string[]) {
    let grid = this.tabs.selectedTab;
    if (!grid) {
      grid = this.makeGrid();
      this.tabs.add(grid);
    }
    for (const dir of dirs) grid.addPane(this.startSpec(false, dir));
    this.refresh();
  }

  // ---- typing and broadcast --------------------------------------------------

  private input(grid: TabGrid, pane: PaneView, data: string) {
    if (!pane.sessionId) return;
    void api.paneInput(pane.sessionId, data);
    if (!grid.broadcast || pane.suppressBroadcast) return;
    const source = grid.panes.indexOf(pane);
    const running = grid.panes.map((p) => p.running && !p.showingMenu && !!p.sessionId);
    for (const target of broadcastTargets(source, running, true)) {
      const other = grid.panes[target];
      void api.paneInput(other.sessionId!, reencodeForTarget(data, pane.appCursorKeys, other.appCursorKeys));
    }
  }

  /** Pastes into the focused pane, or into every pane while broadcasting;
   * each terminal applies its own bracketed-paste mode. */
  private async paste() {
    const grid = this.tabs.selectedTab;
    const pane = grid?.focusedPane;
    const text = await api.clipboardRead();
    if (!grid || !pane || !text) return;
    const targets = grid.broadcast ? grid.panes.filter((p) => p.running && !p.showingMenu) : [pane];
    for (const target of targets) {
      target.suppressBroadcast = true;
      target.paste(text);
      target.suppressBroadcast = false;
    }
  }

  // ---- keys and commands ------------------------------------------------------

  private keydown(e: KeyboardEvent) {
    const match = matchKey({ code: e.code, ctrlKey: e.ctrlKey, shiftKey: e.shiftKey, altKey: e.altKey, metaKey: e.metaKey, altGraph: e.getModifierState("AltGraph") });
    if (!match) return;
    const target = e.target as HTMLElement | null;
    // Let text fields keep their own editing keys (rename, search, settings).
    if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA") && !target.classList.contains("xterm-helper-textarea")) {
      if ("command" in match && ["copy", "paste", "selectAll", "find"].includes(match.command)) return;
    }
    e.preventDefault();
    e.stopPropagation();
    closeMenus();
    if ("selectTab" in match) {
      this.tabs.selectNumber(match.selectTab);
      this.refresh();
    } else if ("focusPane" in match) {
      this.tabs.selectedTab?.focusNumber(match.focusPane - 1);
    } else {
      this.run(match.command);
    }
  }

  run(command: Command) {
    const grid = this.tabs.selectedTab;
    const pane = grid?.focusedPane ?? null;
    const cwd = pane?.cwd ?? null;
    switch (command) {
      case "newWindow": void api.newWindow(); break;
      case "newTab": this.newTab(false, cwd); break;
      case "newTabChoosingShell": this.newTab(true, cwd); break;
      case "newPane": grid?.addPane(this.startSpec(false, cwd)); break;
      case "newPaneChoosingShell": grid?.addPane(this.startSpec(true, cwd)); break;
      case "closePane": if (grid && pane) grid.removePane(pane, true); break;
      case "closeTab": this.closeTab(this.tabs.selected); break;
      case "closeWindow": void api.windowClose(); break;
      case "toggleBroadcast": grid?.setBroadcast(!grid.broadcast); break;
      case "nextTab": this.tabs.selectNext(1); this.refresh(); break;
      case "previousTab": this.tabs.selectNext(-1); this.refresh(); break;
      case "toggleZoom": grid?.toggleZoom(); break;
      case "toggleCommandBlocks": this.toggleBlocks(); break;
      case "copyLastCommandOutput": void this.copyLastOutput(); break;
      case "explainLastFailure": pane?.explainLast(); break;
      case "nextPane": grid?.focusNext(1); break;
      case "previousPane": grid?.focusNext(-1); break;
      case "focusLeft": grid?.focusDirection("left"); break;
      case "focusRight": grid?.focusDirection("right"); break;
      case "focusUp": grid?.focusDirection("up"); break;
      case "focusDown": grid?.focusDirection("down"); break;
      case "swapLeft": grid?.swap("left"); break;
      case "swapRight": grid?.swap("right"); break;
      case "swapUp": grid?.swap("up"); break;
      case "swapDown": grid?.swap("down"); break;
      case "makeMain": grid?.makeMain(); break;
      case "equalizePanes": grid?.equalize(); break;
      case "toggleAttentionGrid": void api.setSettings({ ...this.settings, attentionGrid: !this.settings.attentionGrid }); break;
      case "cycleLayout": grid?.cycleLayout(); break;
      case "rotateLayout": grid?.rotate(); break;
      case "showSettings": this.toggleSettings(); break;
      case "openConfiguration": void api.openConfig(); break;
      case "reloadConfiguration": void api.reloadConfig(); break;
      case "quit": void this.saveNow().then(() => api.quit()); break;
      case "minimize": void appWindow.minimize(); break;
      case "toggleFullScreen": void appWindow.isFullscreen().then((f) => appWindow.setFullscreen(!f)); break;
      case "copy": pane?.copySelection(); break;
      case "paste": void this.paste(); break;
      case "find": pane?.toggleSearch(); break;
      case "clearScreen": pane?.clear(); break;
      case "fontBigger": pane?.changeFontSize(1); break;
      case "fontSmaller": pane?.changeFontSize(-1); break;
      case "fontReset": pane?.changeFontSize(null); break;
      case "renameTab": this.tabBar.startRename(this.tabs.selected); break;
      case "moveTabToNewWindow": void this.moveTabToNewWindow(this.tabs.selected); break;
      default: break;
    }
  }

  private shortcut(command: Command): string | undefined {
    const chord = bindings(command)[0];
    return chord ? describe(chord) : undefined;
  }

  private item(label: string, command: Command, extra: { checked?: boolean; disabled?: boolean } = {}): MenuItem {
    return { label, shortcut: this.shortcut(command), action: () => this.run(command), ...extra };
  }

  private appMenu(): MenuItem[] {
    const grid = this.tabs.selectedTab;
    return [
      { label: "Shell", submenu: [
        this.item("New Window", "newWindow"),
        this.item("New Tab", "newTab"),
        this.item("New Tab Choosing Shell...", "newTabChoosingShell"),
        this.item("New Pane", "newPane"),
        this.item("New Pane Choosing Shell...", "newPaneChoosingShell"),
        "separator",
        this.item("Broadcast Input to All Panes", "toggleBroadcast", { checked: !!grid?.broadcast }),
      ] },
      { label: "Tab", submenu: this.tabItems(this.tabs.selected) },
      { label: "Pane", submenu: [
        { label: "Layout", submenu: layoutModes.map((mode) => ({ label: layoutTitle(mode), checked: grid?.mode === mode, action: () => grid?.setLayout(mode) })) },
        this.item("Next Layout", "cycleLayout"),
        this.item("Rotate Layout", "rotateLayout", { checked: !!grid?.rotated }),
        this.item("Make Main Pane", "makeMain"),
        this.item("Equalize Panes", "equalizePanes"),
        this.item("Zoom Pane", "toggleZoom", { checked: grid?.zoomed !== null && grid?.zoomed !== undefined }),
        this.item("Attention Grid", "toggleAttentionGrid", { checked: this.settings.attentionGrid }),
        "separator",
        this.item("Command Blocks", "toggleCommandBlocks"),
        this.item("Copy Last Command Output", "copyLastCommandOutput"),
        this.item("Explain Last Failure", "explainLastFailure"),
        "separator",
        this.item("Next Pane", "nextPane"),
        this.item("Previous Pane", "previousPane"),
        this.item("Close Pane", "closePane"),
      ] },
      { label: "View", submenu: [
        this.item("Find...", "find"),
        this.item("Clear Screen", "clearScreen"),
        "separator",
        this.item("Bigger Text", "fontBigger"),
        this.item("Smaller Text", "fontSmaller"),
        this.item("Actual Size", "fontReset"),
        "separator",
        this.item("Full Screen", "toggleFullScreen"),
      ] },
      "separator",
      this.item("Settings...", "showSettings"),
      this.item("Open Ghostty Config", "openConfiguration"),
      this.item("Reload Ghostty Config", "reloadConfiguration"),
      { label: "Check for Updates...", disabled: !this.data.updatesConfigured, action: () => void this.checkUpdates(true) },
      "separator",
      this.item("Close Window", "closeWindow"),
      this.item("Quit ghostgrid", "quit"),
    ];
  }

  private tabItems(index: number): MenuItem[] {
    const grid = this.tabs.tabs[index];
    return [
      { label: "Rename Tab...", shortcut: index === this.tabs.selected ? this.shortcut("renameTab") : undefined, action: () => this.tabBar.startRename(index) },
      { label: "Tab Color", submenu: [
        ...tabColors.map((color) => ({ label: tabColorTitle(color), swatch: TAB_COLORS[color], checked: grid?.color === color, action: () => { if (grid) grid.color = color; this.refresh(); } })),
        { label: "None", checked: !grid?.color, action: () => { if (grid) grid.color = null; this.refresh(); } },
      ] },
      { label: "Move Tab to New Window", disabled: this.tabs.count < 2, action: () => void this.moveTabToNewWindow(index) },
      "separator",
      { label: "Next Tab", shortcut: this.shortcut("nextTab"), action: () => this.run("nextTab") },
      { label: "Previous Tab", shortcut: this.shortcut("previousTab"), action: () => this.run("previousTab") },
      "separator",
      { label: "Close Other Tabs", disabled: this.tabs.count < 2, action: () => this.closeOtherTabs(index) },
      { label: "Close Tab", shortcut: index === this.tabs.selected ? this.shortcut("closeTab") : undefined, action: () => this.closeTab(index) },
    ];
  }

  private tabMenu(index: number, x: number, y: number) {
    showMenu(this.tabItems(index), x, y);
  }

  private paneMenu(grid: TabGrid, pane: PaneView, x: number, y: number) {
    grid.focusPane(pane);
    showMenu([
      this.item("Copy", "copy", { disabled: !pane.term?.hasSelection() }),
      this.item("Paste", "paste"),
      { label: "Select All", action: () => pane.selectAll() },
      this.item("Find...", "find"),
      "separator",
      this.item("New Pane", "newPane"),
      this.item("Zoom Pane", "toggleZoom"),
      this.item("Command Blocks", "toggleCommandBlocks"),
      "separator",
      this.item("Close Pane", "closePane"),
    ], x, y);
  }

  private closeOtherTabs(keep: number) {
    const keepGrid = this.tabs.tabs[keep];
    for (let i = this.tabs.count - 1; i >= 0; i--) {
      if (this.tabs.tabs[i] !== keepGrid) this.removeTab(i, true);
    }
  }

  private async moveTabToNewWindow(index: number) {
    if (this.tabs.count < 2) return;
    const grid = this.tabs.tabs[index];
    const saved = grid.saved();
    this.tabs.close(index);
    this.paneHosts.delete(grid);
    grid.dispose(false);
    this.refresh();
    await api.tabToNewWindow(saved, window.screenX + 60, window.screenY + 60);
  }

  // ---- blocks, settings, updates ------------------------------------------------

  private toggleBlocks() {
    if (this.blocks) {
      this.blocks.close();
      return;
    }
    const pane = this.tabs.selectedTab?.focusedPane;
    if (!pane?.sessionId) return;
    this.blocks = new BlocksPanel(pane, () => {
      this.blocks = null;
      pane.focus();
    });
    this.root.append(this.blocks.el);
  }

  private async copyLastOutput() {
    const pane = this.tabs.selectedTab?.focusedPane;
    if (!pane?.sessionId) return;
    const blocks = await api.paneBlocks(pane.sessionId);
    const last = [...blocks].reverse().find((b) => b.finished);
    if (last) {
      await api.clipboardWrite(last.output);
      this.flashBanner(`Copied the output of ${last.command ?? "the last command"}`);
    }
  }

  private toggleSettings() {
    if (this.settingsPanel) {
      this.settingsPanel.close();
      return;
    }
    this.settingsPanel = new SettingsPanel(this.settings, this.config, this.data, () => {
      this.settingsPanel = null;
      this.tabs.selectedTab?.focusedPane?.focus();
    });
    this.root.append(this.settingsPanel.el);
  }

  private async checkUpdates(manual: boolean) {
    try {
      const update = await api.checkUpdate();
      if (update) this.showUpdate(update.version);
      else if (manual) this.flashBanner(`ghostgrid ${this.data.version} is up to date`);
    } catch (e) {
      if (manual) this.flashBanner(String(e));
    }
  }

  private showUpdate(version: string) {
    this.banner.replaceChildren(
      h("span", { text: `ghostgrid ${version} is available. Your shells keep running through the update.` }),
      h("button", { class: "banner-button", text: "Install and Relaunch", onclick: () => void api.installUpdate().catch((e) => this.flashBanner(String(e))) }),
      h("button", { class: "banner-button", text: "Later", onclick: () => this.banner.classList.add("hidden") }),
    );
    this.banner.classList.remove("hidden");
  }

  private flashBanner(text: string) {
    this.banner.replaceChildren(h("span", { text }));
    this.banner.classList.remove("hidden");
    setTimeout(() => this.banner.classList.add("hidden"), 3000);
  }

  // ---- settings and config -------------------------------------------------------

  private applySettings(settings: Settings) {
    this.settings = settings;
    for (const grid of this.tabs.tabs) grid.applySettings();
    this.settingsPanel?.update(settings);
    this.refresh();
  }

  private applyConfig(config: TerminalConfig) {
    this.config = config;
    applyChrome(config.settings);
    for (const grid of this.tabs.tabs) for (const pane of grid.panes) pane.applyConfig();
    for (const grid of this.tabs.tabs) grid.layout(false);
    this.settingsPanel?.updateConfig(config);
  }

  // ---- state --------------------------------------------------------------------

  private windowFocused() {
    const grid = this.tabs.selectedTab;
    grid?.focusedPane?.seen();
    // Back to the terminal only if that is where you were (not a search
    // field, an overlay or a rename).
    const active = document.activeElement as HTMLElement | null;
    if (!active || active === document.body || active.classList.contains("xterm-helper-textarea")) grid?.focusedPane?.focus();
    this.refresh();
  }

  private tickAttention() {
    const now = Date.now();
    for (const grid of this.tabs.tabs) grid.tickAttention(now);
  }

  /** Redraws the tab bar and title and schedules a save. */
  refresh() {
    const selected = this.tabs.selectedTab;
    this.tabs.tabs.forEach((grid) => grid.show(grid === selected));
    if (selected) selected.lastSeen = Date.now();
    this.tabBar.render(
      this.tabs.tabs.map((grid, i) => {
        const badge = grid === selected ? null : tabBadgeSince(grid.panes.map((p) => ({ activity: p.activity, at: p.activityAt })), grid.lastSeen);
        return {
          title: tabTitle(grid.name, i),
          color: grid.color,
          badge: badge ? { text: activityLabel(badge), kind: badge.kind === "bell" ? "bell" : activityFailed(badge) ? "failed" : "done" } : null,
          active: grid === selected,
          broadcast: grid.broadcast,
        };
      }),
    );
    const pane = selected?.focusedPane;
    const base = pane?.title || (pane?.cwd ? pane.cwd : "ghostgrid");
    const title = selected?.broadcast ? `BROADCAST: ${base}` : base;
    document.title = title;
    void appWindow.setTitle(title);
    this.root.classList.toggle("broadcast", !!selected?.broadcast);
    this.save();
  }

  private async saveNow() {
    if (this.closing && !this.tabs.isEmpty) return;
    const [position, size, scale, maximized] = await Promise.all([appWindow.outerPosition(), appWindow.innerSize(), appWindow.scaleFactor(), appWindow.isMaximized()]);
    const state: SavedWindow = {
      frame: { x: position.x / scale, y: position.y / scale, width: size.width / scale, height: size.height / scale },
      maximized,
      tabs: this.tabs.tabs.map((grid) => grid.saved()).filter((t) => t.panes.length > 0),
      selectedTab: this.tabs.selected,
    };
    await api.saveWindow(state);
  }
}
