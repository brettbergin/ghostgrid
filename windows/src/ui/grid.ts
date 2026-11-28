// One tab: its grid of panes and how they are arranged (layout, divider
// weights, moved rows, rotation, zoom, broadcast, attention).
//
// Every change animates: each pane's frame moves along the style's curve
// while its terminal, already at its final size, is scaled uniformly to
// cover the moving box (ContentScale). A new pane launches as a small card
// out of the pane you were in and lands with a flash.
import { animationCurve, animationDuration, animationFromStored, clampedGap, CubicBezier, coverScale } from "../core/animation";
import { attentionLevel, attentionWeights } from "../core/attention";
import type { Point, Rect } from "../core/geometry";
import { drag as dragWeights, frames as layoutFrames, indexAt, layoutFromStored, move, neighbor, nextLayout, splitters, type Direction, type LayoutMode, type LayoutWeights, type SplitterKind } from "../core/gridLayout";
import type { TabColor } from "../core/tabs";
import { isTabColor } from "../core/tabs";
import type { SavedTab } from "../ipc";
import { h } from "./dom";
import { PaneView, type PaneHost, type StartSpec } from "./pane";

/** What a tab needs from its window, beyond what panes need. */
export interface GridHost {
  paneHost(grid: TabGrid): PaneHost;
  gridChanged(grid: TabGrid): void;
  /** A pane dragged by its header was let go: the window may take it
   * (onto a tab, or into another window); false: the grid handles it. */
  paneDropped(grid: TabGrid, pane: PaneView, e: PointerEvent): Promise<boolean>;
  paneDragMoved(grid: TabGrid, e: PointerEvent | null): void;
  emptied(grid: TabGrid): void;
  attentionEnabled(): boolean;
}

const SOFT = new CubicBezier(0.25, 0.1, 0.25, 1);
const MINIMUM_PANE = 100;

interface Animation {
  start: number;
  duration: number;
  curve: CubicBezier;
  from: Rect[];
  to: Rect[];
  fresh: Set<PaneView>;
}

function lerp(a: Rect, b: Rect, p: number): Rect {
  return { x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p, width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p };
}

function sameWeights(a: LayoutWeights | null, b: LayoutWeights | null): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

export class TabGrid {
  readonly el: HTMLDivElement;
  panes: PaneView[] = [];
  focused = 0;
  zoomed: number | null = null;
  mode: LayoutMode;
  /** Divider drags; null: balanced (or the attention grid's). */
  weights: LayoutWeights | null = null;
  rows: number[] | null = null;
  rotated = false;
  broadcast = false;
  name: string | null = null;
  color: TabColor | null = null;
  /** When you last looked at this tab, for its badge. */
  lastSeen: number | null = Date.now();
  /** A divider drag pauses the attention grid until Equalize. */
  attentionPaused = false;
  private attention: LayoutWeights | null = null;
  private shown: Rect[] = [];
  private animation: Animation | null = null;
  private splitterEls: HTMLDivElement[] = [];
  /** What each divider element drags (updated in place, so a drag or a
   * double click survives a relayout). */
  private splitterData: { kind: SplitterKind; vertical: boolean }[] = [];
  private resizeObserver: ResizeObserver;
  private dropHighlight: number[] = [];

  constructor(private host: GridHost, defaultLayout: string) {
    this.mode = layoutFromStored(defaultLayout);
    this.el = h("div", { class: "grid" });
    this.resizeObserver = new ResizeObserver(() => this.layout(false));
    this.resizeObserver.observe(this.el);
  }

  // ---- panes ----------------------------------------------------------------

  get focusedPane(): PaneView | null {
    return this.panes[this.focused] ?? null;
  }

  /** A new pane right after the focused one, launched out of it. */
  addPane(start: StartSpec, at?: number): PaneView {
    const pane = new PaneView(this.host.paneHost(this), start);
    const index = at ?? (this.panes.length === 0 ? 0 : this.focused + 1);
    const source = this.shown[this.focused];
    this.panes.splice(index, 0, pane);
    this.el.append(pane.el);
    const origin = source ?? this.bounds();
    const card: Rect = { x: origin.x + origin.width * 0.35, y: origin.y + origin.height * 0.35, width: origin.width * 0.3, height: origin.height * 0.3 };
    this.shown.splice(index, 0, card);
    this.focused = index;
    this.zoomed = null;
    this.layout(this.panes.length > 1, new Set([pane]));
    this.focusPaneAt(index);
    return pane;
  }

