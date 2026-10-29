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
// Centred in the sidebar's 44 px header, which starts 8 px from the window's edge.
const TRAFFIC_LIGHTS = { x: 22, y: 22 };

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
    webPreferences: { contextIsolation: true, sandbox: true, spellcheck: true, preload: path.join(here, "preload.cjs") },
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

ipcMain.on("theme", (_event, theme) => {
  if (["system", "light", "dark"].includes(theme)) nativeTheme.themeSource = theme;
});

app.whenReady().then(() => {
  protocol.handle("app", serve);
  menu();
  createWindow();
  app.on("activate", () => windows.size === 0 && createWindow());
});

app.on("window-all-closed", () => !isMac && app.quit());
