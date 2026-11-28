// A ghostgrid window's web view: asks the app process what this window
// starts with, then hands over to the window controller.
import "@xterm/xterm/css/xterm.css";
import { api } from "./ipc";
import { WindowController } from "./ui/window";

async function boot() {
  const root = document.getElementById("app")!;
  // Right-click menus are ghostgrid's own; the web view's would offer
  // "Reload" and "Inspect" in a terminal.
  window.addEventListener("contextmenu", (e) => e.preventDefault());
  const data = await api.windowInit();
  new WindowController(root, data);
}

void boot();
