// Syncs shares (spaces, or any folder or file in one) across the user's devices and with the people they invited,
// like the Mac app's `SyncService`. Each state of a share travels as a jj node: a commit is exported by the jj worker
// (`lib/jj.ts`) and published as this device's head through `irohBridge` (built for wasm); other devices' heads are
// fetched and merged 3-way by jj, and a clean merge is published again, until every device holds the same node.
// Files open on two connected devices sync live through the CRDT instead, so merges leave them alone.
//
// Paths are repository paths (`Thesis/main.typ`): a space is a top-level folder of the repository.
// The tab running the repository runs the node too (Web Locks decide); other tabs say "Syncing in another tab".
import { batch, createEffect, createRoot } from "solid-js";
import { createStore } from "solid-js/store";
import init, { generateDeviceKey, SyncNode } from "~/wasm/sync/sync.js";
import syncWasm from "~/wasm/sync/sync_bg.wasm?url";
import * as core from "./core";
import type { PeerHead, SharePath, SpaceInvite } from "./core";
import { identity } from "./identity";
import * as jj from "./jj";
import { settings } from "./settings";
import { refreshSpaces, SPACES, uniqueName } from "./spaces";
import * as fs from "./storage";

export type ShareKind = "space" | "folder" | "file";
export type ShareStatus = "Synced" | "Syncing" | "Conflicts" | "Offline";

/** A share listed by the account, possibly not on this device yet. */
export type AccountShare = { id: string; name: string; kind: ShareKind; members: string[]; shared: boolean; joined?: boolean; devices?: boolean; host?: string };

/** Where a share lives on this device: its repository path. */
export type LocalShare = { path: string; kind: ShareKind };

/** A share stopped because its folder or file was deleted; restoring it syncs it again. */
export type ParkedShare = { share: LocalShare; name: string; shared: boolean; secret?: string; left: boolean };

export type LiveResult = {
  edits: { location: number; length: number; text: string }[];
  adopted: { base: string; theirs: string } | null;
  cursors: { device: string; name: string; location: number; length: number }[];
  peers: number;
  undone: boolean;
};

/** Live files above this size sync on save only. */
export const LIVE_LIMIT = 512 * 1024;
const SHARES_KEY = "typewright.syncedShares";
const PARKED_KEY = "typewright.syncParkedShares";
const REJOINING_KEY = "typewright.syncRejoiningShares";
/** Spaces synced path by path before shares: id → folder. */
const OLD_SPACES_KEY = "typewright.syncedSpaces";

export const [sync, setSync] = createStore({
  status: "off" as "off" | "starting" | "running" | "elsewhere" | "error",
  deviceId: null as string | null,
  /** Devices this one is connected to right now. */
  connected: [] as string[],
  /** Every device listed for the account, this one included. */
  devices: [] as string[],
  accountShares: [] as AccountShare[],
  /** Shares synced on this device by id. */
  shares: load<Record<string, LocalShare>>(SHARES_KEY, {}),
  statuses: {} as Record<string, ShareStatus>,
  /** Why a share isn't syncing, like its folder having moved away. */
  problems: {} as Record<string, string>,
  /** Shares whose root was deleted here, by id. */
  parked: load<Record<string, ParkedShare>>(PARKED_KEY, {}),
  /** Devices of any account listed for each shared share. */
  shared: {} as Record<string, string[]>,
  lastError: null as string | null,
});

function load<T>(key: string, fallback: T): T {
  if (typeof localStorage === "undefined") return fallback;
  try {
    return JSON.parse(localStorage.getItem(key) ?? "null") ?? fallback;
  } catch {
    return fallback;
  }
}

/** What this device knows about a share's nodes. */
type Runtime = {
  /** This device's current node, its ancestors and the LFS files it holds. */
  head: string | null;
  ancestry: string[];
  lfs: Set<string>;
  /** The node last published as this device's head, and the LFS files seeded since the page loaded. */
  published: string | null;
  seeded: Set<string>;
  /** The other devices' heads. */
  heads: Map<string, { node: string; name: string | null }>;
  working: number;
};

type Manifest = {
  node?: string;
  ancestry?: string[];
  files?: Record<string, { lfs?: boolean; blake3?: string }>;
};

