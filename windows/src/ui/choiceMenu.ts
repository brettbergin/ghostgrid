// The menu a new pane shows before it starts a shell (and, after picking
// PowerShell, the apps to start in it). Press the number to pick at once,
// or Up/Down and Return; Escape cancels. Entries that cannot be picked are
// dimmed and skipped.
import { h } from "./dom";

export interface Choice {
  key: string;
  title: string;
  detail?: string;
  enabled: boolean;
  note?: string;
}

export class ChoiceMenu {
  el: HTMLDivElement;
  private index: number;
  private rows: HTMLElement[] = [];

  constructor(
    heading: string,
    private choices: Choice[],
    highlighted: number,
    private onPick: (index: number) => void,
    private onCancel: () => void,
    footer: string,
  ) {
    this.index = this.firstEnabled(highlighted);
    const list = h("div", { class: "choice-list" });
    choices.forEach((choice, i) => {
      const row = h(
        "div",
        { class: "choice" + (choice.enabled ? "" : " disabled") },
        h("span", { class: "choice-key", text: choice.key }),
        h("span", { class: "choice-title", text: choice.title }),
        h("span", { class: "choice-detail", text: [choice.detail, choice.note].filter(Boolean).join("  ") }),
      );
      row.addEventListener("pointerdown", (e) => {
        e.preventDefault();
        if (choice.enabled) this.onPick(i);
      });
      row.addEventListener("pointerenter", () => choice.enabled && this.highlight(i));
      this.rows.push(row);
      list.append(row);
    });
    this.el = h(
      "div",
      { class: "choice-menu", tabindex: 0 },
      h("div", { class: "choice-heading", text: heading }),
      list,
      h("div", { class: "choice-footer", text: footer }),
    );
    this.el.addEventListener("keydown", (e) => this.key(e));
    this.highlight(this.index);
  }

  private firstEnabled(from: number): number {
    if (this.choices[from]?.enabled) return from;
    const found = this.choices.findIndex((c) => c.enabled);
    return found;
  }

  private highlight(index: number) {
    this.index = index;
    this.rows.forEach((row, i) => row.classList.toggle("active", i === index));
  }

  private step(delta: number) {
    const n = this.choices.length;
    for (let k = 1; k <= n; k++) {
      const i = (((this.index + delta * k) % n) + n) % n;
      if (this.choices[i].enabled) {
        this.highlight(i);
        return;
      }
    }
  }

  focus() {
    this.el.focus({ preventScroll: true });
  }

  private key(e: KeyboardEvent) {
    if (e.ctrlKey || e.altKey || e.metaKey) return;
    const byKey = this.choices.findIndex((c) => c.key === e.key);
    if (byKey >= 0) {
      e.preventDefault();
      if (this.choices[byKey].enabled) this.onPick(byKey);
      return;
    }
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        this.step(1);
        break;
      case "ArrowUp":
        e.preventDefault();
        this.step(-1);
        break;
      case "Enter":
        e.preventDefault();
        if (this.index >= 0) this.onPick(this.index);
        break;
      case "Escape":
        e.preventDefault();
        this.onCancel();
        break;
    }
  }
}
