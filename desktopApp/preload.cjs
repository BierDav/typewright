// The few things the web app asks of the desktop window; sandboxed preloads are CommonJS.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("typewrightDesktop", {
  platform: process.platform,
  setTrafficLights: (visible) => ipcRenderer.send("traffic-lights", !!visible),
  setTheme: (theme) => ipcRenderer.send("theme", theme),
});
