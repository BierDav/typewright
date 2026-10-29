// The one internal jj repository (mirrors macApp's `SpaceRepository`): every space is a top-level folder of it, so
// its working copy is `spaces/` in origin storage. Paths here are repo-relative (`Thesis/main.typ`). One tab per
// browser runs the repository (a Web Lock); it commits what any tab writes, 5 s after the last change or every 60 s
// while changes keep coming. Edits it hasn't seen yet (made while no tab ran it) wait in localStorage.
import { createEffect, createRoot } from "solid-js";
import { createStore } from "solid-js/store";
import { nativeConfig, invokeNative } from "./native";
import JJWorker from "~/workers/jj.worker.ts?worker";
import type { Arg, Request, Response } from "~/workers/jj.worker";
import { type RetentionPolicy, settings } from "./settings";
import { SPACES } from "./spaces";
import * as fs from "./storage";

export type FileVersion = {
  commit: string;
  /** Milliseconds since the epoch. */
  time: number;
  description: string;
  kind: "added" | "modified" | "deleted" | "renamed";
  /** The path before a rename. */
  from?: string;
  added: number;
  removed: number;
};

/** A deleted file or folder the history (or the stash of untracked LFS files) still has. */
export type DeletedItem = {
  path: string;
  kind: "file" | "folder";
  files: number;
  /** The deleting commit and its parent, which still has the item; absent for stashed LFS files only. */
  commit?: string | null;
  lastCommit?: string | null;
  stash?: string | null;
  /** Milliseconds since the epoch. */
  time: number;
  description: string;
};

export type FileContent = { text: string } | { data: Uint8Array } | { missing: true };

export type ConflictHunk = { text: string } | { conflict: { base: string; sides: string[] } };
export type FileConflict = { path: string; binary: boolean; sides: string[]; hunks: ConflictHunk[] };

const IDLE_MS = 5_000;
const MAX_MS = 60_000;
const HOUR_MS = 3_600_000;
const LAST_SQUASH = "typewright.jj.lastSquash";

export const [repository, setRepository] = createStore({
  /** "elsewhere": another tab runs the repository, so history and conflicts show there. */
  status: "idle" as "idle" | "starting" | "open" | "elsewhere" | "failed",
  error: null as string | null,
  /** Conflicted files, repo-relative. */
  conflicted: [] as string[],
  /** "asyncify" where the browser lacks JSPI: a larger, slower build of the module. */
  mode: null as "jspi" | "asyncify" | "native" | null,
});

type Pending = { resolve: (value: any) => void; reject: (err: Error) => void };

let worker: Worker | null = null;
const pending = new Map<number, Pending>();
let nextId = 1;
const commitListeners = new Set<(changed: string[]) => void>();
/** Paths this tab announced after the repository wrote them; their echo isn't an edit. */
const echoes = new Set<string>();

const moveListeners = new Set<(from: string, to: string) => void>();
const deleteListeners = new Set<(paths: string[]) => void>();
const restoreListeners = new Set<(from: string, to: string) => void>();

/** Calls `listener` when a file or folder was renamed or moved in the app (repo-relative paths). */
export function onMove(listener: (from: string, to: string) => void): () => void {
  moveListeners.add(listener);
  return () => moveListeners.delete(listener);
}

/** Calls `listener` with the paths deleted in the app. */
export function onDelete(listener: (paths: string[]) => void): () => void {
  deleteListeners.add(listener);
  return () => deleteListeners.delete(listener);
}

/** Calls `listener` when a deleted item came back (`from` its old path, `to` where it is now). */
export function onRestore(listener: (from: string, to: string) => void): () => void {
  restoreListeners.add(listener);
  return () => restoreListeners.delete(listener);
}

/** Tells listeners (sync, so shares follow) that the app moved `from` to `to`. */
export function noteMoved(from: string, to: string) {
  if (from !== to) moveListeners.forEach((l) => l(from, to));
}

/** Calls `listener` with the repo-relative paths of every commit, restore and resolve. */
export function onCommit(listener: (changed: string[]) => void): () => void {
  commitListeners.add(listener);
  return () => commitListeners.delete(listener);
}

export function relativePath(storagePath: string): string | null {
  const parts = fs.split(storagePath);
  return parts[0] === SPACES && parts.length > 1 ? parts.slice(1).join("/") : null;
}