  /** A pane arriving from another tab or window. */
  adoptPane(pane: PaneView, at = this.panes.length) {
    pane.rehost(this.host.paneHost(this));
    this.panes.splice(at, 0, pane);
    this.el.append(pane.el);
    this.shown.splice(at, 0, this.bounds());
    this.focused = at;
    this.zoomed = null;
    this.layout(true);
  }

  /** Takes a pane out without ending its shell (it moves elsewhere). */
  detachPane(pane: PaneView): PaneView | null {
    const index = this.panes.indexOf(pane);
    if (index < 0) return null;
    this.panes.splice(index, 1);
    this.shown.splice(index, 1);
    pane.el.remove();
    this.afterRemoval(index);
    return pane;
  }

  removePane(pane: PaneView, terminate: boolean) {
    const index = this.panes.indexOf(pane);
    if (index < 0) return;
    this.panes.splice(index, 1);
    this.shown.splice(index, 1);
    pane.el.classList.add("closing");
    pane.dispose(terminate, 120);
    this.afterRemoval(index);
  }

  private afterRemoval(index: number) {
    if (this.zoomed !== null) this.zoomed = this.zoomed === index ? null : this.zoomed > index ? this.zoomed - 1 : this.zoomed;
    if (this.focused >= index && this.focused > 0) this.focused -= 1;
    this.focused = Math.min(this.focused, Math.max(this.panes.length - 1, 0));
    if (this.panes.length === 0) {
      this.host.emptied(this);
      return;
    }
    this.layout(true);
    this.focusPaneAt(this.focused);
  }

  focusPaneAt(index: number) {
    const pane = this.panes[index];
    if (!pane) return;
    this.focused = index;
    for (const p of this.panes) p.el.classList.toggle("focused", p === pane);
    pane.seen();
    pane.focus();
    this.host.gridChanged(this);
  }

  focusPane(pane: PaneView) {
    const index = this.panes.indexOf(pane);
    if (index >= 0 && (index !== this.focused || document.activeElement === document.body)) this.focusPaneAt(index);
    else if (index >= 0) pane.seen();
  }

  /** Next/previous pane; while zoomed, the zoom follows (you never type
   * into a pane you cannot see). */
  focusNext(step: number) {
    if (this.panes.length === 0) return;
    this.focusNumber((((this.focused + step) % this.panes.length) + this.panes.length) % this.panes.length);
  }

  /** Focus Pane N (and the zoom with it, while zoomed). */
  focusNumber(index: number) {
    if (!this.panes[index]) return;
    if (this.zoomed !== null && this.zoomed !== index) {
      this.zoomed = index;
      this.focused = index;
      this.layout(true);
    }
    this.focusPaneAt(index);
  }

  focusDirection(direction: Direction) {
    if (this.zoomed !== null) return;
    const target = neighbor(this.focused, this.targetFrames(), direction);
    if (target !== null) this.focusPaneAt(target);
  }

  swap(direction: Direction) {
    if (this.zoomed !== null) return;
    const target = neighbor(this.focused, this.targetFrames(), direction);
    if (target !== null) this.rearrange(this.focused, target);
  }

  /** Moving pane `from` onto pane `to` (a swap or a drop). */
  rearrange(from: number, to: number) {
    const moved = move(from, to, { count: this.panes.length, mode: this.mode, rows: this.rows, weights: this.weights });
    const focusedPane = this.panes[this.focused];
    const zoomedPane = this.zoomed === null ? null : this.panes[this.zoomed];
    this.panes = moved.order.map((i) => this.panes[i]);
    this.shown = moved.order.map((i) => this.shown[i]);
    this.rows = moved.rows;
    this.weights = moved.weights;
    this.attention = null;
    this.focused = Math.max(0, this.panes.indexOf(focusedPane));
    this.zoomed = zoomedPane ? this.panes.indexOf(zoomedPane) : null;
    this.layout(true);
    this.focusPaneAt(this.panes.indexOf(focusedPane));
  }