let node: SyncNode | null = null;
let wasmReady: Promise<unknown> | null = null;
let dataDir = "";
let releaseLock: (() => void) | null = null;
let generation = 0;
let rejoining = load<Record<string, ParkedShare>>(REJOINING_KEY, {});
const runtimes = new Map<string, Runtime>();
const queues = new Map<string, Promise<void>>();
const publishTimers = new Map<string, ReturnType<typeof setTimeout>>();
/** `share/inside` of files open here and on another device; merges leave them to the live session. */
const livePaths = new Set<string>();
const willChange = new Set<(folder: string) => Promise<void> | void>();
const liveListeners = new Set<(folder: string, path: string) => void>();
let snapshotTimer: ReturnType<typeof setTimeout> | undefined;

migrateSpaces();

/** Spaces synced before shares keep their ids and sync as space shares. */
function migrateSpaces() {
  if (typeof localStorage === "undefined") return;
  const old = load<Record<string, string>>(OLD_SPACES_KEY, {});
  if (!Object.keys(old).length) return;
  for (const [id, folder] of Object.entries(old)) {
    if (folder && !sync.shares[id]) setSync("shares", id, { path: folder, kind: "space" });
  }
  localStorage.removeItem(OLD_SPACES_KEY);
  persist();
}

function persist() {
  localStorage.setItem(SHARES_KEY, JSON.stringify(sync.shares));
  localStorage.setItem(PARKED_KEY, JSON.stringify(sync.parked));
  localStorage.setItem(REJOINING_KEY, JSON.stringify(rejoining));
}

function runtime(id: string): Runtime {
  let r = runtimes.get(id);
  if (!r) {
    r = { head: null, ancestry: [], lfs: new Set(), published: null, seeded: new Set(), heads: new Map(), working: 0 };
    runtimes.set(id, r);
  }
  return r;
}

// MARK: - Lookups

function sharePaths(): SharePath[] {
  return Object.entries(sync.shares)
    .filter(([id, s]) => s && isActive(id))
    .map(([id, s]) => ({ id, path: s.path, file: s.kind === "file" }));
}

function sharePath(id: string): SharePath | null {
  const share = sync.shares[id];
  return share ? { id, path: share.path, file: share.kind === "file" } : null;
}

export function isRunning(): boolean {
  return node !== null;
}

/** The share whose root is exactly `path`. */
export function shareId(path: string): string | undefined {
  return Object.entries(sync.shares).find(([, s]) => s?.path === path)?.[0];
}

export function isSynced(path: string): boolean {
  const id = shareId(path);
  return !!id && accountShare(path)?.devices !== false;
}

export function accountShare(path: string): AccountShare | undefined {
  const id = shareId(path);
  return sync.accountShares.find((s) => s.id === id);
}

function isActive(id: string): boolean {
  const share = sync.accountShares.find((s) => s.id === id);
  return !share || share.devices !== false || (share.shared && share.host === sync.deviceId);
}

export async function configure(path: string, devices: boolean, shared: boolean, rotate = false): Promise<boolean> {
  const current = node;
  const id = shareId(path) ?? await share(path);
  if (!current || !id) return false;
  // A new share is listed asynchronously before its settings can be changed.
  for (let i = 0; i < 100 && !sync.accountShares.some((s) => s.id === id); i++) await new Promise((resolve) => setTimeout(resolve, 20));
  try {
    await current.configureShare(id, devices, shared, rotate);
    return true;
  } catch (err) {
    setSync("lastError", (err as Error).message ?? String(err));
    return false;
  }
}

/** Whether anything in or around `folder` syncs, so its edits should reach storage quickly. */
export function syncsAnything(folder: string): boolean {
  return Object.entries(sync.shares).some(([id, s]) => s && isActive(id) && (s.path === folder || s.path.startsWith(`${folder}/`) || folder.startsWith(`${s.path}/`)));
}

/** Whether other accounts sync the share too. */
export function isShared(path: string): boolean {
  const id = shareId(path);
  return !!id && isActive(id) && sync.accountShares.some((s) => s.id === id && s.shared);
}

export function status(path: string): ShareStatus | undefined {
  const id = shareId(path);
  return id ? sync.statuses[id] : undefined;
}

