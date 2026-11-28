// Pane > Command Blocks: every command the focused pane ran, newest last:
// its command line, its output as plain text, how it ended and how long it
// took. Fold or unfold each (or all), copy one, run it again, or copy it
// as Markdown to share.
import { api, type BlockView } from "../ipc";
import { h } from "./dom";
import type { PaneView } from "./pane";

function duration(block: BlockView): string {
  if (block.finishedAt === null) return block.finished ? "" : "running";
  const seconds = Math.max(0, block.finishedAt - block.startedAt);
  if (seconds < 1) return `${Math.round(seconds * 1000)} ms`;
  if (seconds < 60) return `${seconds.toFixed(1)} s`;
  return `${Math.floor(seconds / 60)}m ${String(Math.round(seconds % 60)).padStart(2, "0")}s`;
}

function transcript(block: BlockView): string {
  const text = `$ ${block.command ?? ""}\n${block.output}`;
  return text.endsWith("\n") ? text : text + "\n";
}

export class BlocksPanel {
  readonly el: HTMLDivElement;
  private list: HTMLDivElement;
  private folded = new Set<number>();
  private blocks: BlockView[] | null = null;
  private timer: number;

  constructor(private pane: PaneView, private onClose: () => void) {
    this.list = h("div", { class: "blocks-list" });
    const foldAll = h("button", { class: "panel-button", text: "Fold All", onclick: () => this.foldAll(true) });
    const unfoldAll = h("button", { class: "panel-button", text: "Unfold All", onclick: () => this.foldAll(false) });
    const close = h("button", { class: "panel-button", text: "Close", onclick: () => this.close() });
    this.el = h(
      "div",
      { class: "overlay blocks", tabindex: -1 },
      h("div", { class: "panel-head" }, h("span", { class: "panel-title", text: "Command Blocks" }), h("span", { class: "header-spacer" }), foldAll, unfoldAll, close),
      this.list,
    );
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        this.close();
      }
    });
    void this.load(true);
    this.timer = window.setInterval(() => void this.load(false), 1000);
    requestAnimationFrame(() => this.el.focus());
  }

  private async load(scroll: boolean) {
    if (!this.pane.sessionId) return;
    const blocks = await api.paneBlocks(this.pane.sessionId).catch(() => [] as BlockView[]);
    if (JSON.stringify(blocks) === JSON.stringify(this.blocks)) return;
    this.blocks = blocks;
    this.render();
    if (scroll) this.list.scrollTop = this.list.scrollHeight;
  }

  private foldAll(fold: boolean) {
    this.folded = fold ? new Set((this.blocks ?? []).map((b) => b.id)) : new Set();
    this.render();
  }

  private render() {
    const all = this.blocks ?? [];
    if (all.length === 0) {
      this.list.replaceChildren(h("div", { class: "blocks-empty", text: "No commands yet. Blocks come from the shell's prompt marks (shell integration)." }));
      return;
    }
    this.list.replaceChildren(
      ...all.map((block) => {
        const folded = this.folded.has(block.id);
        const status = block.summary === "ok" ? "done" : block.summary === "running" ? "" : "failed";
        const toggle = () => {
          if (folded) this.folded.delete(block.id);
          else this.folded.add(block.id);
          this.render();
        };
        return h(
          "div",
          { class: "block" + (folded ? " folded" : "") },
          h(
            "div",
            { class: "block-head", onclick: toggle },
            h("span", { class: "block-fold", text: folded ? "▸" : "▾" }),
            h("code", { class: "block-command", text: block.command ?? "(command not reported)" }),
            h("span", { class: `badge ${status}`, text: block.summary }),
            h("span", { class: "block-time", text: duration(block) }),
            h("button", { class: "panel-button", text: "Copy", onclick: (e: Event) => { e.stopPropagation(); void api.clipboardWrite(transcript(block)); } }),
            h("button", { class: "panel-button", text: "Copy as Markdown", onclick: (e: Event) => { e.stopPropagation(); void api.clipboardWrite("```\n" + transcript(block) + "```\n"); } }),
            block.command
              ? h("button", { class: "panel-button", text: "Run Again", onclick: (e: Event) => { e.stopPropagation(); if (this.pane.sessionId) void api.paneInput(this.pane.sessionId, block.command + "\r"); this.close(); } })
              : null,
          ),
          folded ? null : h("pre", { class: "block-output", text: (block.truncated ? "[... earlier output dropped ...]\n" : "") + block.output }),
        );
      }),
    );
  }

  close() {
    window.clearInterval(this.timer);
    this.el.remove();
    this.onClose();
  }
}