export function storagePath(relative: string): string {
  return fs.join(SPACES, relative);
}

function startWorker(): Worker {
  const w = new JJWorker();
  w.onmessage = (event: MessageEvent<Response>) => {
    const response = event.data;
    const p = pending.get(response.id);
    pending.delete(response.id);
    if (response.ok) {
      announce(response.written);
      p?.resolve(response.mode ? { mode: response.mode } : response.value);
    } else {
      p?.reject(Object.assign(new Error(response.error), { busy: response.busy === true }));
      if (response.fatal) void restart();
    }
  };
  w.onerror = (event) => {
    const error = new Error(event.message || "Couldn't load the repository worker");
    for (const p of pending.values()) p.reject(error);
    pending.clear();
    console.error("jj worker:", error.message);
  };
  worker = w;
  return w;
}

function post(request: DistributiveOmit<Request, "id">): Promise<any> {
  if (nativeConfig) return postNative(request);
  const w = worker ?? startWorker();
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    w.postMessage({ id, ...request });
  });
}

async function postNative(request: DistributiveOmit<Request, "id">): Promise<any> {
  const wire = request.op === "mergeNode" ? { ...request,
    objects: request.objects.map(([name, data]) => [name, Array.from(data)]),
    lfs: request.lfs.map(([name, data]) => [name, Array.from(data)]),
  } : request;
  const response = await invokeNative<{ ok: boolean; value?: any; error?: string; busy?: boolean }>("repository", {
    request: { ...wire, utcOffset: -new Date().getTimezoneOffset() },
  });
  if (!response.ok) throw Object.assign(new Error(response.error), { busy: response.busy });
  if (request.op === "nodeObjects") return response.value.map(([name, data]: [string, number[]]) => [name, new Uint8Array(data)]);
  return response.value;
}

type DistributiveOmit<T, K extends keyof any> = T extends unknown ? Omit<T, K> : never;

/** Tells the app about working-copy files the repository wrote, so editors reload them. */
function announce(written: string[]) {
  if (!written.length) return;
  const paths = written.map(storagePath);
  paths.forEach((p) => echoes.add(p));
  fs.notify(paths);
}

async function restart() {
  worker?.terminate();
  worker = null;
  for (const [id, p] of pending) {
    p.reject(new Error("jj crashed"));
    pending.delete(id);
  }
  await open();
}

const UNSEEN = "typewright.jj.unseen";
const MAX_UNSEEN = 2000;

function unseen(): string[] {
  try {
    return JSON.parse(localStorage.getItem(UNSEEN) ?? "[]");
  } catch {
    return [""];
  }
}

/** Remembers edited paths until the repository has seen them; past the cap, everything counts as edited. */
function addUnseen(paths: string[]) {
  const all = new Set([...unseen(), ...paths]);
  localStorage.setItem(UNSEEN, JSON.stringify(all.size > MAX_UNSEEN || all.has("") ? [""] : [...all]));
}

function removeUnseen(paths: string[]) {
  const done = new Set(paths);
  localStorage.setItem(UNSEEN, JSON.stringify(unseen().filter((p) => !done.has(p))));
}

async function open() {
  setRepository({ status: "starting", error: null });
  try {
    const stale = unseen();
    const value = await post({ op: "open", lfsLimit: lfsLimit(), stale });
    removeUnseen(stale);
    setRepository({ status: "open", mode: value?.mode ?? null });
    await refreshConflicts();
  } catch (err) {
    setRepository({ status: "failed", error: (err as Error).message });
  }
}

let started = false;
/** Waits for this tab's repository, reporting startup failures to sync as well. */
export function whenOpen(): Promise<void> {
  return new Promise((resolve, reject) => {
    createRoot((dispose) => {
      createEffect(() => {
        if (repository.status === "open") {
          dispose();
          resolve();
        } else if (repository.status === "failed") {
          dispose();
          reject(new Error(repository.error ?? "Couldn't open the repository"));
        }
      });
    });
  });
}

/** Opens the repository in this tab once it holds the lock; until then status is "elsewhere". */
export function start() {
  if (started || typeof Worker === "undefined") return;
  started = true;
  const run = () => new Promise<void>(() => void open().then(scheduleSquash));
  if (!navigator.locks) return void run();
  void navigator.locks.request("typewright-jj", { ifAvailable: true }, (lock) => {
    if (lock) return run();
    setRepository("status", "elsewhere");
    return navigator.locks.request("typewright-jj", run);
  });
}