/** Account shares another device syncs and this one doesn't. */
export function elsewhere(): AccountShare[] {
  return sync.accountShares.filter((s) => s.devices !== false && !sync.shares[s.id] && s.members.some((m) => m !== sync.deviceId));
}

/** Runs before sync replaces files of a space, so editors save their edits first. */
export function onWillChange(hook: (folder: string) => Promise<void> | void): () => void {
  willChange.add(hook);
  return () => willChange.delete(hook);
}

/** Called with the space folder and the path inside it when another device edited a file open in a live session. */
export function onLive(listener: (folder: string, path: string) => void): () => void {
  liveListeners.add(listener);
  return () => liveListeners.delete(listener);
}

function spaceOf(path: string): string {
  return path.split("/")[0];
}

// MARK: - Lifecycle

/** Starts with the signed-in account, or stops after signing out. */
export async function restart() {
  await stop();
  const account = identity.account;
  const fingerprint = identity.fingerprint;
  if (!account || !fingerprint) return;
  const run = ++generation;
  setSync({ status: jj.repository.status === "elsewhere" ? "elsewhere" : "starting", lastError: null });
  // Sync runs where the repository does: it exports and merges through it.
  try {
    await jj.whenOpen();
  } catch (err) {
    if (run === generation) setSync({ status: "error", lastError: `Couldn't start syncing: ${(err as Error).message ?? err}` });
    return;
  }
  if (run !== generation) return;
  setSync("status", "starting");
  if (!navigator.locks) return start(account, fingerprint, run);
  navigator.locks.request("typewright-sync", async () => {
    if (run !== generation) return;
    await new Promise<void>((resolve) => {
      releaseLock = resolve;
      void start(account, fingerprint, run);
    });
  });
}

async function start(account: Uint8Array, fingerprint: string, run: number) {
  try {
    wasmReady ??= init({ module_or_path: syncWasm });
    await wasmReady;
    dataDir = `sync/${fingerprint}`;
    let key = await fs.readFile(`${dataDir}/device.key`);
    if (key?.length !== 32) {
      key = generateDeviceKey();
      await fs.writeFile(`${dataDir}/device.key`, key, true);
    }
    // Path-by-path sync kept per-space state here; shares keep theirs in the repository.
    void fs.remove(`${dataDir}/state`, true).catch(() => {});
    const snapshot = await fs.readFile(`${dataDir}/replicas.bin`);
    const started = await SyncNode.start(key, account, snapshot ?? undefined, (event: string) => handle(event));
    if (run !== generation) {
      await started.stop();
      return;
    }
    node = started;
    setSync({ status: "running", deviceId: node.deviceId() });
    for (const id of Object.keys(sync.shares)) if (sync.shares[id]) open(id);
  } catch (err) {
    setSync({ status: "error", lastError: `Couldn't start syncing: ${(err as Error).message ?? err}` });
    releaseLock?.();
  }
}

export async function stop() {
  generation++;
  const current = node;
  node = null;
  if (current) {
    await saveSnapshot(current);
    await current.stop().catch(() => {});
  }
  for (const timer of publishTimers.values()) clearTimeout(timer);
  publishTimers.clear();
  runtimes.clear();
  queues.clear();
  livePaths.clear();
  setSync({ status: "off", deviceId: null, connected: [], devices: [], accountShares: [], shared: {}, statuses: {} });
  releaseLock?.();
  releaseLock = null;
}

if (typeof window !== "undefined") {
  // Replicas live in memory; their snapshot brings them back on the next visit.
  addEventListener("pagehide", () => node && void saveSnapshot(node));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden" && node) void saveSnapshot(node);
  });
  setInterval(() => node && void saveSnapshot(node), 30_000);
  jj.onCommit((changed) => committed(changed));
  jj.onMove((from, to) => moved(from, to));
  jj.onDelete((paths) => deleted(paths));
  jj.onRestore((from, to) => restored(from, to));
  createRoot(() =>
    createEffect(() => {
      void jj.repository.conflicted.length;
      updateStatuses();
    }),
  );
}

