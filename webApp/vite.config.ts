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
    alias: [{ find: "~", replacement: fileURLToPath(new URL("./src", import.meta.url)) }],
  },
  // The editor chunk sits just above the default 500 kB advisory; gzip keeps it around 175 kB.
  build: { chunkSizeWarningLimit: 550 },
  worker: { format: "es" },
  server: { fs: { allow: [".."] } },
});
