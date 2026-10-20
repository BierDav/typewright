import { fileURLToPath } from "node:url";
import { solidStart } from "@solidjs/start/config";
import { nitro } from "nitro/vite";
import { defineConfig } from "vite";

// GitHub Pages serves the app below the repository's path, e.g. `/typewright/`.
const base = process.env.TYPEWRIGHT_WEB_BASE ?? "/";
const core = "../sharedKotlin/build/dist/js/productionLibrary";

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
      // The Kotlin core, built by `sharedKotlin/gradlew -p sharedKotlin jsBrowserProductionLibraryDistribution`.
      { find: /^typewright-core$/, replacement: fileURLToPath(new URL(`${core}/typewright-core.mjs`, import.meta.url)) },
      { find: /^kotlin-stdlib$/, replacement: fileURLToPath(new URL(`${core}/kotlin-kotlin-stdlib.mjs`, import.meta.url)) },
    ],
  },
  worker: { format: "es" },
  optimizeDeps: { exclude: ["typewright-core", "kotlin-stdlib"] },
  server: { fs: { allow: [".."] } },
});