async function saveSnapshot(target: SyncNode) {
  try {
    const bytes = await target.snapshot();
    await fs.writeFile(`${dataDir}/replicas.bin`, bytes, true);
  } catch (err) {
    console.warn("Sync snapshot:", err);
  }
}

function scheduleSnapshot() {
  clearTimeout(snapshotTimer);
  snapshotTimer = setTimeout(() => node && void saveSnapshot(node), 3000);
}

// MARK: - Shares

/** Starts syncing a space, or any folder or file in one; the account lists it for the other devices. */
export async function share(path: string): Promise<string | null> {
  if (!node) return null;
  const existing = shareId(path);
  if (existing) return existing;
  const entry = await fs.stat(fs.join(SPACES, path));
  if (!entry) return null;
  const kind: ShareKind = entry.kind === "file" ? "file" : path.includes("/") ? "folder" : "space";
  const id = crypto.randomUUID().toLowerCase();
  setSync("shares", id, { path, kind });
  persist();
  node.addShare(id, fs.basename(path), kind, settings.deviceName);
  schedulePublish(id, 0);
  return id;
}

/** Stops syncing here; the files stay and the other devices keep syncing. */
export function stopSyncing(path: string) {
  const id = shareId(path);
  if (id) stopSyncingId(id);
}

export function stopSyncingId(id: string) {
  node?.closeShare(id);
  forget(id);
}

/** Drops a share stopped by a deletion, so restoring the item no longer resumes it. */
export function forgetParked(id: string) {
  setSync("parked", id, undefined!);
  delete rejoining[id];
  persist();
}

/** Stops syncing a share on every device; each keeps its files. */
export function removeEverywhere(id: string) {
  if (!node) return;
  node.removeShare(id);
  setSync("accountShares", (all) => all.filter((s) => s.id !== id));
  forget(id);
}

function forget(id: string) {
  batch(() => {
    setSync("shares", id, undefined!);
    setSync("statuses", id, undefined!);
    setSync("problems", id, undefined!);
  });
  runtimes.delete(id);
  void fs.remove(lfsListPath(id), true).catch(() => {});
  clearTimeout(publishTimers.get(id));
  publishTimers.delete(id);
  for (const key of [...livePaths]) if (key.startsWith(`${id}/`)) livePaths.delete(key);
  persist();
}

/** Where an own-account share lands by default: a new space under its name. */
export async function suggestedDestination(share: AccountShare): Promise<string> {
  return uniqueName(SPACES, share.name);
}

/** Checks a destination and makes its folder, so a new space shows up before its files. */
async function prepareDestination(dest: string, file: boolean, merge = false): Promise<string | null> {
  const path = fs.split(dest).join("/");
  if (!path) return fail("Pick a place in the library.");
  if (file && !path.includes("/")) return fail("A shared file goes into a space.");
  const existing = await fs.stat(fs.join(SPACES, path));
  if (existing && (!merge || (existing.kind === "file") !== file)) return fail(`“${fs.basename(path)}” already exists.`);
  await fs.makeDirectory(fs.join(SPACES, file ? fs.dirname(path) : path));
  await refreshSpaces();
  return path;
}

function fail(message: string): null {
  setSync("lastError", message);
  return null;
}

/** Starts syncing an account share at `dest` (a repository path not there yet); its files arrive after. */
export async function join(share: AccountShare, dest: string, merge = false): Promise<string | null> {
  if (!node) return null;
  const path = await prepareDestination(dest, share.kind === "file", merge);
  if (!path) return null;
  const previous = shareId(path);
  if (previous && previous !== share.id) stopSyncingId(previous);
  const kind: ShareKind = share.kind === "file" ? "file" : path.includes("/") ? "folder" : "space";
  batch(() => {
    setSync("shares", share.id, { path, kind });
    setSync("parked", share.id, undefined!);
  });
  persist();
  node.openShare(share.id, settings.deviceName);
  return path;
}

/** An invite link to the share at `path`; anyone holding it can sync and edit it from their account. */
export function inviteLink(path: string): string | null {
  const id = shareId(path);
  const share = id ? sync.shares[id] : undefined;
  if (!node || !id || !share) return null;
  const name = fs.basename(path);
  const secret = node.shareInvite(id, name, share.kind);
  // This device first: it's online right now, so the first join doesn't wait for the share's record.
  const hints = [sync.deviceId!, ...sync.devices.filter((d) => d !== sync.deviceId)];
  return core.inviteLink({ id, name, secret, hints, file: share.kind === "file" }) ?? null;
}

