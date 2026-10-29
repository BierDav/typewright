// Typewright for Windows, Linux and macOS: the web app in its own window, served from the app bundle.
// It runs on Chromium, which the web app's storage (OPFS sync access handles) and sync are built for.
import { app, BrowserWindow, ipcMain, Menu, nativeTheme, net, protocol, screen, shell } from "electron";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const web = path.join(here, "web");
// `scripts/run-desktopApp.sh` points this at vite's dev server.
const devServer = process.env.TYPEWRIGHT_DESKTOP_URL;
// One fixed origin, so spaces stored in the browser storage survive updates.
const ORIGIN = "app://typewright";
const isMac = process.platform === "darwin";
// In the sidebar's top corner, as far from its edges as its rounding (the sidebar starts 8 px in).
const TRAFFIC_LIGHTS = { x: 20, y: 20 };

// Lets tests drive a development build over the DevTools protocol.
if (process.env.TYPEWRIGHT_DEBUG_PORT && !app.isPackaged) app.commandLine.appendSwitch("remote-debugging-port", process.env.TYPEWRIGHT_DEBUG_PORT);

protocol.registerSchemesAsPrivileged([
  { scheme: "app", privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true, codeCache: true } },
]);

/** Files of the web build; other paths (like `/join`) get the app, as GitHub Pages serves `404.html`. */
async function serve(request) {
  const { pathname } = new URL(request.url);
  const file = path.normalize(path.join(web, decodeURIComponent(pathname)));
  const inside = file.startsWith(web + path.sep);
  const exists = inside && fs.statSync(file, { throwIfNoEntry: false })?.isFile();
  const target = exists ? file : path.join(web, pathname === "/" ? "index.html" : "404.html");
  const response = await net.fetch(pathToFileURL(target).toString());
  // Wasm compiles in streaming only with its own type.
  if (target.endsWith(".wasm")) return new Response(response.body, { headers: { "content-type": "application/wasm" } });
  return response;
}

// MARK: - Library

// Spaces live in a real folder, like the Mac app's library, so agents and other programs can work on them by path:
// `<app data>/Typewright Desktop/Spaces` (its own library; the Mac app's is `Typewright/Spaces`). Workers and the
// preload read it from the environment, which renderers inherit.
const LIBRARY = process.env.TYPEWRIGHT_LIBRARY ?? path.join(app.getPath("appData"), "Typewright Desktop");
fs.mkdirSync(path.join(LIBRARY, "Spaces"), { recursive: true });
process.env.TYPEWRIGHT_LIBRARY = LIBRARY;

// MARK: - Passkeys

// Electron can't use passkeys of the web app's domain, so they run in the default browser on its page
// (webApp/src/routes/passkey.tsx), which returns the account through a `typewright-desktop://` link encrypted to a one-time key.
const HANDOFF_SCHEME = "typewright-desktop";
const PASSKEY_PAGE = process.env.TYPEWRIGHT_PASSKEY_PAGE ?? (devServer ? new URL("passkey", devServer).href : "https://bierdav.github.io/typewright/passkey");
const subtle = globalThis.crypto.subtle;
/** The one sign-in waiting for its link; a new one replaces it. */
let pendingPasskey = null;

const base64url = (bytes) => Buffer.from(bytes).toString("base64url");

async function passkey(mode, name) {
  pendingPasskey?.resolve(null);
  const keys = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveKey"]);
  const state = base64url(globalThis.crypto.getRandomValues(new Uint8Array(16)));
  const request = { v: 1, mode, name: String(name ?? "").slice(0, 64), key: base64url(new Uint8Array(await subtle.exportKey("raw", keys.publicKey))), state };
  const result = new Promise((resolve) => {
    // Gives up after a while, so a sign-in abandoned in the browser doesn't keep the button busy.
    const timer = setTimeout(() => finish(null), 10 * 60 * 1000);
    const finish = (value) => {
      clearTimeout(timer);
      if (pendingPasskey?.state === state) pendingPasskey = null;
      resolve(value);
    };
    pendingPasskey = { state, privateKey: keys.privateKey, resolve: finish };
  });
  await shell.openExternal(`${PASSKEY_PAGE}#${base64url(Buffer.from(JSON.stringify(request)))}`);
  return result;
}

async function receivePasskey(url) {
  const pending = pendingPasskey;
  if (!pending) return;
  try {
    const reply = JSON.parse(Buffer.from(new URL(url).hash.slice(1), "base64url").toString());
    if (reply.state !== pending.state) return;
    const browser = await subtle.importKey("raw", Buffer.from(reply.key, "base64url"), { name: "ECDH", namedCurve: "P-256" }, false, []);
    const key = await subtle.deriveKey({ name: "ECDH", public: browser }, pending.privateKey, { name: "AES-GCM", length: 256 }, false, ["decrypt"]);
    const plain = await subtle.decrypt({ name: "AES-GCM", iv: Buffer.from(reply.iv, "base64url"), additionalData: Buffer.from(pending.state) }, key, Buffer.from(reply.data, "base64url"));
    const { secret, name } = JSON.parse(Buffer.from(plain).toString());
    if (!/^[0-9a-f]{64}$/.test(secret)) return;
    pending.resolve({ secret, name: String(name ?? "") });
    const [window] = windows;
    if (window) {
      if (window.isMinimized()) window.restore();
      window.focus();
    }
    app.focus({ steal: true });
  } catch (err) {
    console.error("Passkey link", err);
  }
}

// MARK: - Window bounds

const stateFile = () => path.join(app.getPath("userData"), "window.json");

