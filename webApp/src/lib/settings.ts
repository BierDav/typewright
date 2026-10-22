import { createEffect, createRoot } from "solid-js";
import { createStore } from "solid-js/store";

export type RenderMode = "pdf" | "html" | "svg";
export type Theme = "system" | "light" | "dark";

export type Settings = {
  theme: Theme;
  /** Editor font size in px. */
  fontSize: number;
  vim: boolean;
  wrapGuide: boolean;
  wrapColumn: number;
  /** Completions, hovers and go to definition. */
  language: boolean;
  renderMode: RenderMode;
  /** For Markdown and for HTML without pages. */
  previewTextSize: number;
  ignoreLibraryWarnings: boolean;
  /** Folders inside each space, relative to its root, searched for fonts. */
  spaceFontPaths: string[];
  /** Files up to this many megabytes get history and merge when synced; larger ones are LFS files, kept whole. */
  lfsThresholdMB: number;
  /** History older than this many days keeps one version per day; 0 keeps every version. */
  historySquashDays: number;
  /** Labels this device's cursor on other devices. */
  deviceName: string;
  sidebarVisible: boolean;
  spacesVisible: boolean;
  /** Width of the preview as a share of the window. */
  split: number;
};

const defaults: Settings = {
  theme: "system",
  fontSize: 14,
  vim: false,
  wrapGuide: false,
  wrapColumn: 100,
  language: true,
  renderMode: "svg",
  previewTextSize: 16,
  ignoreLibraryWarnings: false,
  spaceFontPaths: ["./fonts"],
  lfsThresholdMB: 1,
  historySquashDays: 30,
  deviceName: defaultDeviceName(),
  sidebarVisible: true,
  spacesVisible: true,
  split: 0.5,
};

function defaultDeviceName(): string {
  if (typeof navigator === "undefined") return "Browser";
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? "Edge" : /Firefox\//.test(ua) ? "Firefox" : /Chrome\//.test(ua) ? "Chrome" : /Safari\//.test(ua) ? "Safari" : "Browser";
  const os = /Mac OS X/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows" : /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Linux/.test(ua) ? "Linux" : "";
  return os ? `${browser} on ${os}` : browser;
}

const KEY = "typewright.settings";

function load(): Settings {
  try {
    return { ...defaults, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") };
  } catch {
    return { ...defaults };
  }
}

export const [settings, setSettings] = createStore<Settings>(typeof localStorage === "undefined" ? defaults : load());

createRoot(() => {
  createEffect(() => {
    localStorage.setItem(KEY, JSON.stringify(settings));
  });
  createEffect(() => {
    const theme = settings.theme;
    document.documentElement.dataset.theme = theme;
  });
});

/** Whether the page shows dark, following the system unless a theme is picked. */
export function isDark(): boolean {
  if (settings.theme !== "system") return settings.theme === "dark";
  return matchMedia("(prefers-color-scheme: dark)").matches;
}