/** The web app's address for an invite link, which joins in the browser. */
export function webInviteLink(link: string): string {
  return core.webInviteLink(link, `${location.origin}${import.meta.env.BASE_URL}`) ?? link;
}

export function parseInvite(link: string): SpaceInvite | null {
  return core.parseInvite(link) ?? null;
}

/** Where a share is synced already, if it is. */
export function pathOf(id: string): string | null {
  return sync.shares[id]?.path ?? null;
}

/** Starts syncing a share from an invite at `dest`; the account lists it for this user's other devices. */
export async function joinInvite(invite: SpaceInvite, dest: string): Promise<string | null> {
  if (!node) return null;
  const existing = pathOf(invite.id);
  if (existing) {
    node.joinShare(invite.id, invite.name, sync.shares[invite.id].kind, invite.secret, invite.hints, settings.deviceName);
    return existing;
  }
  const path = await prepareDestination(dest, !!invite.file);
  if (!path) return null;
  const kind: ShareKind = invite.file ? "file" : path.includes("/") ? "folder" : "space";
  batch(() => {
    setSync("shares", invite.id, { path, kind });
    setSync("parked", invite.id, undefined!);
  });
  persist();
  node.joinShare(invite.id, invite.name, kind, invite.secret, invite.hints, settings.deviceName);
  return path;
}

function open(id: string) {
  if (!node || !isActive(id)) return;
  const parked = rejoining[id];
  if (parked) {
    // It left the account when its folder was deleted; list it again under the same id.
    delete rejoining[id];
    if (parked.shared && parked.secret) node.joinShare(id, parked.name, parked.share.kind, parked.secret, [], settings.deviceName);
    else node.addShare(id, parked.name, parked.share.kind, settings.deviceName);
    persist();
  } else {
    node.openShare(id, settings.deviceName);
  }
  enqueue(id, () => seed(id));
  schedulePublish(id, 0);
}

// MARK: - Moving, deleting and restoring

/** Follows a folder or file renamed or moved here; nothing syncs for the move itself. */
export function moved(from: string, to: string) {
  let changed = false;
  batch(() => {
    for (const [id, share] of Object.entries(sync.shares)) {
      if (!share) continue;
      let path: string | null = null;
      if (share.path === from) path = to;
      else if (share.path.startsWith(`${from}/`)) path = to + share.path.slice(from.length);
      if (path === null) continue;
      setSync("shares", id, "path", path);
      setSync("problems", id, undefined!);
      changed = true;
    }
  });
  if (changed) persist();
}

/** Shares whose root went with a deletion stop here (others keep syncing them); ones inside a deleted folder too. */
function deleted(paths: string[]) {
  let changed = false;
  for (const [id, share] of Object.entries(sync.shares)) {
    if (!share || !paths.some((p) => share.path === p || share.path.startsWith(`${p}/`))) continue;
    const listed = sync.accountShares.find((s) => s.id === id);
    const name = listed?.name ?? fs.basename(share.path);
    const shared = listed?.shared ?? false;
    const secret = node && shared ? node.shareInvite(id, name, share.kind) : undefined;
    setSync("parked", id, { share: { ...share }, name, shared, secret, left: node !== null });
    node?.closeShare(id);
    forget(id);
    changed = true;
  }
  if (changed) persist();
}

/** A deleted item came back at `to`: shares parked at or inside it sync again from there. */
function restored(from: string, to: string) {
  const resumed: string[] = [];
  for (const [id, entry] of Object.entries(sync.parked)) {
    if (!entry || !(entry.share.path === from || entry.share.path.startsWith(`${from}/`))) continue;
    const path = to + entry.share.path.slice(from.length);
    setSync("shares", id, { path, kind: entry.share.kind });
    setSync("parked", id, undefined!);
    if (entry.left) rejoining[id] = entry;
    resumed.push(id);
  }
  if (!resumed.length) return;
  persist();
  resumed.forEach(open);
}