function savedBounds() {
  try {
    const bounds = JSON.parse(fs.readFileSync(stateFile(), "utf8"));
    // Only on a display that's still attached.
    const visible = screen.getAllDisplays().some(({ workArea: a }) => bounds.x < a.x + a.width && bounds.x + bounds.width > a.x && bounds.y < a.y + a.height && bounds.y + bounds.height > a.y);
    return visible ? bounds : null;
  } catch {
    return null;
  }
}

function remember(window) {
  let timer;
  const save = () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (window.isDestroyed()) return;
      fs.writeFileSync(stateFile(), JSON.stringify({ ...window.getNormalBounds(), maximized: window.isMaximized() }));
    }, 400);
  };
  for (const event of ["resize", "move", "maximize", "unmaximize"]) window.on(event, save);
}

// MARK: - Windows

const windows = new Set();

function createWindow() {
  const saved = savedBounds();
  const window = new BrowserWindow({
    width: saved?.width ?? 1280,
    height: saved?.height ?? 820,
    x: saved?.x,
    y: saved?.y,
    minWidth: 720,
    minHeight: 480,
    title: "Typewright",
    show: false,
    autoHideMenuBar: true,
    // Before the page paints, in the window's appearance.
    backgroundColor: nativeTheme.shouldUseDarkColors ? "#1e1e1e" : "#ececec",
    // On macOS the content reaches the top, and the window buttons sit inside the sidebar's corner.
    ...(isMac ? { titleBarStyle: "hidden", trafficLightPosition: TRAFFIC_LIGHTS } : {}),
    // Packaged builds take theirs from the bundle; Windows and Linux development runs need it here.
    ...(!isMac && !app.isPackaged ? { icon: path.join(here, "build/icons/512x512.png") } : {}),
    // Unsandboxed, so the preload and workers reach the library folder through Node (`webApp/src/lib/disk.ts`);
    // the page itself still has no Node, and only this app's own pages load here.
    webPreferences: { contextIsolation: true, sandbox: false, nodeIntegrationInWorker: true, spellcheck: true, preload: path.join(here, "preload.cjs") },
  });
  if (saved?.maximized) window.maximize();
  remember(window);
  windows.add(window);
  window.on("closed", () => windows.delete(window));
  // Appears once painted, without a white flash.
  window.once("ready-to-show", () => window.show());

  const own = (url) => url.startsWith(`${ORIGIN}/`) || (devServer && url.startsWith(devServer)) || url.startsWith("blob:");
  // Links leave for the default browser; the app's own pages (a PDF opened in a new tab) get a window.
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (own(url)) return { action: "allow", overrideBrowserWindowOptions: { autoHideMenuBar: true, titleBarStyle: "default" } };
    if (/^(https?|mailto):/.test(url)) void shell.openExternal(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event, url) => {
    if (own(url)) return;
    event.preventDefault();
    if (/^(https?|mailto):/.test(url)) void shell.openExternal(url);
  });
  void window.loadURL(devServer ?? `${ORIGIN}/`);
  return window;
}

function menu() {
  const template = [
    ...(isMac ? [{ role: "appMenu" }] : []),
    { label: "File", submenu: [{ label: "New Window", accelerator: "CmdOrCtrl+Shift+N", click: () => createWindow() }, { type: "separator" }, isMac ? { role: "close" } : { role: "quit" }] },
    { role: "editMenu" },
    {
      label: "View",
      submenu: [
        { role: "resetZoom" },
        { role: "zoomIn" },
        { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" },
        ...(app.isPackaged ? [] : [{ type: "separator" }, { role: "reload" }, { role: "toggleDevTools" }]),
      ],
    },
    { role: "windowMenu" },
    { role: "help", submenu: [{ label: "Typewright on GitHub", click: () => void shell.openExternal("https://github.com/BierDav/typewright") }] },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

// One running copy: a second launch brings the open window forward.
if (!app.requestSingleInstanceLock()) app.quit();

app.on("second-instance", () => {
  const [window] = windows;
  if (!window) return createWindow();
  if (window.isMinimized()) window.restore();
  window.focus();
});

ipcMain.on("traffic-lights", (event, visible) => {
  if (isMac) BrowserWindow.fromWebContents(event.sender)?.setWindowButtonVisibility(visible);
});

ipcMain.handle("passkey", (_event, mode, name) => (isMac && (mode === "create" || mode === "get") ? passkey(mode, name) : null));

// macOS delivers the browser's link here, also when it launched the app.
app.on("open-url", (event, url) => {
  if (!url.startsWith(`${HANDOFF_SCHEME}://`)) return;
  event.preventDefault();
  void receivePasskey(url);
});

// Only inside the library, so a page can't open arbitrary places.
ipcMain.on("reveal", (_event, target) => {
  const resolved = path.resolve(target);
  if (resolved === LIBRARY || resolved.startsWith(LIBRARY + path.sep)) shell.showItemInFolder(resolved);
});

ipcMain.on("theme", (_event, theme) => {
  if (["system", "light", "dark"].includes(theme)) nativeTheme.themeSource = theme;
});

// Packaged builds declare the scheme in Info.plist; a development run registers Electron itself.
if (isMac && !app.isPackaged) app.setAsDefaultProtocolClient(HANDOFF_SCHEME, process.execPath, [path.resolve(here)]);

app.whenReady().then(() => {
  // A development run is Electron's own bundle, which would show Electron's icon.
  if (!app.isPackaged && isMac) app.dock?.setIcon(path.join(here, "build/icons/1024x1024.png"));
  protocol.handle("app", serve);
  menu();
  createWindow();
  app.on("activate", () => windows.size === 0 && createWindow());
});

app.on("window-all-closed", () => !isMac && app.quit());
