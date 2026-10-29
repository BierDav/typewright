import { fileURLToPath } from "node:url";
import { solidStart } from "@solidjs/start/config";
import { nitro } from "nitro/vite";
import { defineConfig } from "vite";

// GitHub Pages serves the app below the repository's path, e.g. `/typewright/`.
const base = process.env.TYPEWRIGHT_WEB_BASE ?? "/";

export default defineConfig({
  base,
  plugins: [
    // Everything lives in the browser's origin storage, so there's nothing to render on a server.
    solidStart({ ssr: false, devOverlay: false }),
    nitro({ preset: "github-pages", baseURL: base, prerender: { routes: ["/"], crawlLinks: false } }),
  ],
  resolve: {
    alias: [
      { find: "~", replacement: fileURLToPath(new URL("./src", import.meta.url)) },
      // monaco-vim imports Monaco by paths its package exports no longer list.
      { find: /^monaco-editor\/esm\/vs\/(.*?)(\.js)?$/, replacement: fileURLToPath(new URL("./node_modules/monaco-editor/esm/vs/", import.meta.url)) + "$1.js" },
      { find: /^monaco-vim$/, replacement: fileURLToPath(new URL("./node_modules/monaco-vim/dist/index.mjs", import.meta.url)) },
    ],
  },
  build: {
    // Monaco is one large chunk (about 3.5 MB, 900 kB gzipped) of its own, cached across app updates.
    chunkSizeWarningLimit: 3600,
    rolldownOptions: { output: { codeSplitting: { groups: [{ name: "monaco", test: /node_modules[\\/]monaco-(editor|vim)[\\/]/ }] } } },
  },
  worker: { format: "es" },
  server: { fs: { allow: [".."] } },
});