// MARK: - Events

type Event = {
  type: string;
  message?: string;
  peers?: string[];
  devices?: string[];
  shared?: Record<string, string[]>;
  shares?: { id: string; name?: string; kind?: string; members?: string[]; shared?: boolean; joined?: boolean; devices?: boolean; host?: string }[];
  removed?: string[];
  reset?: string[];
  share?: string;
  space?: string;
  device?: string;
  node?: string;
  name?: string | null;
  path?: string;
};

function handle(text: string) {
  let event: Event;
  try {
    event = JSON.parse(text);
  } catch {
    return;
  }
  switch (event.type) {
    case "status":
      setSync({ connected: event.peers ?? [], devices: event.devices ?? [], shared: event.shared ?? {} });
      updateStatuses();
      break;
    case "shares": {
      const active = new Set(Object.keys(sync.shares).filter(isActive));
      const all = (event.shares ?? [])
        .map((s) => ({
          id: s.id,
          name: s.name ?? "Space",
          kind: (["space", "folder", "file"].includes(s.kind ?? "") ? s.kind : "space") as ShareKind,
          members: s.members ?? [],
          shared: s.shared ?? false,
          joined: s.joined ?? false,
          devices: s.devices ?? true,
          host: s.host,
        }))
        .sort((a, b) => a.name.localeCompare(b.name));
      setSync("accountShares", all);
      // Removed from all devices elsewhere: stop here too, keeping the files.
      for (const id of event.removed ?? []) {
        if (sync.shares[id]) {
          node?.closeShare(id);
          forget(id);
        }
        if (sync.parked[id] || rejoining[id]) {
          setSync("parked", id, undefined!);
          delete rejoining[id];
          persist();
        }
      }
      for (const id of Object.keys(sync.shares)) {
        if (!sync.shares[id]) continue;
        if (!isActive(id) || event.reset?.includes(id)) {
          clearTimeout(publishTimers.get(id));
          publishTimers.delete(id);
          runtimes.delete(id);
          queues.delete(id);
          setSync("statuses", id, undefined!);
        }
        if (isActive(id) && (!active.has(id) || event.reset?.includes(id))) open(id);
      }
      updateStatuses();
      scheduleSnapshot();
      break;
    }
    case "head": {
      if (!event.share || !sync.shares[event.share] || !isActive(event.share) || !event.device || !event.node) return;
      runtime(event.share).heads.set(event.device, { node: event.node, name: event.name ?? null });
      mergeHeads(event.share);
      updateStatus(event.share);
      scheduleSnapshot();
      break;
    }
    case "published-node":
      if (event.share) updateStatus(event.share);
      scheduleSnapshot();
      break;
    case "live": {
      const share = event.space ? sharePath(event.space) : null;
      if (!share || event.path === undefined) return;
      const path = core.shareFilePath(share, event.path);
      const folder = spaceOf(path);
      if (path.length > folder.length) liveListeners.forEach((l) => l(folder, path.slice(folder.length + 1)));
      break;
    }
    case "error":
      setSync("lastError", event.message ?? null);
      console.warn("Sync:", event.message);
      break;
  }
}

// MARK: - Nodes

/** Commits reach the shares they touch. */
function committed(changed: string[]) {
  if (!node || !changed.length) return;
  for (const id of core.sharesTouched(sharePaths(), changed)) schedulePublish(id);
}

function schedulePublish(id: string, delay = 300) {
  clearTimeout(publishTimers.get(id));
  publishTimers.set(
    id,
    setTimeout(() => {
      publishTimers.delete(id);
      enqueue(id, () => publish(id));
    }, delay),
  );
  updateStatus(id);
}

function enqueue(id: string, work: () => Promise<void>) {
  const r = runtime(id);
  r.working++;
  updateStatus(id);
  const run = generation;
  const previous = queues.get(id) ?? Promise.resolve();
  const next = previous
    .then(() => (run === generation && runtimes.get(id) === r ? work() : undefined))
    .catch((err) => { if (runtimes.get(id) === r) setSync("lastError", `Sync: ${(err as Error).message ?? err}`); })
    .finally(() => {
      r.working--;
      updateStatus(id);
    });
  queues.set(id, next);
}