async function call<T>(fn: string, ...args: Arg[]): Promise<T | null> {
  if (repository.status !== "open") return null;
  try {
    return (await post({ op: "call", fn, args })) as T;
  } catch (err) {
    console.error(`jj: ${fn}:`, (err as Error).message);
    return null;
  }
}

/** Raw JSON call, for the sync engine. */
export function json<T = unknown>(fn: string, ...args: Arg[]): Promise<T | null> {
  return call<T>(fn, ...args);
}

/** An error the repository reported; `busy` while the jj CLI or another process holds it. */
export type RepositoryError = Error & { busy?: boolean };

/** Like `json`, but failures throw (a `RepositoryError`), as the sync engine tells them apart. */
export function request<T = unknown>(fn: string, ...args: Arg[]): Promise<T> {
  if (repository.status !== "open") return Promise.reject(new Error("The repository isn't open in this tab"));
  return post({ op: "call", fn, args });
}

/** The git objects of a node (its commit and whole tree), as `[oid, bytes]` pairs for its bundle. */
export function nodeObjects(node: string): Promise<[string, Uint8Array][]> {
  return post({ op: "nodeObjects", node });
}

export type MergeResult = { node: string | null; changed?: string[]; conflicts?: string[] };

/** Imports another device's node and merges it into the share at `path`, leaving the `keep` paths as they are. */
export async function mergeNode(args: {
  share: string;
  path: string;
  manifest: string;
  objects: [string, Uint8Array][];
  lfs: [string, Uint8Array][];
  label: string;
  keep: string[];
}): Promise<MergeResult> {
  const result = (await post({ op: "mergeNode", ...args })) as MergeResult;
  if (result.changed?.length) commitListeners.forEach((l) => l(result.changed!));
  await refreshConflicts();
  return result;
}

function lfsLimit(): number {
  return Math.round(settings.lfsThresholdMB * 1_048_576);
}

export function setLFSLimit(bytes: number) {
  void call("twj_set_lfs_limit", bytes);
}

// MARK: History

/** Commits whatever changed; returns the changed paths. */
export async function commit(message = "Edit"): Promise<string[]> {
  clearTimers();
  const result = await call<{ commit: string | null; changed: string[] }>("twj_commit", message);
  if (!result?.changed.length) return [];
  commitListeners.forEach((l) => l(result.changed));
  await refreshConflicts();
  return result.changed;
}

/** Thins out old autosaves by `policy`; null when it failed. */
export async function squash(policy: RetentionPolicy): Promise<{ squashed: number; kept: number } | null> {
  const clean = Object.fromEntries(Object.entries(policy).map(([k, v]) => [k, k === "yearly" ? Math.trunc(v) : Math.max(0, Math.trunc(v))]));
  return call<{ squashed: number; kept: number }>("twj_squash", JSON.stringify(clean));
}

/** At most hourly (or after the clock went back), and only while no commit is pending. */
export function squashIsDue(last: number | null, now: number): boolean {
  return last === null || now - last >= HOUR_MS || now < last;
}

export async function history(path: string, limit = 500): Promise<FileVersion[]> {
  const versions = await call<(Omit<FileVersion, "time"> & { time: number })[]>("twj_file_history", path, limit);
  return (versions ?? []).map((v) => ({ ...v, description: v.description ?? "", time: v.time * 1000 }));
}

export async function contentAt(path: string, commitId: string): Promise<FileContent> {
  const result = await call<{ text?: string; data?: string; missing?: boolean }>("twj_file_at", commitId, path);
  if (typeof result?.text === "string") return { text: result.text };
  if (typeof result?.data === "string") return { data: Uint8Array.from(atob(result.data), (c) => c.charCodeAt(0)) };
  return { missing: true };
}

/** Puts the file back as it was in `commit`; editors reload through the storage change it announces. */
export async function restore(path: string, commitId: string): Promise<boolean> {
  if (!(await call<{ commit: string | null }>("twj_restore_file", commitId, path))) return false;
  commitListeners.forEach((l) => l([path]));
  return true;
}

// MARK: Deleting

