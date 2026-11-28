// Gets the native pieces ready before `tauri dev` / `tauri build` compile the
// app: builds ghostgrid-sessiond and puts it where Tauri bundles sidecars
// (src-tauri/binaries/<name>-<target triple>.exe), and draws the icons from
// app-icon.svg when they are missing or older than it.
//
//   node scripts/prepare.mjs [--release]
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const release = process.argv.includes("--release");
const run = (cmd, args) => execFileSync(cmd, args, { cwd: root, stdio: "inherit", shell: process.platform === "win32" });

const host = execFileSync("rustc", ["-vV"], { encoding: "utf8" }).match(/^host: (.+)$/m)?.[1];
if (!host) throw new Error("could not read the Rust host triple from rustc -vV");

run("cargo", ["build", "-p", "ghostgrid-sessiond", ...(release ? ["--release"] : [])]);
const exe = process.platform === "win32" ? ".exe" : "";
const built = join(root, "target", release ? "release" : "debug", `ghostgrid-sessiond${exe}`);
const binaries = join(root, "src-tauri", "binaries");
mkdirSync(binaries, { recursive: true });
copyFileSync(built, join(binaries, `ghostgrid-sessiond-${host}${exe}`));

const svg = join(root, "app-icon.svg");
const ico = join(root, "src-tauri", "icons", "icon.ico");
if (!existsSync(ico) || statSync(ico).mtimeMs < statSync(svg).mtimeMs) {
  run("npx", ["tauri", "icon", "app-icon.svg"]);
}
