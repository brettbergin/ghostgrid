// The app process's commands and events, typed. Everything the web view
// needs from Windows (shells, files, the clipboard, other windows) goes
// through here.
import { Channel, invoke } from "@tauri-apps/api/core";
import type { UnlistenFn } from "@tauri-apps/api/event";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import type { LayoutMode, LayoutWeights } from "./core/gridLayout";

export interface Theme {
  background: string;
  foreground: string;
  cursor?: string | null;
  cursorText?: string | null;
  selectionBackground?: string | null;
  selectionForeground?: string | null;
  palette: (string | null)[];
}

export interface TerminalSettings {
  fontFamily: string[];
  fontSizePx: number;
  themes: { light: Theme; dark: Theme };
  cursorStyle: "block" | "bar" | "underline";
  cursorBlink?: boolean | null;
  scrollbackLines: number;
  padding: { x: number; y: number; left: number; right: number; top: number; bottom: number };
  backgroundOpacity: number;
  lineHeight: number;
  mouseHideWhileTyping: boolean;
  unfocusedSplitOpacity: number;
  copyOnSelect: boolean;
  windowSaveState?: string | null;
  minimumContrast: number;
  boldIsBright: boolean;
  shellIntegration?: string | null;
  shellIntegrationFeatures?: string | null;
  confirmCloseSurface: boolean;
  unsupported: string[];
}

export interface TerminalConfig {
  path: string;
  exists: boolean;
  error?: string | null;
  settings: TerminalSettings;
}

export interface LauncherEntry {
  id: string;
  name: string;
  command: string;
  summary: string;
  program?: string | null;
}

export interface Settings {
  newPaneUsesLastShell: boolean;
  offerAppsAfterShell: boolean;
  lastShell?: string | null;
  paneGap: number;
  animationStyle: string;
  showPaneHeaders: boolean;
  defaultLayout: string;
  launcherEntries: LauncherEntry[];
  showActivityBadges: boolean;
  keepShellsRunning: boolean;
  explainFailures: boolean;
  attentionGrid: boolean;
  modelEndpoint: string;
  modelName: string;
  checkForUpdates: boolean;
  lastUpdateCheck?: number | null;
}

export interface ShellChoice {
  name: string;
  title: string;
  hotkey: string;
  executable?: string | null;
}

export interface LaunchApp {
  name: string;
  hotkey: string;
  command: string;
  summary: string;
  executable?: string | null;
}

/** A pane as the session saves it (the Swift Codable keys). */
export interface SavedPane {
  shell: string;
  workingDirectory?: string | null;
  sessionID?: string | null;
}

export interface SavedTab {
  name?: string | null;
  color?: string | null;
  panes: SavedPane[];
  focused?: number | null;
  zoomed?: number | null;
  layout?: LayoutMode | null;
  weights?: LayoutWeights | null;
  rows?: number[] | null;
  rotated?: boolean | null;
}

export interface SavedWindow {
  frame: { x: number; y: number; width: number; height: number };
  maximized?: boolean | null;
  tabs: SavedTab[];
  selectedTab?: number | null;
}

export interface InitData {
  label: string;
  init: { restore?: SavedWindow | null; openDirs: string[] };
  settings: Settings;
  config: TerminalConfig;
  shells: ShellChoice[];
  version: string;
  home: string;
  updatesConfigured: boolean;
  osBuild: number;
}

export interface PaneOpened {
  sessionId: string;
  reattached: boolean;
  local: boolean;
}

export type PaneEvent =
  | { type: "commandStarted"; block: number }
  | { type: "commandFinished"; block: number; exitCode: number | null; seconds: number | null; command: string | null }
  | { type: "cwd"; path: string }
  | { type: "notification"; title: string | null; body: string }
  | { type: "blocksChanged" }
  | { type: "exited"; code: number }
  | { type: "failure"; message: string };

