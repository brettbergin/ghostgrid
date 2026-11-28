// The tab bar, in the title bar from the first tab on, so that one can be
// renamed, colored and dragged like the rest. Tabs share the bar's width
// and it scrolls when they no longer fit.
//
// Click shows a tab, a middle click or its x closes it, a double click
// renames it, a right click opens its menu. Drag along the bar to move it;
// drag it off the bar to move it to another window's bar or a window of
// its own.
import { leavesBar, TabBarLayout, TAB_COLORS, type TabColor } from "../core/tabs";
import { h, ICONS, svgIcon } from "./dom";

export interface TabInfo {
  title: string;
  color: TabColor | null;
  badge: { text: string; kind: string } | null;
  active: boolean;
  broadcast: boolean;
}

export interface TabBarActions {
  select(index: number): void;
  close(index: number): void;
  rename(index: number, name: string | null): void;
  contextMenu(index: number, e: MouseEvent): void;
  move(from: number, to: number): void;
  /** A tab let go off the bar, at this pointer position. */
  tearOff(index: number, e: PointerEvent): void;
  newTab(): void;
}

const layout = new TabBarLayout({ minimumWidth: 110, maximumWidth: 220, spacing: 2 });

export class TabBar {
  readonly el: HTMLDivElement;
  private strip: HTMLDivElement;
  private items: HTMLDivElement[] = [];
  private infos: TabInfo[] = [];
  private renaming: number | null = null;
  private dragging = false;

  constructor(private actions: TabBarActions) {
    this.strip = h("div", { class: "tab-strip" });
    const add = h("button", { class: "tab-new", title: "New tab (Ctrl+Shift+T)", onclick: () => actions.newTab() }, svgIcon(ICONS.plus));
    this.el = h("div", { class: "tab-bar" }, this.strip, add);
    this.strip.addEventListener("wheel", (e) => {
      this.strip.scrollLeft += e.deltaY + e.deltaX;
    }, { passive: true });
    new ResizeObserver(() => this.layoutTabs()).observe(this.strip);
  }

