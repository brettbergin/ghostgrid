// Popup menus: the app menu (the button left of the tabs, Windows has no
// menu bar here), tab and pane context menus. Keyboard: Up/Down, Right
// opens a submenu, Left/Escape closes, Return picks.
import { h } from "./dom";

export type MenuItem =
  | { label: string; shortcut?: string; action?: () => void; disabled?: boolean; checked?: boolean; submenu?: MenuItem[]; swatch?: string }
  | "separator";

let openMenu: PopupMenu | null = null;

export function closeMenus(): void {
  openMenu?.close();
}

export function showMenu(items: MenuItem[], x: number, y: number, onClose?: () => void): void {
  closeMenus();
  openMenu = new PopupMenu(items, x, y, null, onClose);
}

class PopupMenu {
  el: HTMLDivElement;
  private child: PopupMenu | null = null;
  private active = -1;
  private rows: { el: HTMLElement; item: Exclude<MenuItem, "separator"> }[] = [];
  private keyHandler = (e: KeyboardEvent) => this.key(e);
  private outside = (e: PointerEvent) => {
    if (!(e.target instanceof Node) || !this.contains(e.target)) this.close();
  };

  constructor(items: MenuItem[], x: number, y: number, private parent: PopupMenu | null, private onClose?: () => void) {
    this.el = h("div", { class: "menu", role: "menu" });
    for (const item of items) {
      if (item === "separator") {
        this.el.append(h("div", { class: "menu-separator" }));
        continue;
      }
      const row = h(
        "div",
        { class: "menu-item" + (item.disabled ? " disabled" : ""), role: "menuitem" },
        h("span", { class: "menu-check", text: item.checked ? "✓" : "" }),
        item.swatch ? h("span", { class: "menu-swatch", style: `background:${item.swatch}` }) : null,
        h("span", { class: "menu-label", text: item.label }),
        h("span", { class: "menu-shortcut", text: item.submenu ? "›" : item.shortcut ?? "" }),
      );
      const index = this.rows.length;
      row.addEventListener("pointerenter", () => this.highlight(index, true));
      row.addEventListener("click", (e) => {
        e.stopPropagation();
        this.activate(index);
      });
      this.rows.push({ el: row, item });
      this.el.append(row);
    }
    document.body.append(this.el);
    const rect = this.el.getBoundingClientRect();
    const left = Math.min(x, window.innerWidth - rect.width - 4);
    const top = Math.min(y, window.innerHeight - rect.height - 4);
    this.el.style.left = `${Math.max(4, left)}px`;
    this.el.style.top = `${Math.max(4, top)}px`;
    if (!parent) {
      window.addEventListener("keydown", this.keyHandler, true);
      setTimeout(() => window.addEventListener("pointerdown", this.outside, true));
      window.addEventListener("blur", () => this.close(), { once: true });
    }
  }

  private contains(node: Node): boolean {
    return this.el.contains(node) || (this.child?.contains(node) ?? false);
  }

  private highlight(index: number, openSub: boolean) {
    this.rows.forEach((r, i) => r.el.classList.toggle("active", i === index));
    this.active = index;
    this.child?.close();
    this.child = null;
    const row = this.rows[index];
    if (openSub && row?.item.submenu && !row.item.disabled) this.openSubmenu(index);
  }

  private openSubmenu(index: number) {
    const row = this.rows[index];
    if (!row.item.submenu) return;
    const rect = row.el.getBoundingClientRect();
    this.child = new PopupMenu(row.item.submenu, rect.right - 2, rect.top - 4, this);
  }

  private activate(index: number) {
    const row = this.rows[index];
    if (!row || row.item.disabled) return;
    if (row.item.submenu) {
      this.highlight(index, true);
      return;
    }
    const action = row.item.action;
    this.root().close();
    action?.();
  }

  private root(): PopupMenu {
    return this.parent ? this.parent.root() : this;
  }

  private deepest(): PopupMenu {
    return this.child ? this.child.deepest() : this;
  }

  private key(e: KeyboardEvent) {
    const menu = this.deepest();
    e.preventDefault();
    e.stopPropagation();
    const enabled = menu.rows.map((r, i) => (r.item.disabled ? -1 : i)).filter((i) => i >= 0);
    const position = enabled.indexOf(menu.active);
    switch (e.key) {
      case "ArrowDown":
        menu.highlight(enabled[(position + 1) % enabled.length], false);
        break;
      case "ArrowUp":
        menu.highlight(enabled[(position - 1 + enabled.length) % enabled.length], false);
        break;
      case "ArrowRight":
        if (menu.rows[menu.active]?.item.submenu) {
          menu.openSubmenu(menu.active);
          menu.child?.highlight(0, false);
        }
        break;
      case "ArrowLeft":
        if (menu.parent) {
          menu.parent.child = null;
          menu.close();
        }
        break;
      case "Escape":
        if (menu.parent) {
          menu.parent.child = null;
          menu.close();
        } else {
          this.close();
        }
        break;
      case "Enter":
      case " ":
        if (menu.active >= 0) menu.activate(menu.active);
        break;
    }
  }

  close() {
    this.child?.close();
    this.child = null;
    this.el.remove();
    if (!this.parent) {
      window.removeEventListener("keydown", this.keyHandler, true);
      window.removeEventListener("pointerdown", this.outside, true);
      if (openMenu === this) openMenu = null;
      this.onClose?.();
    }
  }
}
