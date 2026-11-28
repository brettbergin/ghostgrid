// One pane: its header, its terminal (xterm.js) and the shell behind it,
// the shell menu it starts with, its search bar and its explain panel.
//
// The grid positions the pane; the pane sizes its terminal once to the
// size it is going to, and the grid scales it while the frame animates, so
// text moves with its pane without reflowing on every frame.
import { FitAddon } from "@xterm/addon-fit";
import { SearchAddon } from "@xterm/addon-search";
import { Unicode11Addon } from "@xterm/addon-unicode11";
import { WebglAddon } from "@xterm/addon-webgl";
import { Terminal } from "@xterm/xterm";
import { activityLabel, forFinishedCommand, type PaneActivity } from "../core/paneActivity";
import { api, Channel, type ExplainUpdate, type LaunchApp, type PaneEvent, type SavedPane, type Settings, type ShellChoice, type TerminalConfig } from "../ipc";
import { ChoiceMenu } from "./choiceMenu";
import { h } from "./dom";
import { LinkProvider } from "./links";
import { xtermOptions, xtermTheme } from "./theme";

/** What the pane needs from its tab and window. */
export interface PaneHost {
  settings(): Settings;
  config(): TerminalConfig;
  shells(): ShellChoice[];
  osBuild: number;
  /** The focused pane of the tab in front, in the focused window. */
  isLookedAt(pane: PaneView): boolean;
  focusPane(pane: PaneView): void;
  closePane(pane: PaneView, terminate: boolean): void;
  /** Header, folder or session changed: save, redraw the tab bar. */
  paneChanged(pane: PaneView): void;
  /** Typing in `pane`: to its shell and, while broadcasting, the others'. */
  input(pane: PaneView, data: string): void;
  rememberShell(name: string): void;
  headerPointerDown(pane: PaneView, e: PointerEvent): void;
  contextMenu(pane: PaneView, e: MouseEvent): void;
  /** A bell, notification or finished command while you looked elsewhere. */
  attention(pane: PaneView): void;
  broadcasting(): boolean;
}

export type StartSpec =
  | { kind: "menu"; highlight?: string | null; cwd?: string | null }
  | { kind: "shell"; shell: string; cwd?: string | null; sessionId?: string | null; app?: LaunchApp | null };

let nextPaneId = 1;
const HEADER_HEIGHT = 24;

export class PaneView {
  readonly uid = nextPaneId++;
  readonly el: HTMLDivElement;
  private header: HTMLDivElement;
  private headerShell: HTMLSpanElement;
  private headerPath: HTMLSpanElement;
  private headerBranch: HTMLSpanElement;
  private headerBadge: HTMLSpanElement;
  private cornerBadge: HTMLSpanElement;
  private body: HTMLDivElement;
  readonly host: HTMLDivElement;
  private menu: ChoiceMenu | null = null;
  private searchBar: HTMLDivElement | null = null;
  private explainEl: HTMLDivElement | null = null;
  private explainFix: string | null = null;

  term: Terminal | null = null;
  private fit: FitAddon | null = null;
  private search: SearchAddon | null = null;
  private webgl: WebglAddon | null = null;

  shell: string | null = null;
  sessionId: string | null = null;
  cwd: string | null;
  title = "";
  running = false;
  local = false;
  lastOutput: number | null = null;
  /** Wants you: a bell, a notification, a command that finished while you
   * looked elsewhere. Cleared when you focus the pane. */
  waiting = false;
  activity: PaneActivity | null = null;
  activityAt: number | null = null;
  private lastFailure: number | null = null;
  private pendingApp: LaunchApp | null = null;
  private promptSeen = false;
  private fontSize: number;
  private contentSize = { width: 0, height: 0 };
  private disposed = false;
  suppressBroadcast = false;
  private terminateOnDispose = true;
  private searchResults: { dispose(): void } | undefined;

