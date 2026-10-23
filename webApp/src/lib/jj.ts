// The one internal jj repository (mirrors macApp's `SpaceRepository`): every space is a top-level folder of it, so
// its working copy is `spaces/` in origin storage. Paths here are repo-relative (`Thesis/main.typ`). One tab per
// browser runs the repository (a Web Lock); it commits what any tab writes, 5 s after the last change or every 60 s
// while changes keep coming. Edits it hasn't seen yet (made while no tab ran it) wait in localStorage.
import { createEffect, createRoot } from "solid-js";
import { createStore } from "solid-js/store";
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
  mode: null as "jspi" | "asyncify" | null,
});

type Pending = { resolve: (value: any) => void; reject: (err: Error) => void };

let worker: Worker | null = null;
const pending = new Map<number, Pending>();
let nextId = 1;
const commitListeners = new Set<(changed: string[]) => void>();
/** Paths this tab announced after the repository wrote them; their echo isn't an edit. */
const echoes = new Set<string>();

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
      p?.reject(new Error(response.error));
      if (response.fatal) void restart();
    }
  };
  w.onerror = (event) => console.error("jj worker:", event.message);
  worker = w;
  return w;
}

function post(request: DistributiveOmit<Request, "id">): Promise<any> {
  const w = worker ?? startWorker();
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    w.postMessage({ id, ...request });
  });
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