/** Deletes and commits `message` at once; there's no trash. Null when this tab doesn't run the repository. */
export async function deleteItems(paths: string[], message: string): Promise<DeletedItem[] | null> {
  clearTimers();
  const result = await call<{ deleted: (DeletedItem & { time: number })[] }>("twj_delete", JSON.stringify(paths), message);
  if (!result) return null;
  deleteListeners.forEach((l) => l(paths));
  commitListeners.forEach((l) => l(paths));
  return result.deleted.map(fromWire);
}

function fromWire(item: DeletedItem): DeletedItem {
  return { ...item, description: item.description ?? "", time: item.time * 1000 };
}

/** Deleted items under `prefix` ("" for all), newest first. */
export async function deleted(prefix = "", limit = 500): Promise<DeletedItem[]> {
  return ((await call<DeletedItem[]>("twj_deleted", prefix, limit)) ?? []).map(fromWire);
}

/** Puts a deleted item back at `dest` (repo-relative; its own path or a free name). */
export async function restoreDeleted(item: DeletedItem, dest: string): Promise<"restored" | "exists" | "failed"> {
  const entry = JSON.stringify({ ...item, time: item.time / 1000 });
  const result = await call<{ commit?: string | null; exists?: boolean }>("twj_restore_deleted", entry, dest);
  if (!result) return "failed";
  if (result.exists) return "exists";
  restoreListeners.forEach((l) => l(item.path, dest));
  commitListeners.forEach((l) => l([dest]));
  return "restored";
}

/** Whether this tab runs the repository, so history calls work here. */
export function isOpen(): boolean {
  return repository.status === "open";
}

// MARK: Conflicts

export async function refreshConflicts() {
  const paths = await call<string[]>("twj_conflicts", "");
  if (!paths) return;
  const sorted = [...paths].sort();
  if (sorted.join("\n") !== repository.conflicted.join("\n")) setRepository("conflicted", sorted);
}

export function isConflicted(path: string): boolean {
  return repository.conflicted.includes(path);
}

export function conflict(path: string): Promise<FileConflict | null> {
  return call<FileConflict>("twj_conflict", path);
}

/** Resolves with `text`, or for binary files by keeping side `side`. */
export async function resolve(path: string, text: string | null, side = 0): Promise<boolean> {
  if (!(await call<{ commit: string | null }>("twj_resolve", path, text, side))) return false;
  commitListeners.forEach((l) => l([path]));
  await refreshConflicts();
  return true;
}

// MARK: Scheduling

let idleTimer: ReturnType<typeof setTimeout> | undefined;
let maxTimer: ReturnType<typeof setTimeout> | undefined;

function clearTimers() {
  clearTimeout(idleTimer);
  clearTimeout(maxTimer);
  idleTimer = maxTimer = undefined;
}

function scheduleCommit() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => void commit(), IDLE_MS);
  maxTimer ??= setTimeout(() => void commit(), MAX_MS);
}

function scheduleSquash() {
  const run = async () => {
    if (!settings.historyThinOut || idleTimer || repository.status !== "open") return;
    const last = Number(localStorage.getItem(LAST_SQUASH)) || null;
    if (!squashIsDue(last, Date.now())) return;
    // Marked done only once it ran, so a failure gets the next check.
    if (await squash({ ...settings.historyRetention })) localStorage.setItem(LAST_SQUASH, String(Date.now()));
  };
  void run();
  setInterval(() => void run(), 5 * 60_000);
}

createRoot(() => {
  if (typeof window === "undefined") return;
  // Edits from any tab (other tabs announce theirs over a BroadcastChannel).
  fs.onChange(({ paths }) => {
    const relative: string[] = [];
    for (const path of paths) {
      if (echoes.delete(path)) continue;
      const rel = relativePath(path);
      if (rel && fs.split(rel)[0] !== ".jj") relative.push(rel);
    }
    if (!relative.length) return;
    addUnseen(relative);
    if (repository.status !== "open") return;
    void post({ op: "invalidate", paths: relative }).then(() => {
      removeUnseen(relative);
      scheduleCommit();
    }, () => {});
  });
  addEventListener("pagehide", () => {
    if (idleTimer) void commit();
  });
  createEffect(() => {
    const bytes = lfsLimit();
    if (repository.status === "open") setLFSLimit(bytes);
  });
});
