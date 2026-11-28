// The Ghostty config as xterm.js options and ghostgrid's chrome colors.
// Everything about how terminals look comes from the user's Ghostty config;
// the chrome (tab bar, headers, menus) follows its background and
// foreground so the window reads as one surface.
import type { ITerminalOptions, ITheme } from "@xterm/xterm";
import type { TerminalSettings, Theme } from "../ipc";

const ANSI = [
  "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
  "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
] as const;

/** Whether the system is in dark mode (Ghostty's `theme = light:A,dark:B`). */
export function prefersDark(): boolean {
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? true;
}

export function activeTheme(settings: TerminalSettings): Theme {
  return prefersDark() ? settings.themes.dark : settings.themes.light;
}

/** "#rrggbb" with an alpha, for a translucent background. */
export function withAlpha(color: string, alpha: number): string {
  const hex = /^#([0-9a-f]{6})$/i.exec(color);
  if (!hex || alpha >= 1) return color;
  const a = Math.round(Math.max(0, Math.min(1, alpha)) * 255).toString(16).padStart(2, "0");
  return `#${hex[1]}${a}`;
}

export function xtermTheme(settings: TerminalSettings): ITheme {
  const theme = activeTheme(settings);
  const out: ITheme = {
    background: withAlpha(theme.background, settings.backgroundOpacity),
    foreground: theme.foreground,
  };
  if (theme.cursor) out.cursor = theme.cursor;
  if (theme.cursorText) out.cursorAccent = theme.cursorText;
  if (theme.selectionBackground) out.selectionBackground = theme.selectionBackground;
  if (theme.selectionForeground) out.selectionForeground = theme.selectionForeground;
  theme.palette.slice(0, 16).forEach((color, index) => {
    if (color) (out as Record<string, string>)[ANSI[index]] = color;
  });
  return out;
}

function fontStack(fonts: string[]): string {
  const quoted = fonts.map((f) => (/^[\w-]+$/.test(f) ? f : `"${f.replace(/"/g, "")}"`));
  return [...quoted, "monospace"].join(", ");
}

export function xtermOptions(settings: TerminalSettings, osBuild: number): ITerminalOptions {
  return {
    fontFamily: fontStack(settings.fontFamily),
    fontSize: settings.fontSizePx,
    lineHeight: Math.max(0.8, settings.lineHeight || 1),
    theme: xtermTheme(settings),
    cursorStyle: settings.cursorStyle,
    cursorBlink: settings.cursorBlink ?? true,
    scrollback: settings.scrollbackLines,
    minimumContrastRatio: Math.max(1, settings.minimumContrast),
    drawBoldTextInBrightColors: settings.boldIsBright,
    allowTransparency: settings.backgroundOpacity < 1,
    allowProposedApi: true,
    rightClickSelectsWord: false,
    // ConPTY reflows on resize itself; xterm must not do it twice.
    windowsPty: { backend: "conpty", buildNumber: osBuild || undefined },
    macOptionIsMeta: false,
    scrollOnUserInput: true,
    smoothScrollDuration: 0,
  };
}

/** Mixes two "#rrggbb" colors, `amount` of the way from a to b. */
export function mix(a: string, b: string, amount: number): string {
  const parse = (c: string) => {
    const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(c);
    return m ? [1, 2, 3].map((i) => parseInt(m[i], 16)) : [128, 128, 128];
  };
  const [x, y] = [parse(a), parse(b)];
  return "#" + x.map((v, i) => Math.round(v + (y[i] - v) * amount).toString(16).padStart(2, "0")).join("");
}

/** Sets the chrome's CSS variables from the terminal theme. */
export function applyChrome(settings: TerminalSettings): void {
  const theme = activeTheme(settings);
  const root = document.documentElement.style;
  const bg = theme.background.startsWith("#") ? theme.background.slice(0, 7) : "#1e1e2e";
  const fg = theme.foreground.startsWith("#") ? theme.foreground.slice(0, 7) : "#cdd6f4";
  root.setProperty("--term-bg", withAlpha(bg, settings.backgroundOpacity));
  root.setProperty("--bg", bg);
  root.setProperty("--fg", fg);
  root.setProperty("--chrome", withAlpha(mix(bg, "#000000", 0.25), Math.min(1, settings.backgroundOpacity + 0.1)));
  root.setProperty("--chrome-raised", mix(bg, fg, 0.08));
  root.setProperty("--chrome-hover", mix(bg, fg, 0.14));
  root.setProperty("--muted", mix(bg, fg, 0.55));
  root.setProperty("--faint", mix(bg, fg, 0.3));
  root.setProperty("--dim-overlay", withAlpha(bg, 1 - settings.unfocusedSplitOpacity));
  root.setProperty("--font-mono", fontStack(settings.fontFamily));
}
