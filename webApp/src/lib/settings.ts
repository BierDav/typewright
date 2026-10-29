import { createEffect, createRoot } from "solid-js";
import { createStore } from "solid-js/store";
import { desktop } from "./desktop";

export type RenderMode = "pdf" | "html" | "svg";

/** How many old versions to keep, like a backup prune (`twj_squash` in jjBridge); negative means all. */
export type RetentionPolicy = { last: number; hourly: number; daily: number; weekly: number; monthly: number; yearly: number };

export const DEFAULT_RETENTION: RetentionPolicy = { last: 100, hourly: 48, daily: 14, weekly: 8, monthly: 12, yearly: -1 };
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
  /** Whether old versions are thinned out by `historyRetention`. */
  historyThinOut: boolean;
  historyRetention: RetentionPolicy;
  /** Labels this device's cursor on other devices. */
  deviceName: string;
  /** Pinned beside the content; when false it hides and floats in from the left edge. */
  sidebarVisible: boolean;
  sidebarWidth: number;
  /** Shows the document's pages dark, colours inverted, for reading at night. */
  previewDark: boolean;
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
  historyThinOut: true,
  historyRetention: DEFAULT_RETENTION,
  deviceName: defaultDeviceName(),
  sidebarVisible: true,
  sidebarWidth: 264,
  split: 0.5,
  previewDark: false,
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
    const stored = JSON.parse(localStorage.getItem(KEY) ?? "{}");
    // The old "squash after N days" setting gives way to the retention defaults, like on the Mac.
    delete stored.historySquashDays;
    return { ...defaults, ...stored, historyRetention: { ...DEFAULT_RETENTION, ...stored.historyRetention } };
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
    desktop?.setTheme(theme);
  });
});

/** Whether the page shows dark, following the system unless a theme is picked. */
export function isDark(): boolean {
  if (settings.theme !== "system") return settings.theme === "dark";
  return matchMedia("(prefers-color-scheme: dark)").matches;
}
