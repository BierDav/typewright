// Window-wide state: the open space, overlays and dialogs.
import type { EditorView } from "@codemirror/view";
import { createSignal } from "solid-js";
import { createStore } from "solid-js/store";
import { Workspace } from "./workspace";

const LAST_SPACE = "typewright.lastSpace";
/** An invite link the `/join` route hands to the main page. */
export const PENDING_JOIN = "typewright.pendingJoin";

const [workspace, setWorkspaceSignal] = createSignal<Workspace | null>(null);
export { workspace };

export function openSpace(folder: string | null) {
  const current = workspace();
  if (current?.folder === folder) return;
  current?.dispose();
  setWorkspaceSignal(folder ? new Workspace(folder) : null);
  if (folder) localStorage.setItem(LAST_SPACE, folder);
  else localStorage.removeItem(LAST_SPACE);
}

export function lastSpace(): string | null {
  return localStorage.getItem(LAST_SPACE);
}

export type Overlay =
  | { type: "palette"; page?: string }
  | { type: "search"; allSpaces: boolean }
  | { type: "settings"; tab?: SettingsTab }
  /** `scope` is a repo-relative folder (a space or one inside it); null lists every space. */
  | { type: "deleted"; scope: string | null }
  | null;

export type SettingsTab = "general" | "editor" | "fonts" | "packages" | "devices";

const [overlay, setOverlay] = createSignal<Overlay>(null);
export { overlay, setOverlay };

export function showRecentlyDeleted(scope: string | null = workspace()?.folder ?? null) {
  setOverlay({ type: "deleted", scope });
}

/** The editor view of the shown file, for commands run from outside it. */
const [editorView, setEditorView] = createSignal<EditorView | null>(null);
export { editorView, setEditorView };

// MARK: - Dialogs

type Button = { label: string; value: string; role?: "cancel" | "destructive" | "default" };

export type Dialog = {
  id: number;
  title: string;
  message?: string;
  /** Shows a text field starting with this value. */
  input?: string;
  placeholder?: string;
  /** Read-only text to copy, like an invite link. */
  copy?: string[];
  buttons: Button[];
  resolve: (result: { button: string; input: string } | null) => void;
};

const [dialogs, setDialogs] = createStore<Dialog[]>([]);
export { dialogs };
let dialogId = 0;

function present(dialog: Omit<Dialog, "id" | "resolve">): Promise<{ button: string; input: string } | null> {
  return new Promise((resolve) => {
    const id = ++dialogId;
    setDialogs((all) => [
      ...all,
      {
        ...dialog,
        id,
        resolve: (result) => {
          setDialogs((rest) => rest.filter((d) => d.id !== id));
          resolve(result);
        },
      },
    ]);
  });
}

export async function confirm(title: string, message: string, action = "OK", destructive = false): Promise<boolean> {
  const result = await present({
    title,
    message,
    buttons: [
      { label: "Cancel", value: "cancel", role: "cancel" },
      { label: action, value: "ok", role: destructive ? "destructive" : "default" },
    ],
  });
  return result?.button === "ok";
}

export async function prompt(title: string, initial = "", action = "OK", message?: string, placeholder?: string): Promise<string | null> {
  const result = await present({
    title,
    message,
    input: initial,
    placeholder,
    buttons: [
      { label: "Cancel", value: "cancel", role: "cancel" },
      { label: action, value: "ok", role: "default" },
    ],
  });
  return result?.button === "ok" ? result.input : null;
}

export async function alert(title: string, message?: string, copy?: string[]) {
  await present({ title, message, copy, buttons: [{ label: "OK", value: "ok", role: "default" }] });
}

export async function choose(title: string, message: string, options: { label: string; value: string; role?: Button["role"] }[]): Promise<string | null> {
  const result = await present({ title, message, buttons: options });
  return result?.button ?? null;
}

// MARK: - Toasts

export type ToastAction = { label: string; run: () => void };
const [toasts, setToasts] = createStore<{ id: number; text: string; actions: ToastAction[] }[]>([]);
export { toasts };

export function dismissToast(id: number) {
  setToasts((all) => all.filter((t) => t.id !== id));
}

/** A short note; with actions (like Undo) it stays a little longer. */
export function toast(text: string, actions: ToastAction[] = []) {
  const id = ++dialogId;
  setToasts((all) => [...all, { id, text, actions }]);
  setTimeout(() => dismissToast(id), actions.length ? 8000 : 3500);
}

export async function copyText(text: string, what = "Copied") {
  try {
    await navigator.clipboard.writeText(text);
    toast(what);
  } catch {
    await alert("Copy this", undefined, [text]);
  }
}

export const isMac = typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
/** Shortcut labels the way the platform writes them. */
export function shortcut(mac: string): string {
  if (isMac) return mac;
  return mac.replace(/⌘/g, "Ctrl+").replace(/⌥/g, "Alt+").replace(/⇧/g, "Shift+").replace(/⌃/g, "Ctrl+");
}