  makeMain() {
    if (this.focused === 0 || this.panes.length < 2 || this.zoomed !== null) return;
    const pane = this.panes.splice(this.focused, 1)[0];
    const frame = this.shown.splice(this.focused, 1)[0];
    this.panes.unshift(pane);
    this.shown.unshift(frame);
    this.rows = null;
    this.focused = 0;
    this.layout(true);
    this.focusPaneAt(0);
  }

  toggleZoom() {
    this.zoomed = this.zoomed === null && this.panes.length > 1 ? this.focused : null;
    this.layout(true);
    this.focusPaneAt(this.focused);
  }

  cycleLayout() {
    this.mode = nextLayout(this.mode);
    this.weights = null;
    this.rows = null;
    this.attention = null;
    this.layout(true);
    this.host.gridChanged(this);
  }

  setLayout(mode: LayoutMode) {
    this.mode = mode;
    this.weights = null;
    this.rows = null;
    this.attention = null;
    this.layout(true);
    this.host.gridChanged(this);
  }

  rotate() {
    this.rotated = !this.rotated;
    this.layout(true);
    this.host.gridChanged(this);
  }

  equalize() {
    this.weights = null;
    this.attentionPaused = false;
    this.attention = null;
    this.layout(true);
    this.host.gridChanged(this);
  }

  // ---- layout ---------------------------------------------------------------

  private bounds(): Rect {
    return { x: 0, y: 0, width: this.el.clientWidth, height: this.el.clientHeight };
  }

  private gap(): number {
    return clampedGap(this.host.paneHost(this).settings().paneGap);
  }

  private effectiveWeights(): LayoutWeights | null {
    return this.weights ?? (this.host.attentionEnabled() && !this.attentionPaused ? this.attention : null);
  }

  targetFrames(): Rect[] {
    const bounds = this.bounds();
    const gap = this.gap();
    return layoutFrames({ count: this.panes.length, bounds, gap, mode: this.mode, weights: this.effectiveWeights(), rows: this.rows, rotated: this.rotated });
  }

  /** Lays the panes out, animated or at once. `fresh`: panes just added
   * (they land with a flash). */
  layout(animated: boolean, fresh: Set<PaneView> = new Set(), curve?: CubicBezier, seconds?: number) {
    const bounds = this.bounds();
    if (bounds.width <= 0 || bounds.height <= 0 || this.panes.length === 0) return;
    const gap = this.gap();
    let to = this.targetFrames();
    if (this.zoomed !== null && this.panes[this.zoomed]) {
      const full: Rect = { x: gap, y: gap, width: bounds.width - gap * 2, height: bounds.height - gap * 2 };
      to = to.map((frame, i) => (i === this.zoomed ? full : frame));
    }
    this.panes.forEach((pane, i) => {
      pane.el.classList.toggle("zoom-hidden", this.zoomed !== null && i !== this.zoomed);
      pane.setContentSize(to[i].width, to[i].height);
    });
    const style = animationFromStored(this.host.paneHost(this).settings().animationStyle);
    const useCurve = curve ?? animationCurve(style);
    const duration = (seconds ?? animationDuration(style)) * 1000;
    if (!animated || !useCurve || duration <= 0 || this.shown.length !== to.length || document.hidden) {
      this.animation = null;
      this.apply(to, to, 1);
      this.finish(fresh);
      return;
    }
    const from = this.shown.map((f, i) => f ?? to[i]);
    this.animation = { start: performance.now(), duration, curve: useCurve, from, to, fresh };
    const step = (now: number) => {
      const animation = this.animation;
      if (!animation) return;
      const t = Math.min(1, (now - animation.start) / animation.duration);
      this.apply(animation.from, animation.to, animation.curve.progress(t));
      if (t < 1) requestAnimationFrame(step);
      else {
        this.animation = null;
        this.finish(animation.fresh);
      }
    };
    requestAnimationFrame(step);
  }

  private apply(from: Rect[], to: Rect[], progress: number) {
    this.panes.forEach((pane, i) => {
      const frame = progress >= 1 ? to[i] : lerp(from[i], to[i], progress);
      this.shown[i] = frame;
      const s = pane.el.style;
      s.transform = `translate(${frame.x}px, ${frame.y}px)`;
      s.width = `${Math.max(0, frame.width)}px`;
      s.height = `${Math.max(0, frame.height)}px`;
      if (progress >= 1) {
        pane.setContentScale(null);
      } else {
        const header = pane.headerHeight();
        const scale = coverScale(
          { width: from[i].width, height: Math.max(1, from[i].height - header) },
          { width: Math.max(1, to[i].width), height: Math.max(1, to[i].height - header) },
          progress,
        );
        pane.setContentScale(scale);
      }
    });
  }

