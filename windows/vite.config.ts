import { defineConfig } from "vitest/config";

// Tauri serves the built files in production; `tauri dev` points the window
// at this dev server.
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true, watch: { ignored: ["**/src-tauri/**", "**/crates/**", "**/target/**"] } },
  // xterm.js and its WebGL renderer make one large chunk; it loads from disk.
  build: { target: "es2022", outDir: "dist", emptyOutDir: true, sourcemap: false, chunkSizeWarningLimit: 1500 },
  test: { include: ["test/**/*.test.ts"], environment: "node" },
});
