// The few things the web app asks of the desktop window; sandboxed preloads are CommonJS.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("typewrightDesktop", {
  platform: process.platform,
  setTrafficLights: (visible) => ipcRenderer.send("traffic-lights", !!visible),
  setTheme: (theme) => ipcRenderer.send("theme", theme),
  // Passkeys run in the default browser and come back through a link (macOS only for now).
  ...(process.platform === "darwin" ? { passkey: (mode, name) => ipcRenderer.invoke("passkey", mode, name) } : {}),
});