  render(tabs: TabInfo[]) {
    this.infos = tabs;
    // Mid-rename or mid-drag the elements must stay as they are (a
    // replaced element loses its pointer capture and double clicks); the
    // next render after the gesture catches up.
    if (this.renaming !== null || this.dragging) return;
    // The same number of tabs: update them in place, so elements (and the
    // gestures on them) survive the many refreshes a window makes.
    if (this.items.length !== tabs.length) {
      this.strip.replaceChildren();
      this.items = tabs.map((_, index) => this.makeItem(index));
      this.strip.append(...this.items);
    }
    tabs.forEach((tab, index) => this.fill(this.items[index], tab, index));
    this.layoutTabs();
    this.items.find((_, i) => tabs[i].active)?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  private makeItem(index: number): HTMLDivElement {
    const el = h("div", { class: "tab", role: "tab" });
    el.addEventListener("pointerdown", (e) => this.pointerDown(index, e));
    el.addEventListener("auxclick", (e) => {
      if (e.button === 1) {
        e.preventDefault();
        this.actions.close(index);
      }
    });
    el.addEventListener("dblclick", () => this.startRename(index));
    el.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      this.actions.contextMenu(index, e);
    });
    return el;
  }

  private fill(el: HTMLDivElement, tab: TabInfo, index: number) {
    const close = h("button", { class: "tab-close", title: "Close tab" }, svgIcon(ICONS.close, 12));
    close.addEventListener("pointerdown", (e) => e.stopPropagation());
    close.addEventListener("click", (e) => {
      e.stopPropagation();
      this.actions.close(index);
    });
    el.className = "tab" + (tab.active ? " active" : "") + (tab.broadcast ? " broadcast" : "");
    el.title = tab.title;
    if (tab.color) el.style.setProperty("--tab-color", TAB_COLORS[tab.color]);
    else el.style.removeProperty("--tab-color");
    el.replaceChildren(
      ...[
        tab.color ? h("span", { class: "tab-color", style: `background:${TAB_COLORS[tab.color]}` }) : null,
        h("span", { class: "tab-title", text: tab.title }),
        tab.badge ? h("span", { class: `badge ${tab.badge.kind}`, text: tab.badge.text }) : null,
        close,
      ].filter((n): n is HTMLElement => n !== null),
    );
  }

  private layoutTabs() {
    const width = layout.tabWidth(this.items.length, this.strip.clientWidth);
    for (const item of this.items) item.style.width = `${width}px`;
  }

  private pointerDown(index: number, e: PointerEvent) {
    if (e.button !== 0) return;
    const el = this.items[index];
    const startX = e.clientX;
    let dragging = false;
    let torn = false;
    el.setPointerCapture(e.pointerId);
    const barRect = () => this.strip.getBoundingClientRect();
    const moveHandler = (m: PointerEvent) => {
      if (!dragging && Math.abs(m.clientX - startX) < 5 && Math.abs(m.clientY - e.clientY) < 5) return;
      dragging = true;
      this.dragging = true;
      const rect = barRect();
      torn = leavesBar(m.clientY - rect.top, rect.height) || m.clientX < rect.left - 40 || m.clientX > rect.right + 40;
      el.classList.add("dragging");
      el.classList.toggle("torn", torn);
      el.style.transform = torn ? `translate(${m.clientX - startX}px, ${m.clientY - e.clientY}px)` : `translateX(${m.clientX - startX}px)`;
    };
    const up = (u: PointerEvent) => {
      el.removeEventListener("pointermove", moveHandler);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
      el.style.transform = "";
      el.classList.remove("dragging", "torn");
      this.dragging = false;
      if (!dragging) {
        this.actions.select(index);
        return;
      }
      if (torn) {
        this.actions.tearOff(index, u);
        return;
      }
      const rect = barRect();
      const middle = el.offsetLeft - this.strip.scrollLeft + el.offsetWidth / 2 + (u.clientX - startX);
      const to = layout.dropIndex(middle + this.strip.scrollLeft, this.items.length, Math.max(rect.width, layout.contentWidth(this.items.length, rect.width)));
      if (to !== index) this.actions.move(index, to);
    };
    el.addEventListener("pointermove", moveHandler);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
  }

  startRename(index: number) {
    const el = this.items[index];
    if (!el) return;
    this.renaming = index;
    const title = el.querySelector(".tab-title") as HTMLElement;
    const input = h("input", { class: "tab-rename", value: this.infos[index].title, spellcheck: "false" });
    title.replaceWith(input);
    input.select();
    input.focus();
    let done = false;
    const finish = (keep: boolean) => {
      if (done) return;
      done = true;
      this.renaming = null;
      if (keep) this.actions.rename(index, input.value);
      else this.fill(this.items[index], this.infos[index], index);
    };
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") finish(true);
      else if (e.key === "Escape") finish(false);
    });
    input.addEventListener("blur", () => finish(true));
    input.addEventListener("pointerdown", (e) => e.stopPropagation());
  }

  /** The tab under a point (client coordinates), for dropping a pane on it. */
  tabAt(x: number, y: number): number | null {
    const rect = this.el.getBoundingClientRect();
    if (y < rect.top || y > rect.bottom) return null;
    const index = this.items.findIndex((item) => {
      const r = item.getBoundingClientRect();
      return x >= r.left && x <= r.right;
    });
    return index >= 0 ? index : null;
  }

  /** Where a tab dropped from another window goes, or null when the point
   * is not on the bar. */
  insertIndexAt(x: number, y: number): number | null {
    const rect = this.el.getBoundingClientRect();
    if (y < rect.top - 8 || y > rect.bottom + 8 || x < rect.left || x > rect.right) return null;
    const local = x - this.strip.getBoundingClientRect().left + this.strip.scrollLeft;
    return layout.insertIndex(local, this.items.length, this.strip.clientWidth);
  }

  highlight(index: number | null) {
    this.items.forEach((item, i) => item.classList.toggle("drop-target", i === index));
  }
}