  constructor(private hostApi: PaneHost, start: StartSpec) {
    this.cwd = start.cwd ?? null;
    this.fontSize = hostApi.config().settings.fontSizePx;
    this.headerShell = h("span", { class: "header-shell" });
    this.headerPath = h("span", { class: "header-path" });
    this.headerBranch = h("span", { class: "header-branch" });
    this.headerBadge = h("span", { class: "badge" });
    this.cornerBadge = h("span", { class: "badge corner" });
    this.header = h(
      "div",
      { class: "pane-header" },
      h("span", { class: "header-broadcast", text: "BROADCAST" }),
      this.headerShell,
      this.headerPath,
      this.headerBranch,
      h("span", { class: "header-spacer" }),
      this.headerBadge,
    );
    this.host = h("div", { class: "term-host" });
    this.body = h("div", { class: "pane-body" }, this.host, h("div", { class: "pane-dim" }), this.cornerBadge);
    this.el = h("div", { class: "pane" }, this.header, this.body, h("div", { class: "pane-flash" }));
    this.header.addEventListener("pointerdown", (e) => this.hostApi.headerPointerDown(this, e));
    this.el.addEventListener("pointerdown", () => this.hostApi.focusPane(this), true);
    this.body.addEventListener("contextmenu", (e) => {
      const mouseApp = this.term && this.term.modes.mouseTrackingMode !== "none" && !e.shiftKey;
      if (mouseApp) return;
      e.preventDefault();
      this.hostApi.contextMenu(this, e);
    });
    this.body.addEventListener("mousemove", () => this.el.classList.remove("hide-pointer"));

    if (start.kind === "menu") {
      this.showShellMenu(start.highlight ?? null);
    } else {
      this.startShell(start.shell, start.sessionId ?? null, start.app ?? null);
    }
    this.updateHeader();
  }

  /** The pane moved to another tab: from now on it answers to that one. */
  rehost(host: PaneHost) {
    this.hostApi = host;
    this.updateHeader();
  }

  // ---- layout ---------------------------------------------------------------

  headerHeight(): number {
    return this.hostApi.settings().showPaneHeaders ? HEADER_HEIGHT : 0;
  }

  /** The terminal's final size: it takes it once, the grid scales it. */
  setContentSize(width: number, height: number) {
    const h = Math.max(0, height - this.headerHeight());
    this.contentSize = { width, height: h };
    // Ghostty's window padding sits around the terminal, not inside the
    // element FitAddon measures.
    const pad = this.hostApi.config().settings.padding;
    this.host.style.left = `${pad.left}px`;
    this.host.style.top = `${pad.top}px`;
    this.host.style.width = `${Math.max(0, width - pad.left - pad.right)}px`;
    this.host.style.height = `${Math.max(0, h - pad.top - pad.bottom)}px`;
    this.refit();
  }

  setContentScale(scale: number | null) {
    this.host.style.transform = scale === null || Math.abs(scale - 1) < 1e-3 ? "" : `scale(${scale})`;
  }

  private refit() {
    if (!this.term || !this.fit || this.contentSize.width < 20 || this.contentSize.height < 10) return;
    const dims = this.fit.proposeDimensions();
    if (!dims || !Number.isFinite(dims.cols) || !Number.isFinite(dims.rows)) return;
    const cols = Math.max(2, dims.cols);
    const rows = Math.max(1, dims.rows);
    if (cols !== this.term.cols || rows !== this.term.rows) this.term.resize(cols, rows);
  }

  // ---- shell menu -------------------------------------------------------------

  private showShellMenu(highlight: string | null) {
    const shells = this.hostApi.shells();
    const choices = shells.map((s) => ({
      key: s.hotkey,
      title: s.title,
      detail: s.executable ?? "not installed",
      enabled: !!s.executable,
    }));
    const start = Math.max(0, shells.findIndex((s) => s.name === highlight));
    this.menu = new ChoiceMenu(
      "Start a shell",
      choices,
      start,
      (i) => this.pickShell(shells[i]),
      () => this.hostApi.closePane(this, false),
      "Press a number, or Up/Down and Return. Escape closes the pane.",
    );
    this.body.append(this.menu.el);
    requestAnimationFrame(() => this.menu?.focus());
  }