/** Merges every head this device doesn't have yet. */
function mergeHeads(id: string) {
  const r = runtimes.get(id);
  if (!r || !sync.shares[id]) return;
  for (const [device, head] of r.heads) {
    if (core.needsMerge(r.head ?? undefined, r.ancestry, head.node)) enqueue(id, () => merge(id, device));
  }
}

function isBusy(err: unknown): boolean {
  return (err as jj.RepositoryError)?.busy === true;
}

function message(err: unknown): string {
  return (err as Error)?.message ?? String(err);
}

/** Exports the share's content as a node and publishes it unless the devices already have it. */
async function publish(id: string) {
  if (!isActive(id)) return;
  const share = sync.shares[id];
  const current = node;
  if (!current || !share) return;
  const entry = await fs.stat(fs.join(SPACES, share.path));
  if (!entry || (entry.kind === "file") !== (share.kind === "file")) {
    // Exporting nothing would delete the share on every device; a moved folder is no reason for that.
    setSync("problems", id, `“${fs.basename(share.path)}” moved or was deleted. Put it back, or stop syncing it.`);
    return;
  }
  setSync("problems", id, undefined!);
  const r = runtime(id);
  // A share just joined waits for its first node instead of publishing an empty one.
  if (r.head === null && entry.kind === "dir") {
    const children = await fs.list(fs.join(SPACES, share.path));
    if (children.every((c) => fs.basename(c.path).startsWith("."))) return;
  }
  let manifest: Manifest;
  try {
    manifest = await jj.request<Manifest>("twj_export_node", id, share.path);
  } catch (err) {
    if (isBusy(err)) schedulePublish(id, 2000);
    // Conflicts block exports until they're resolved; resolving commits and comes back here.
    else if (!message(err).includes("unresolved conflicts")) setSync("problems", id, message(err));
    return;
  }
  if (!manifest.node || !isActive(id) || runtimes.get(id) !== r) return;
  r.head = manifest.node;
  r.ancestry = manifest.ancestry ?? [];
  const lfs = Object.entries(manifest.files ?? {}).filter(([, f]) => f.lfs && f.blake3);
  r.lfs = new Set(lfs.map(([, f]) => f.blake3!));
  if (r.published !== manifest.node) {
    const objects = await jj.nodeObjects(manifest.node);
    const sp = sharePath(id)!;
    const seeds: [string, Uint8Array][] = [];
    for (const [rel, file] of lfs) {
      if (r.seeded.has(file.blake3!)) continue;
      const bytes = await fs.readFile(fs.join(SPACES, core.shareFilePath(sp, rel)));
      if (bytes) seeds.push([file.blake3!, bytes]);
    }
    if (node !== current || !isActive(id) || runtimes.get(id) !== r) return;
    await current.publishNode(id, JSON.stringify(manifest), objects, seeds);
    seeds.forEach(([hash]) => r.seeded.add(hash));
    r.published = manifest.node;
    await fs.writeFile(lfsListPath(id), JSON.stringify(lfs.map(([rel, f]) => [f.blake3, rel])), true);
  }
  mergeHeads(id);
}

function lfsListPath(id: string): string {
  return `${dataDir}/lfs/${id}.json`;
}

/** Puts the LFS files of the last published node back into the blob store after a reload, so other devices can
 * fetch them even while publishing waits (on conflicts, say). */
async function seed(id: string) {
  const current = node;
  const sp = sharePath(id);
  const text = await fs.readText(lfsListPath(id));
  if (!current || !sp || !text) return;
  const r = runtime(id);
  const pairs: [string, Uint8Array][] = [];
  for (const [hash, rel] of JSON.parse(text) as [string, string][]) {
    if (r.seeded.has(hash)) continue;
    const bytes = await fs.readFile(fs.join(SPACES, core.shareFilePath(sp, rel)));
    if (bytes) pairs.push([hash, bytes]);
  }
  if (!pairs.length || node !== current) return;
  for (const hash of await current.seedLfs(id, pairs)) r.seeded.add(hash);
}

