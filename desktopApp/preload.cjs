// The few things the web app asks of the desktop window. Preloads are CommonJS.
const { contextBridge, ipcRenderer } = require("electron");
const fs = require("node:fs");
const path = require("node:path");

// MARK: - Library on disk

// The web app's storage over the library folder (`webApp/src/lib/disk.ts` has the same operations for workers).
// Paths are relative to the folder and can't leave it; errors carry only their errno code.
const library = process.env.TYPEWRIGHT_LIBRARY;
const SPACES = "Spaces";

function abs(rel) {
  const parts = String(rel).split("/").filter(Boolean);
  if (parts.some((p) => p === "." || p === "..")) throw new Error("EACCES");
  if (parts[0] === "spaces") parts[0] = SPACES;
  return path.join(library, ...parts);
}

/** The storage path of a file in the folder, or null for the repository's and the jj host's own files. */
function storagePath(rel) {
  const parts = rel.split(path.sep).filter(Boolean);
  if (parts[0] === SPACES) parts[0] = "spaces";
  if (parts[0] === "jj-host" || parts[0] === ".migrated" || (parts[0] === "spaces" && parts[1] === ".jj")) return null;
  return parts.join("/");
}

const wrap = (body) => async (...args) => {
  try {
    return await body(...args);
  } catch (err) {
    throw new Error(err?.code ?? String(err?.message ?? err));
  }
};

/** What this window wrote last, so the watcher doesn't report the app's own writes back to it. */
const written = new Map();

async function remember(rel) {
  try {
    written.set(storagePath(path.relative(library, abs(rel))), (await fs.promises.stat(abs(rel))).mtimeMs);
  } catch {}
}

const storage = library && {
  library,
  stat: wrap(async (rel) => {
    try {
      const info = await fs.promises.stat(abs(rel));
      return { dir: info.isDirectory(), size: info.size, mtime: info.mtimeMs };
    } catch (err) {
      if (err.code === "ENOENT") return null;
      throw err;
    }
  }),
  list: wrap(async (rel) => (await fs.promises.readdir(abs(rel), { withFileTypes: true })).map((e) => ({ name: e.name, dir: e.isDirectory() || (e.isSymbolicLink() && fs.statSync(path.join(abs(rel), e.name)).isDirectory()) }))),
  read: wrap(async (rel) => new Uint8Array(await fs.promises.readFile(abs(rel)))),
  write: wrap(async (rel, data) => {
    await fs.promises.writeFile(abs(rel), data);
    await remember(rel);
  }),
  mkdir: wrap(async (rel) => void (await fs.promises.mkdir(abs(rel), { recursive: true }))),
  remove: wrap(async (rel, recursive) => {
    await fs.promises.rm(abs(rel), { recursive, force: false });
    written.set(storagePath(path.relative(library, abs(rel))), -1);
  }),
  rename: wrap(async (from, to) => {
    await fs.promises.rename(abs(from), abs(to));
    written.set(storagePath(path.relative(library, abs(from))), -1);
    await remember(to);
  }),
  /** Calls `listener` with the storage paths other programs changed, a moment after they settle. */
  watch(listener) {
    const pending = new Set();
    let timer;
    const flush = async () => {
      timer = undefined;
      const paths = [];
      for (const rel of pending) {
        const info = await fs.promises.stat(abs(rel)).catch(() => null);
        const own = written.get(rel);
        if (own !== undefined && own === (info ? info.mtimeMs : -1)) continue;
        written.delete(rel);
        paths.push(rel);
      }
      pending.clear();
      if (paths.length) listener(paths);
    };
    const watcher = fs.watch(library, { recursive: true }, (_event, file) => {
      const rel = file && storagePath(String(file));
      if (!rel) return;
      pending.add(rel);
      clearTimeout(timer);
      timer = setTimeout(flush, 150);
    });
    watcher.on("error", () => {});
  },
};

contextBridge.exposeInMainWorld("typewrightDesktop", {
  platform: process.platform,
  packageLinks: () => ipcRenderer.invoke("package-links"),
  unlinkPackages: (namespace) => ipcRenderer.invoke("unlink-packages", namespace),
  packageFolder: () => ipcRenderer.invoke("package-folder"),
  linkPackages: (namespace, folder, packages) => ipcRenderer.invoke("link-packages", namespace, folder, packages),
  setTrafficLights: (visible) => ipcRenderer.send("traffic-lights", !!visible),
  setTheme: (theme) => ipcRenderer.send("theme", theme),
  reveal: (target) => ipcRenderer.send("reveal", String(target)),
  // Passkeys run in the default browser and come back through a link (macOS only for now).
  ...(process.platform === "darwin" ? { passkey: (mode, name) => ipcRenderer.invoke("passkey", mode, name) } : {}),
  ...(storage ? { storage } : {}),
});