  private async pickShell(shell: ShellChoice) {
    this.removeMenu();
    this.hostApi.rememberShell(shell.name);
    if (shell.name === "pwsh" && this.hostApi.settings().offerAppsAfterShell) {
      const apps = await api.launcherApps().catch(() => [] as LaunchApp[]);
      if (apps.length > 0) {
        this.showAppMenu(shell, apps);
        return;
      }
    }
    this.startShell(shell.name, null, null);
  }

  private showAppMenu(shell: ShellChoice, apps: LaunchApp[]) {
    this.shell = shell.name;
    this.updateHeader();
    const choices = apps.map((a) => ({
      key: a.hotkey,
      title: a.name,
      detail: a.summary,
      enabled: true,
      note: a.executable ? undefined : "(not found)",
    }));
    this.menu = new ChoiceMenu(
      `Start an app in ${shell.title}`,
      choices,
      0,
      (i) => {
        this.removeMenu();
        this.startShell(shell.name, null, apps[i]);
      },
      () => {
        this.removeMenu();
        this.startShell(shell.name, null, null);
      },
      "Press a number to start it. Escape starts a plain shell.",
    );
    this.body.append(this.menu.el);
    requestAnimationFrame(() => this.menu?.focus());
  }

  private removeMenu() {
    this.menu?.el.remove();
    this.menu = null;
  }

  get showingMenu(): boolean {
    return this.menu !== null;
  }

  // ---- terminal ---------------------------------------------------------------

  private createTerminal() {
    const config = this.hostApi.config().settings;
    const term = new Terminal({
      ...xtermOptions(config, this.hostApi.osBuild),
      fontSize: this.fontSize,
      linkHandler: {
        allowNonHttpProtocols: true,
        activate: (event, text) => {
          if (event.ctrlKey) void api.openLink(text, this.cwd);
        },
      },
    });
    this.fit = new FitAddon();
    this.search = new SearchAddon();
    term.loadAddon(this.fit);
    term.loadAddon(this.search);
    term.loadAddon(new Unicode11Addon());
    term.unicode.activeVersion = "11";
    term.open(this.host);
    try {
      this.webgl = new WebglAddon();
      this.webgl.onContextLoss(() => {
        // Too many panes for the GPU's contexts: fall back to the DOM renderer.
        this.webgl?.dispose();
        this.webgl = null;
      });
      term.loadAddon(this.webgl);
    } catch {
      this.webgl = null;
    }
    term.registerLinkProvider(new LinkProvider(term, () => this.cwd));
    term.parser.registerOscHandler(133, (data) => {
      if (data.startsWith("A") || data.startsWith("B")) this.onPrompt();
      return false;
    });
    term.onData((data) => {
      if (config.mouseHideWhileTyping) this.el.classList.add("hide-pointer");
      this.hostApi.input(this, data);
    });
    term.onBinary((data) => {
      // One byte per char (mouse reports): not UTF-8 text.
      if (this.sessionId) void api.paneInputBytes(this.sessionId, Array.from(data, (c) => c.charCodeAt(0) & 0xff));
    });
    term.onResize(({ cols, rows }) => {
      if (this.sessionId) void api.paneResize(this.sessionId, cols, rows, Math.round(this.contentSize.width), Math.round(this.contentSize.height));
    });
    term.onBell(() => this.bell());
    term.onTitleChange((title) => {
      this.title = title;
      this.hostApi.paneChanged(this);
    });
    term.onSelectionChange(() => {
      if (this.hostApi.config().settings.copyOnSelect && term.hasSelection()) {
        void api.clipboardWrite(term.getSelection());
      }
    });
    this.term = term;
    this.refit();
  }

