// ghostgrid's own options (Ctrl+,), saved in %APPDATA%\ghostgrid and
// applied at once in every window. Everything about how terminals look
// stays in the Ghostty config, which this only points at.
import { animationStyles, animationTitle } from "../core/animation";
import { layoutModes, layoutTitle } from "../core/gridLayout";
import { api, type InitData, type LauncherEntry, type Settings, type TerminalConfig } from "../ipc";
import { h } from "./dom";

const DEFAULT_APPS: Omit<LauncherEntry, "id">[] = [
  { name: "opencode", command: "opencode", summary: "coding agent on the local model" },
  { name: "claude", command: "claude", summary: "Claude Code" },
  { name: "btop", command: "btop", summary: "system monitor" },
  { name: "lazygit", command: "lazygit", summary: "git TUI" },
  { name: "yazi", command: "y", summary: "file manager; q leaves you in that folder", program: "yazi" },
];

const newId = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2));

export class SettingsPanel {
  readonly el: HTMLDivElement;
  private body: HTMLDivElement;

  constructor(private settings: Settings, private config: TerminalConfig, private data: InitData, private onClose: () => void) {
    this.body = h("div", { class: "settings-body" });
    this.el = h(
      "div",
      { class: "overlay settings", tabindex: -1 },
      h("div", { class: "panel-head" }, h("span", { class: "panel-title", text: "ghostgrid Settings" }), h("span", { class: "header-spacer" }), h("button", { class: "panel-button", text: "Done", onclick: () => this.close() })),
      this.body,
    );
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        this.close();
      }
    });
    this.render();
    requestAnimationFrame(() => this.el.focus());
  }

  update(settings: Settings) {
    this.settings = settings;
    if (!this.el.contains(document.activeElement) || document.activeElement === this.el) this.render();
  }

  updateConfig(config: TerminalConfig) {
    this.config = config;
    this.render();
  }

  private set(patch: Partial<Settings>) {
    this.settings = { ...this.settings, ...patch };
    void api.setSettings(this.settings);
  }

  private toggle(label: string, key: keyof Settings, help?: string): HTMLElement {
    const input = h("input", { type: "checkbox" }) as HTMLInputElement;
    input.checked = !!this.settings[key];
    input.addEventListener("change", () => this.set({ [key]: input.checked } as Partial<Settings>));
    return h("label", { class: "setting" }, input, h("span", { text: label }), help ? h("span", { class: "setting-help", text: help }) : null);
  }

  private select(label: string, value: string, options: [string, string][], onChange: (v: string) => void): HTMLElement {
    const select = h("select") as HTMLSelectElement;
    for (const [v, title] of options) {
      const option = h("option", { value: v, text: title }) as HTMLOptionElement;
      option.selected = v === value;
      select.append(option);
    }
    select.addEventListener("change", () => onChange(select.value));
    return h("label", { class: "setting" }, h("span", { class: "setting-label", text: label }), select);
  }

  private text(label: string, value: string, placeholder: string, onChange: (v: string) => void): HTMLElement {
    const input = h("input", { type: "text", value, placeholder, spellcheck: "false" }) as HTMLInputElement;
    input.addEventListener("change", () => onChange(input.value.trim()));
    return h("label", { class: "setting" }, h("span", { class: "setting-label", text: label }), input);
  }

  private section(title: string, ...children: (HTMLElement | null)[]): HTMLElement {
    return h("section", { class: "settings-section" }, h("h2", { text: title }), ...children);
  }

  private render() {
    const s = this.settings;
    const shellTitle = this.data.shells.find((x) => x.name === s.lastShell)?.title ?? s.lastShell;
    const gap = h("input", { type: "range", min: 0, max: 24, step: 1, value: s.paneGap }) as HTMLInputElement;
    const gapValue = h("span", { class: "setting-value", text: `${s.paneGap} px` });
    gap.addEventListener("input", () => (gapValue.textContent = `${gap.value} px`));
    gap.addEventListener("change", () => this.set({ paneGap: Number(gap.value) }));
    const c = this.config;
    const restores = (c.settings.windowSaveState ?? "default").toLowerCase();

    this.body.replaceChildren(
      this.section(
        "Shells",
        this.select("Ctrl+Shift+T and Ctrl+Shift+D open", s.newPaneUsesLastShell ? "last" : "menu", [["last", "Your last shell"], ["menu", "The shell menu every time"]], (v) => this.set({ newPaneUsesLastShell: v === "last" })),
        h("div", { class: "setting" }, h("span", { class: "setting-label", text: "Last shell" }), h("span", { text: shellTitle ?? "none yet" }), s.lastShell ? h("button", { class: "panel-button", text: "Forget", onclick: () => this.set({ lastShell: null }) }) : null),
        this.toggle("Keep shells running after quitting", "keepShellsRunning", "They come back, with their output, when ghostgrid opens again."),
      ),
      this.section("PowerShell app launcher", this.toggle("Offer apps after choosing PowerShell", "offerAppsAfterShell"), this.launcherEditor()),
      this.section(
        "Panes",
        this.toggle("Pane headers (shell, folder, git branch)", "showPaneHeaders"),
        this.toggle("Activity badges (bell, finished and failed commands)", "showActivityBadges"),
        h("label", { class: "setting" }, h("span", { class: "setting-label", text: "Gap between panes" }), gap, gapValue),
        this.select("Animations", s.animationStyle, animationStyles.map((a) => [a, animationTitle(a)]), (v) => this.set({ animationStyle: v })),
      ),
      this.section(
        "Grid",
        this.select("New windows use", s.defaultLayout, layoutModes.map((m) => [m, layoutTitle(m)]), (v) => this.set({ defaultLayout: v })),
        this.toggle("Attention grid (panes that need you grow)", "attentionGrid"),
      ),
      this.section(
        "Explain failures",
        this.toggle("Explain failed commands with a local model", "explainFailures"),
        this.text("Model server", s.modelEndpoint, "http://localhost:1234/v1", (v) => this.set({ modelEndpoint: v || "http://localhost:1234/v1" })),
        this.text("Model", s.modelName, "a loaded model (automatic)", (v) => this.set({ modelName: v })),
      ),
      this.section(
        "Ghostty",
        h("div", { class: "setting" }, h("span", { class: "setting-label", text: "Config" }), h("code", { text: c.path + (c.exists ? "" : " (not there yet)") })),
        c.error ? h("div", { class: "setting error", text: c.error }) : null,
        h("div", { class: "setting" }, h("span", { class: "setting-label", text: "Windows restored" }), h("span", { text: restores === "never" ? "never (window-save-state = never)" : restores === "always" ? "always" : s.keepShellsRunning ? "yes, with kept shells" : "no (window-save-state = default)" })),
        c.settings.unsupported.length ? h("div", { class: "setting" }, h("span", { class: "setting-label", text: "Not on Windows" }), h("span", { class: "setting-help", text: c.settings.unsupported.join(", ") })) : null,
        h("div", { class: "setting" }, h("button", { class: "panel-button", text: "Open Config", onclick: () => void api.openConfig() }), h("button", { class: "panel-button", text: "Reload", onclick: () => void api.reloadConfig() })),
      ),
      this.section(
        "Updates and command line",
        this.data.updatesConfigured ? this.toggle("Check for updates once a day", "checkForUpdates") : h("div", { class: "setting setting-help", text: "This build has no update key, so it does not update itself." }),
        h("div", { class: "setting" }, h("span", { class: "setting-label", text: "gg command" }), this.ggButton()),
        h("div", { class: "setting setting-help", text: `ghostgrid ${this.data.version}` }),
      ),
    );
  }

  private ggButton(): HTMLElement {
    const result = h("span", { class: "setting-help" });
    const button = h("button", { class: "panel-button", text: "Put gg on PATH" });
    button.addEventListener("click", async () => {
      try {
        const path = await api.installGg();
        result.textContent = `Installed ${path}. Open a new terminal to use it.`;
      } catch (e) {
        result.textContent = String(e);
      }
    });
    return h("span", {}, button, result);
  }

  private launcherEditor(): HTMLElement {
    // Handlers read the current list (not the one this render saw), and
    // changes to its shape re-render.
    const entries = this.settings.launcherEntries;
    const current = () => this.settings.launcherEntries;
    const save = (next: LauncherEntry[], rerender = true) => {
      this.set({ launcherEntries: next });
      if (rerender) this.render();
    };
    const rows = entries.map((entry, i) => {
      const field = (key: "name" | "command" | "summary", placeholder: string) => {
        const input = h("input", { type: "text", value: entry[key] ?? "", placeholder, spellcheck: "false" }) as HTMLInputElement;
        input.addEventListener("change", () => save(current().map((e, j) => (j === i ? { ...e, [key]: input.value } : e)), false));
        return input;
      };
      const moveBy = (d: number) => {
        const next = [...current()];
        const [item] = next.splice(i, 1);
        next.splice(Math.max(0, Math.min(next.length, i + d)), 0, item);
        save(next);
      };
      return h(
        "div",
        { class: "launcher-row" },
        h("span", { class: "choice-key", text: String(i + 1) }),
        field("name", "name"),
        field("command", "command typed at the prompt"),
        field("summary", "description"),
        h("button", { class: "panel-button", text: "Up", disabled: i === 0, onclick: () => moveBy(-1) }),
        h("button", { class: "panel-button", text: "Down", disabled: i === entries.length - 1, onclick: () => moveBy(1) }),
        h("button", { class: "panel-button", text: "Remove", onclick: () => save(current().filter((_, j) => j !== i)) }),
      );
    });
    return h(
      "div",
      { class: "launcher" },
      ...rows,
      h(
        "div",
        { class: "setting" },
        h("button", { class: "panel-button", text: "Add", disabled: entries.length >= 9, onclick: () => { if (current().length < 9) save([...current(), { id: newId(), name: "", command: "", summary: "" }]); } }),
        h("button", { class: "panel-button", text: "Reset to Defaults", onclick: () => save(DEFAULT_APPS.map((a) => ({ ...a, id: newId() }))) }),
        h("span", { class: "setting-help", text: "Up to 9 (keys 1-9). An empty list means a plain shell." }),
      ),
    );
  }

  close() {
    this.el.remove();
    this.onClose();
  }
}