/** Fetches another device's head and merges it into the share; a clean merge is published right away. */
async function merge(id: string, device: string) {
  const share = sync.shares[id];
  const r = runtimes.get(id);
  const head = r?.heads.get(device);
  const current = node;
  if (!current || !share || !r || !head || !core.needsMerge(r.head ?? undefined, r.ancestry, head.node)) return;
  const fetched = (await current.fetchNode(id, device, [...r.lfs])) as {
    manifest: string;
    objects: [string, Uint8Array][];
    lfs: [string, Uint8Array][];
  };
  const fetchedNode = (JSON.parse(fetched.manifest) as Manifest).node;
  if (!fetchedNode || !core.needsMerge(r.head ?? undefined, r.ancestry, fetchedNode)) return;
  const folder = spaceOf(share.path);
  for (const hook of willChange) await hook(folder);
  if (!isActive(id) || runtimes.get(id) !== r) return;
  const sp = sharePath(id)!;
  const keep = [...livePaths].filter((k) => k.startsWith(`${id}/`)).map((k) => core.shareFilePath(sp, k.slice(id.length + 1)));
  let merged: jj.MergeResult;
  try {
    merged = await jj.mergeNode({
      share: id,
      path: share.path,
      manifest: fetched.manifest,
      objects: fetched.objects,
      lfs: fetched.lfs,
      label: head.name ?? "Other Device",
      keep,
    });
  } catch (err) {
    if (isBusy(err)) setTimeout(() => mergeHeads(id), 2000);
    // A share waiting on conflicts merges again once they're resolved.
    else if (!message(err).includes("unresolved conflicts")) setSync("lastError", message(err));
    return;
  }
  // Publishing exports again, on top of the merge when live files kept their own content.
  if (merged.node) await publish(id);
}

// MARK: - Status

function updateStatuses() {
  for (const id of Object.keys(sync.shares)) if (sync.shares[id]) updateStatus(id);
}

function updateStatus(id: string) {
  if (!isActive(id)) return;
  const share = sync.shares[id];
  if (!share) return;
  const r = runtimes.get(id);
  const peers: PeerHead[] = [...(r?.heads ?? [])].map(([device, h]) => ({ device, node: h.node, connected: sync.connected.includes(device) }));
  const members = new Set([...(sync.accountShares.find((s) => s.id === id)?.members ?? []), ...(r?.heads.keys() ?? [])]);
  members.delete(sync.deviceId ?? "");
  const conflicted = jj.repository.conflicted.some((p) => p === share.path || p.startsWith(`${share.path}/`));
  const working = (r?.working ?? 0) > 0 || publishTimers.has(id);
  const next = core.shareStatus(r?.head ?? undefined, peers, members.size, conflicted, working) as ShareStatus;
  if (sync.statuses[id] !== next) setSync("statuses", id, next);
}

// MARK: - Live editing

/** The share and the path inside it holding `path` of space `folder`, while syncing runs. */
function livePlace(folder: string, path: string) {
  if (!node) return null;
  return core.sharePlace(sharePaths(), `${folder}/${path}`) ?? null;
}

/** Whether a file can be edited live: it's in a share and syncing runs. */
export function canEditLive(folder: string, path: string): boolean {
  return livePlace(folder, path) !== null;
}

export function liveOpen(folder: string, path: string, text: string) {
  const place = livePlace(folder, path);
  if (node && place) node.liveOpen(place.id, place.inside, text, settings.deviceName);
}

export function liveClose(folder: string, path: string) {
  const place = livePlace(folder, path);
  if (!node || !place) return;
  livePaths.delete(`${place.id}/${place.inside}`);
  node.liveClose(place.id, place.inside);
}

/** `step` 1 undoes and 2 redoes this device's last edit of the file. */
export function liveSync(folder: string, path: string, text: string, location: number, length: number, step = 0): LiveResult | null {
  const place = livePlace(folder, path);
  if (!node || !place) return null;
  const result = JSON.parse(node.liveSync(place.id, place.inside, text, location, length, step)) as Partial<LiveResult>;
  const full: LiveResult = { edits: [], adopted: null, cursors: [], peers: 0, undone: false, ...result };
  const key = `${place.id}/${place.inside}`;
  if (full.peers > 0) livePaths.add(key);
  else livePaths.delete(key);
  return full;
}