  private async startShell(shell: string, sessionId: string | null, app: LaunchApp | null) {
    this.shell = shell;
    this.pendingApp = app;
    this.updateHeader();
    this.createTerminal();
    const term = this.term!;
    await document.fonts?.ready;
    if (this.disposed) return;
    this.refit();
    const data = new Channel<ArrayBuffer>();
    data.onmessage = (buffer) => this.output(buffer);
    const events = new Channel<PaneEvent>();
    events.onmessage = (event) => this.event(event);
    try {
      const opened = await api.paneOpen({ sessionId, shell, cwd: this.cwd, cols: term.cols, rows: term.rows }, data, events);
      if (this.disposed) {
        // Closed while it started: end the shell, or let a moving pane's go.
        void (this.terminateOnDispose ? api.paneClose(opened.sessionId) : api.paneRelease(opened.sessionId));
        return;
      }
      this.sessionId = opened.sessionId;
      // Sizes set while the shell was starting (a restored tab's first
      // layout) were not sent yet.
      void api.paneResize(opened.sessionId, term.cols, term.rows, Math.round(this.contentSize.width), Math.round(this.contentSize.height));
      this.local = opened.local;
      this.running = true;
      this.hostApi.paneChanged(this);
      if (this.hostApi.isLookedAt(this)) term.focus();
      if (app && !this.promptSeen) {
        // Shells without prompt marks: type the app once output settles.
        setTimeout(() => this.onPrompt(), 2500);
      }
    } catch (error) {
      term.write(`\r\n\x1b[31mghostgrid: ${String(error)}\x1b[0m\r\n`);
    }
  }