  private finish(fresh: Set<PaneView>) {
    for (const pane of fresh) {
      pane.el.classList.remove("landed");
      void pane.el.offsetWidth;
      pane.el.classList.add("landed");
    }
    this.renderSplitters();
  }

  // ---- dividers -------------------------------------------------------------

  private renderSplitters() {
    const opts = { count: this.panes.length, bounds: this.bounds(), gap: this.gap(), mode: this.mode, weights: this.effectiveWeights(), rows: this.rows, rotated: this.rotated };
    const list = this.zoomed !== null ? [] : splitters(opts);
    while (this.splitterEls.length > list.length) this.splitterEls.pop()!.remove();
    while (this.splitterEls.length < list.length) {
      const index = this.splitterEls.length;
      const el = h("div", { class: "splitter" });
      el.addEventListener("pointerdown", (e) => {
        const data = this.splitterData[index];
        if (data) this.dragSplitter(data.kind, data.vertical, e, el);
      });
      el.addEventListener("dblclick", () => this.equalize());
      this.el.append(el);
      this.splitterEls.push(el);
    }
    this.splitterData = list.map((splitter, i) => {
      const vertical = splitter.rect.height > splitter.rect.width;
      const el = this.splitterEls[i];
      el.className = "splitter " + (vertical ? "vertical" : "horizontal");
      Object.assign(el.style, {
        left: `${splitter.rect.x}px`,
        top: `${splitter.rect.y}px`,
        width: `${splitter.rect.width}px`,
        height: `${splitter.rect.height}px`,
      });
      return { kind: splitter.kind, vertical };
    });
  }

  private dragSplitter(kind: SplitterKind, vertical: boolean, e: PointerEvent, el: HTMLElement) {
    if (e.button !== 0) return;
    e.preventDefault();
    el.setPointerCapture(e.pointerId);
    const start = vertical ? e.clientX : e.clientY;
    const base = this.effectiveWeights();
    const opts = { count: this.panes.length, bounds: this.bounds(), gap: this.gap(), mode: this.mode, rows: this.rows, rotated: this.rotated, minimum: MINIMUM_PANE };
    const moveHandler = (m: PointerEvent) => {
      const delta = (vertical ? m.clientX : m.clientY) - start;
      this.weights = dragWeights(kind, delta, { ...opts, weights: base });
      this.attentionPaused = true;
      this.layout(false);
    };
    const up = () => {
      el.removeEventListener("pointermove", moveHandler);
      el.removeEventListener("pointerup", up);
      this.host.gridChanged(this);
    };
    el.addEventListener("pointermove", moveHandler);
    el.addEventListener("pointerup", up);
  }

  // ---- dragging panes by their headers --------------------------------------

  headerPointerDown(pane: PaneView, e: PointerEvent) {
    if (e.button !== 0) return;
    const header = e.currentTarget as HTMLElement;
    const startX = e.clientX;
    const startY = e.clientY;
    let dragging = false;
    let ghost: HTMLDivElement | null = null;
    let target: number | null = null;
    header.setPointerCapture(e.pointerId);
    const local = (m: PointerEvent): Point => {
      const rect = this.el.getBoundingClientRect();
      return { x: m.clientX - rect.left, y: m.clientY - rect.top };
    };
    const moveHandler = (m: PointerEvent) => {
      if (!dragging && Math.hypot(m.clientX - startX, m.clientY - startY) < 5) return;
      if (!dragging) {
        dragging = true;
        pane.el.classList.add("dragging");
        ghost = h("div", { class: "drag-ghost", text: pane.saved()?.shell ?? "pane" });
        document.body.append(ghost);
      }
      ghost!.style.transform = `translate(${m.clientX + 12}px, ${m.clientY + 8}px)`;
      const from = this.panes.indexOf(pane);
      target = indexAt(local(m), this.shown, from);
      const displaced = target === null ? [] : move(from, target, { count: this.panes.length, mode: this.mode, rows: this.rows, weights: this.weights }).displaced;
      this.highlight(displaced);
      this.host.paneDragMoved(this, m);
    };
    const up = async (u: PointerEvent) => {
      header.removeEventListener("pointermove", moveHandler);
      header.removeEventListener("pointerup", up);
      header.removeEventListener("pointercancel", up);
      ghost?.remove();
      pane.el.classList.remove("dragging");
      this.highlight([]);
      this.host.paneDragMoved(this, null);
      if (!dragging) return;
      if (await this.host.paneDropped(this, pane, u)) return;
      const from = this.panes.indexOf(pane);
      if (target !== null && from >= 0) this.rearrange(from, target);
    };
    header.addEventListener("pointermove", moveHandler);
    header.addEventListener("pointerup", up);
    header.addEventListener("pointercancel", up);
  }