export interface BlockView {
  id: number;
  command: string | null;
  exitCode: number | null;
  finished: boolean;
  truncated: boolean;
  startedAt: number;
  finishedAt: number | null;
  output: string;
  summary: string;
}

export interface ExplainUpdate {
  model?: string;
  why?: string;
  fix?: string | null;
  thinking?: boolean;
  error?: string;
  done: boolean;
}

export const api = {
  windowInit: () => invoke<InitData>("window_init"),
  setSettings: (settings: Settings) => invoke<Settings>("set_settings", { settings }),
  reloadConfig: () => invoke<TerminalConfig>("reload_config"),
  openConfig: () => invoke<void>("open_config"),
  shells: () => invoke<ShellChoice[]>("get_shells"),
  launcherApps: () => invoke<LaunchApp[]>("get_launcher_apps"),
  paneOpen: (
    spec: { sessionId?: string | null; shell: string; cwd?: string | null; cols: number; rows: number },
    data: Channel<ArrayBuffer>,
    events: Channel<PaneEvent>,
  ) => invoke<PaneOpened>("pane_open", { spec, data, events }),
  paneInput: (id: string, data: string) => invoke<void>("pane_input", { id, data }),
  paneInputBytes: (id: string, data: number[]) => invoke<void>("pane_input_bytes", { id, data }),
  paneResize: (id: string, cols: number, rows: number, width: number, height: number) =>
    invoke<void>("pane_resize", { id, cols, rows, width, height }),
  paneClose: (id: string) => invoke<void>("pane_close", { id }),
  paneRelease: (id: string) => invoke<void>("pane_release", { id }),
  paneBlocks: (id: string) => invoke<BlockView[]>("pane_blocks", { id }),
  paneInfo: (cwd: string) => invoke<{ display: string; branch: string | null }>("pane_info", { cwd }),
  explainStart: (id: string, block: number, channel: Channel<ExplainUpdate>) =>
    invoke<void>("explain_start", { id, block, channel }),
  explainCancel: (id: string) => invoke<void>("explain_cancel", { id }),
  resolveLink: (raw: string, cwd: string | null) =>
    invoke<{ kind: "url" | "file"; target: string } | null>("resolve_link", { raw, cwd }),
  openLink: (raw: string, cwd: string | null) => invoke<boolean>("open_link", { raw, cwd }),
  clipboardRead: () => invoke<string | null>("clipboard_read"),
  clipboardWrite: (text: string) => invoke<void>("clipboard_write", { text }),
  saveWindow: (value: SavedWindow) => invoke<void>("save_window", { value }),
  windowClose: () => invoke<void>("window_close"),
  quit: () => invoke<void>("app_quit"),
  newWindow: (openDirs?: string[]) => invoke<void>("new_window", { openDirs: openDirs ?? null }),
  tabToNewWindow: (tab: SavedTab, x: number, y: number) => invoke<void>("tab_to_new_window", { tab, x, y }),
  dropQuery: (kind: "tab" | "pane", x: number, y: number) =>
    invoke<{ label: string; index: number } | null>("drop_query", { kind, x, y }),
  dropAnswer: (id: number, index: number | null) => invoke<void>("drop_answer", { id, index }),
  transfer: (target: string, kind: "tab" | "pane", payload: SavedTab | SavedPane, index: number) =>
    invoke<void>("transfer", { target, kind, payload, index }),
  notify: (title: string, body: string) => invoke<void>("notify", { title, body }),
  installGg: () => invoke<string>("install_gg"),
  checkUpdate: () => invoke<{ version: string; notes: string | null } | null>("check_update"),
  installUpdate: () => invoke<void>("install_update"),
};

/** Events for this window: those sent to it, and those sent to every window
 * (a global listener would also hear what is meant for other windows). */
export function on<T>(event: string, handler: (payload: T) => void): Promise<UnlistenFn> {
  return getCurrentWebviewWindow().listen<T>(event, (e) => handler(e.payload));
}

export { Channel };