  private output(buffer: ArrayBuffer | Uint8Array | number[]) {
    const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer as ArrayBuffer);
    this.term?.write(bytes);
    this.lastOutput = Date.now();
  }

  /** The shell's first prompt: type the app picked from the menu there, so
   * it lands in history and quitting it leaves you at the prompt. */
  private onPrompt() {
    this.promptSeen = true;
    const app = this.pendingApp;
    if (!app || !this.sessionId) return;
    this.pendingApp = null;
    void api.paneInput(this.sessionId, app.command + "\r");
  }

  private event(event: PaneEvent) {
    switch (event.type) {
      case "commandStarted":
        this.dismissExplain();
        break;
      case "commandFinished": {
        const looked = this.hostApi.isLookedAt(this);
        if (this.hostApi.settings().showActivityBadges && event.seconds !== null) {
          const badge = forFinishedCommand(event.exitCode, event.seconds, looked);
          if (badge) {
            this.setActivity(badge);
            this.waiting = true;
            this.hostApi.attention(this);
          }
        }
        if ((event.exitCode ?? 0) !== 0) this.lastFailure = event.block;
        if (looked && (event.exitCode ?? 0) !== 0 && this.hostApi.settings().explainFailures && event.command?.trim()) {
          this.explain(event.block, false);
        }
        this.refreshHeaderInfo();
        break;
      }
      case "cwd":
        this.cwd = event.path;
        this.refreshHeaderInfo();
        this.hostApi.paneChanged(this);
        break;
      case "notification":
        this.waiting = !this.hostApi.isLookedAt(this);
        if (this.waiting || !document.hasFocus()) {
          void api.notify(event.title || this.title || "ghostgrid", event.body);
        }
        this.hostApi.attention(this);
        break;
      case "blocksChanged":
        break;
      case "exited":
        this.running = false;
        this.hostApi.closePane(this, false);
        break;
      case "failure":
        this.term?.write(`\r\n\x1b[31mghostgrid: ${event.message}\x1b[0m\r\n`);
        break;
    }
  }

  private bell() {
    this.el.classList.remove("flash");
    void this.el.offsetWidth;
    this.el.classList.add("flash");
    if (!this.hostApi.isLookedAt(this)) {
      if (this.hostApi.settings().showActivityBadges) this.setActivity({ kind: "bell" });
      this.waiting = true;
      this.hostApi.attention(this);
    }
  }

  setActivity(activity: PaneActivity | null) {
    this.activity = activity;
    this.activityAt = activity ? Date.now() : null;
    this.updateHeader();
    this.hostApi.paneChanged(this);
  }

  /** You looked: badges and "waiting" go. */
  seen() {
    if (this.activity || this.waiting) {
      this.waiting = false;
      this.setActivity(null);
    }
  }

  focus() {
    if (this.menu) this.menu.focus();
    else this.term?.focus();
  }

  // ---- header ---------------------------------------------------------------

  private async refreshHeaderInfo() {
    if (!this.cwd) return;
    try {
      const info = await api.paneInfo(this.cwd);
      this.headerPath.textContent = info.display;
      this.headerBranch.textContent = info.branch ? `⎇ ${info.branch}` : "";
    } catch {
      /* the folder may be gone */
    }
  }

  updateHeader() {
    const shell = this.hostApi.shells().find((s) => s.name === this.shell);
    this.headerShell.textContent = shell?.title ?? this.shell ?? "new pane";
    if (!this.headerPath.textContent && this.cwd) void this.refreshHeaderInfo();
    const label = this.activity ? activityLabel(this.activity) : "";
    const kind = !this.activity ? "" : this.activity.kind === "bell" ? "bell" : (this.activity.exitCode ?? 0) !== 0 ? "failed" : "done";
    const text = kind === "failed" ? `✕ ${label}` : kind === "done" ? `✓ ${label}` : label;
    for (const badge of [this.headerBadge, this.cornerBadge]) {
      badge.textContent = text;
      badge.className = `badge ${kind}` + (badge === this.cornerBadge ? " corner" : "");
    }
    this.el.classList.toggle("headers-off", !this.hostApi.settings().showPaneHeaders);
    this.el.classList.toggle("local", this.local);
    this.header.title = this.title || "";
  }

  // ---- search -----------------------------------------------------------------

  toggleSearch() {
    if (this.searchBar) {
      this.closeSearch();
      return;
    }
    const input = h("input", { class: "search-input", placeholder: "Find", spellcheck: "false" });
    const count = h("span", { class: "search-count" });
    this.searchBar = h("div", { class: "search-bar" }, input, count);
    this.searchResults?.dispose();
    const options = { decorations: { matchOverviewRuler: "#f9e2af", activeMatchColorOverviewRuler: "#fab387", matchBackground: "#f9e2af55", activeMatchBackground: "#fab387aa" } };
    this.searchResults = this.search?.onDidChangeResults((r) => {
      count.textContent = r.resultCount ? `${r.resultIndex + 1}/${r.resultCount}` : input.value ? "0" : "";
    });
    input.addEventListener("input", () => this.search?.findNext(input.value, { ...options, incremental: true }));
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        if (e.shiftKey) this.search?.findPrevious(input.value, options);
        else this.search?.findNext(input.value, options);
      } else if (e.key === "Escape") {
        e.preventDefault();
        this.closeSearch();
      }
    });
    this.body.append(this.searchBar);
    input.focus();
  }

  private closeSearch() {
    this.searchResults?.dispose();
    this.searchResults = undefined;
    this.search?.clearDecorations();
    this.searchBar?.remove();
    this.searchBar = null;
    this.term?.focus();
  }

  // ---- explain ----------------------------------------------------------------

  /** Explain the last failure: `focus` takes the keyboard (Return runs the
   * fix); the automatic panel never does, so a reflexive Return still goes
   * to the shell. */
  explainLast() {
    if (this.explainEl) {
      this.explainEl.focus();
      return;
    }
    if (this.lastFailure !== null) this.explain(this.lastFailure, true);
  }

  private explain(block: number, focus: boolean) {
    if (!this.sessionId) return;
    this.dismissExplain();
    const why = h("div", { class: "explain-why", text: "Asking the local model…" });
    const fix = h("code", { class: "explain-fix" });
    const hint = h("div", { class: "explain-hint", text: "Ctrl+Shift+E, then Return runs the fix. Escape dismisses." });
    const panel = h("div", { class: "explain", tabindex: -1 }, h("div", { class: "explain-title", text: "Why it failed" }), why, fix, hint);
    this.explainEl = panel;
    this.explainFix = null;
    panel.addEventListener("keydown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === "Enter" && this.explainFix && this.sessionId) {
        const command = this.explainFix;
        this.dismissExplain();
        // To this pane only, even while broadcasting.
        void api.paneInput(this.sessionId, command + "\r");
      } else if (e.key === "Escape") {
        this.dismissExplain();
      } else if (!["Shift", "Control", "Alt", "Meta"].includes(e.key)) {
        // Any other key dismisses and goes to the shell.
        this.dismissExplain();
        if (e.key.length === 1 && !e.ctrlKey && !e.altKey && this.sessionId) void api.paneInput(this.sessionId, e.key);
      }
    });
    this.body.append(panel);
    const channel = new Channel<ExplainUpdate>();
    channel.onmessage = (update) => {
      if (this.explainEl !== panel) return;
      if (update.error) {
        why.textContent = update.error;
        panel.classList.add("error");
        return;
      }
      if (update.thinking && !update.why) why.textContent = "The model is thinking…";
      if (update.why) why.textContent = update.why;
      if (update.fix !== undefined) {
        this.explainFix = update.fix ?? null;
        fix.textContent = update.fix ?? "";
        fix.style.display = update.fix ? "" : "none";
      }
    };
    api.explainStart(this.sessionId, block, channel).catch((e) => {
      why.textContent = String(e);
    });
    if (focus) panel.focus();
  }

  private dismissExplain() {
    if (!this.explainEl) return;
    const hadFocus = this.explainEl.contains(document.activeElement);
    this.explainEl.remove();
    this.explainEl = null;
    this.explainFix = null;
    if (this.sessionId) void api.explainCancel(this.sessionId);
    if (hadFocus) this.term?.focus();
  }

  // ---- commands from the window -----------------------------------------------

  copySelection(): boolean {
    if (!this.term?.hasSelection()) return false;
    void api.clipboardWrite(this.term.getSelection());
    return true;
  }

  paste(text: string) {
    this.term?.paste(text);
  }

  selectAll() {
    this.term?.selectAll();
  }

  clear() {
    this.term?.clear();
  }

  changeFontSize(delta: number | null) {
    const base = this.hostApi.config().settings.fontSizePx;
    this.fontSize = delta === null ? base : Math.min(72, Math.max(6, this.fontSize + delta));
    if (this.term) {
      this.term.options.fontSize = this.fontSize;
      this.refit();
    }
  }

  applyConfig() {
    const config = this.hostApi.config().settings;
    this.fontSize = config.fontSizePx;
    if (this.term) {
      const options = xtermOptions(config, this.hostApi.osBuild);
      this.term.options.theme = xtermTheme(config);
      this.term.options.fontFamily = options.fontFamily;
      this.term.options.fontSize = this.fontSize;
      this.term.options.lineHeight = options.lineHeight;
      this.term.options.cursorStyle = options.cursorStyle;
      this.term.options.cursorBlink = options.cursorBlink;
      this.term.options.minimumContrastRatio = options.minimumContrastRatio;
      this.refit();
    }
    this.updateHeader();
  }

  /** The application-cursor-keys mode, for broadcast re-encoding. */
  get appCursorKeys(): boolean {
    return this.term?.modes.applicationCursorKeysMode ?? false;
  }

  /** null while it still shows the shell menu (nothing to restore). */
  saved(): SavedPane | null {
    if (!this.shell) return null;
    return { shell: this.shell, workingDirectory: this.cwd, sessionID: this.sessionId };
  }

  /** Removes the pane. `terminate` ends its shell; otherwise the shell stays
   * running for another window (or the next launch) to attach to. */
  dispose(terminate: boolean, fadeMs = 0) {
    if (this.disposed) return;
    this.disposed = true;
    this.terminateOnDispose = terminate;
    // The shell first, at once: a quit right after must not keep it.
    if (this.sessionId) {
      if (terminate) void api.paneClose(this.sessionId);
      else void api.paneRelease(this.sessionId);
    }
    const remove = () => {
      this.webgl?.dispose();
      this.term?.dispose();
      this.el.remove();
    };
    if (fadeMs > 0) setTimeout(remove, fadeMs);
    else remove();
  }
}