  private highlight(indices: number[]) {
    for (const i of this.dropHighlight) this.panes[i]?.el.classList.remove("drop-target");
    this.dropHighlight = indices;
    for (const i of indices) this.panes[i]?.el.classList.add("drop-target");
  }

  // ---- attention grid -------------------------------------------------------

  /** Grows panes that want you or just printed, shrinks idle ones; moves
   * only when some pane's level changed, on a soft ease. */
  tickAttention(now: number) {
    if (!this.host.attentionEnabled() || this.attentionPaused || this.weights || this.zoomed !== null || this.panes.length < 2) {
      if (this.attention && !this.host.attentionEnabled()) {
        this.attention = null;
        this.layout(true, new Set(), SOFT, 0.6);
      }
      return;
    }
    const levels = this.panes.map((pane, i) => attentionLevel({ lastOutput: pane.lastOutput, waiting: pane.waiting, focused: i === this.focused, now }));
    const next = attentionWeights(levels, this.mode, this.rows);
    if (sameWeights(next, this.attention)) return;
    this.attention = next;
    this.layout(true, new Set(), SOFT, 0.6);
  }

  // ---- state ----------------------------------------------------------------

  setBroadcast(on: boolean) {
    this.broadcast = on;
    this.el.classList.toggle("broadcast", on);
    this.host.gridChanged(this);
  }

  saved(): SavedTab {
    return {
      name: this.name,
      color: this.color,
      panes: this.panes.map((p) => p.saved()).filter((p): p is NonNullable<typeof p> => p !== null),
      focused: this.focused,
      zoomed: this.zoomed,
      layout: this.mode,
      weights: this.weights,
      rows: this.rows,
      rotated: this.rotated || null,
    };
  }

  /** Rebuilds a saved tab: each pane attaches to its kept shell, or starts
   * its shell again in its folder. */
  restore(tab: SavedTab) {
    this.name = tab.name ?? null;
    this.color = isTabColor(tab.color) ? tab.color : null;
    this.mode = layoutFromStored(tab.layout);
    this.weights = tab.weights ?? null;
    this.rows = tab.rows ?? null;
    this.rotated = !!tab.rotated;
    for (const saved of tab.panes) {
      const pane = new PaneView(this.host.paneHost(this), {
        kind: "shell",
        shell: saved.shell,
        cwd: saved.workingDirectory ?? null,
        sessionId: saved.sessionID ?? null,
      });
      this.panes.push(pane);
      this.el.append(pane.el);
      this.shown.push(this.bounds());
    }
    this.focused = Math.min(tab.focused ?? 0, Math.max(0, this.panes.length - 1));
    this.zoomed = tab.zoomed ?? null;
    requestAnimationFrame(() => {
      this.layout(false);
      if (this.el.isConnected) this.focusPaneAt(this.focused);
    });
  }

  applySettings() {
    for (const pane of this.panes) pane.updateHeader();
    this.layout(false);
  }

  private visible: boolean | null = null;

  /** Shows or hides the tab (only the selected tab shows). */
  show(visible: boolean) {
    if (this.visible === visible) return;
    this.visible = visible;
    this.el.classList.toggle("hidden", !visible);
    if (visible) {
      this.lastSeen = Date.now();
      requestAnimationFrame(() => {
        this.layout(false);
        this.focusPaneAt(this.focused);
      });
    }
  }

  dispose(terminate: boolean) {
    this.resizeObserver.disconnect();
    for (const pane of this.panes) pane.dispose(terminate);
    this.panes = [];
    this.el.remove();
  }
}
