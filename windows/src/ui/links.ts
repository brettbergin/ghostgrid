// Ctrl+click links in a terminal. The text is untrusted (a program can
// print anything), so the app process decides what opens: web, mail and
// file links, and paths that exist (relative ones against the pane's
// folder). Everything else is not a link.
import type { IBufferLine, ILink, ILinkProvider, Terminal } from "@xterm/xterm";
import { api } from "../ipc";

const URL_PATTERN = /\b(?:https?:\/\/|mailto:|file:\/\/)[^\s"'<>`]+[^\s"'<>`.,;:!?)\]}]/g;
// Windows paths (C:\x, \\server\x), home paths (~\x, ~/x) and relative
// paths with a separator (src\main.rs, ./build.ps1).
const PATH_PATTERN = /(?:[A-Za-z]:[\\/]|\\\\|~[\\/]|\.{1,2}[\\/]|[\w.-]+[\\/])[^\s"'<>|*?]*[^\s"'<>|*?.,;:!)\]}]/g;

function lineText(line: IBufferLine | undefined): string {
  return line ? line.translateToString(true) : "";
}

export class LinkProvider implements ILinkProvider {
  constructor(private term: Terminal, private cwd: () => string | null) {}

  provideLinks(y: number, callback: (links: ILink[] | undefined) => void): void {
    const text = lineText(this.term.buffer.active.getLine(y - 1));
    const candidates: { start: number; text: string }[] = [];
    for (const pattern of [URL_PATTERN, PATH_PATTERN]) {
      pattern.lastIndex = 0;
      for (let m = pattern.exec(text); m; m = pattern.exec(text)) {
        if (!candidates.some((c) => m!.index >= c.start && m!.index < c.start + c.text.length)) {
          candidates.push({ start: m.index, text: m[0] });
        }
      }
    }
    if (candidates.length === 0) {
      callback(undefined);
      return;
    }
    const cwd = this.cwd();
    Promise.all(candidates.map((c) => api.resolveLink(c.text, cwd).catch(() => null))).then((resolved) => {
      const links: ILink[] = [];
      resolved.forEach((target, i) => {
        if (!target) return;
        const c = candidates[i];
        links.push({
          text: c.text,
          range: { start: { x: c.start + 1, y }, end: { x: c.start + c.text.length, y } },
          decorations: { pointerCursor: true, underline: true },
          activate: (event) => {
            if (event.ctrlKey) void api.openLink(c.text, cwd);
          },
        });
      });
      callback(links.length ? links : undefined);
    });
  }
}
