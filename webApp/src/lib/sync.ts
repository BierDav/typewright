// Syncs the spaces the user picked across their devices and with the people they invited, like the
// Mac app's `SyncService`: `irohBridge` (built for wasm) moves the data, `SpaceSync` from the Rust
// core decides what to do, and this applies it to the space folders in origin storage.
//
// Only one tab per browser runs the node (a Web Lock decides); others still edit the same folders,
// and their writes reach the syncing tab through the storage change channel.
import { batch } from "solid-js";
import { createStore } from "solid-js/store";
import init, { generateDeviceKey, hashBytes, SyncNode } from "~/wasm/sync/sync.js";
import syncWasm from "~/wasm/sync/sync_bg.wasm?url";
import * as core from "./core";
import { IgnoreRules, type LocalFile, merge3, type RemoteEntry, type SpaceInvite, SpaceSync, type SyncAction } from "./core";
import { identity } from "./identity";
import { isEditable, kindWithContents } from "./kinds";
import { settings } from "./settings";
import { createSpace, SPACES, spacePath } from "./spaces";
import * as fs from "./storage";

export type AccountSpace = { id: string; name: string; members: string[]; shared: boolean };

export type LiveResult = {
  edits: { location: number; length: number; text: string }[];
  adopted: { base: string; theirs: string } | null;
  cursors: { device: string; name: string; location: number; length: number }[];
  peers: number;
  undone: boolean;
};

/** Live files above this size sync on save only. */
export const LIVE_LIMIT = 512 * 1024;
const SPACES_KEY = "typewright.syncedSpaces";

export const [sync, setSync] = createStore({
  status: "off" as "off" | "starting" | "running" | "elsewhere" | "error",
  deviceId: null as string | null,
  /** Devices this one is connected to right now. */
  connected: [] as string[],
  /** Every device listed for the account, this one included. */
  devices: [] as string[],
  accountSpaces: [] as AccountSpace[],
  /** Synced spaces on this device: id to folder name. */
  spaces: loadSpaces(),
  /** Devices of any account listed for each shared space. */
  shared: {} as Record<string, string[]>,
  lastError: null as string | null,
});

function loadSpaces(): Record<string, string> {
  try {
    return JSON.parse(localStorage.getItem(SPACES_KEY) ?? "{}");
  } catch {
    return {};
  }
}

type Cached = { size: number; modified: number; hash: string; isText: boolean };

let node: SyncNode | null = null;
let wasmReady: Promise<unknown> | null = null;
let dataDir = "";
let releaseLock: (() => void) | null = null;
let unwatch: (() => void) | null = null;
let generation = 0;
const engines = new Map<string, SpaceSync>();
const ignores = new Map<string, IgnoreRules>();
/** Paths of each space's last scan, files and folders, for naming conflict copies. */
const known = new Map<string, Set<string>>();
const scanning = new Set<string>();
const scanPending = new Set<string>();
const scanned = new Set<string>();
/** Remote changes of a space apply one after another. */
const queues = new Map<string, Promise<void>>();
const hashes = new Map<string, Cached>();
const seeded = new Set<string>();
/** `space/path` of files open here and on another device; file sync leaves them to the live session. */
const livePaths = new Set<string>();
const willChange = new Set<(folder: string) => Promise<void> | void>();
const liveListeners = new Set<(id: string, path: string) => void>();
let saveTimer: ReturnType<typeof setTimeout> | undefined;
let snapshotTimer: ReturnType<typeof setTimeout> | undefined;

export function isRunning(): boolean {
  return node !== null;
}

/** Hashes like blobs are (BLAKE3 hex); needs the module, which `restart` loads. */
export function blake3(bytes: Uint8Array): string {
  return hashBytes(bytes);
}

export function spaceId(folder: string): string | undefined {
  return Object.entries(sync.spaces).find(([, f]) => f === folder)?.[0];
}

export function isSynced(folder: string): boolean {
  return spaceId(folder) !== undefined;
}

/** Whether other accounts sync the space too. */
export function isShared(folder: string): boolean {
  const id = spaceId(folder);
  return !!id && sync.accountSpaces.some((s) => s.id === id && s.shared);
}

/** Account spaces another device syncs and this one doesn't. */
export function elsewhere(): AccountSpace[] {
  return sync.accountSpaces.filter((s) => !sync.spaces[s.id] && s.members.some((m) => m !== sync.deviceId));
}

/** Runs before sync replaces files of a space, so editors save their edits first. */
export function onWillChange(hook: (folder: string) => Promise<void> | void): () => void {
  willChange.add(hook);
  return () => willChange.delete(hook);
}

/** Called when another device edited a file open in a live session here. */
export function onLive(listener: (id: string, path: string) => void): () => void {
  liveListeners.add(listener);
  return () => liveListeners.delete(listener);
}

function persistSpaces() {
  localStorage.setItem(SPACES_KEY, JSON.stringify(sync.spaces));
}

// MARK: - Lifecycle

/** Starts with the signed-in account, or stops after signing out. */
export async function restart() {
  await stop();
  const account = identity.account;
  if (!account || !identity.fingerprint) return;
  const run = ++generation;
  setSync({ status: "starting", lastError: null });
  if (!navigator.locks) return start(account, identity.fingerprint, run);
  // One tab per browser runs the node; the lock passes on when it closes.
  navigator.locks.request("typewright-sync", { ifAvailable: true }, async (lock) => {
    if (!lock) {
      setSync("status", "elsewhere");
      navigator.locks.request("typewright-sync", async () => {
        if (run !== generation) return;
        await holdWhileRunning(account, identity.fingerprint!, run);
      });
      return;
    }
    await holdWhileRunning(account, identity.fingerprint!, run);
  });
}

async function holdWhileRunning(account: Uint8Array, fingerprint: string, run: number) {
  await new Promise<void>((resolve) => {
    releaseLock = resolve;
    void start(account, fingerprint, run);
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
    const snapshot = await fs.readFile(`${dataDir}/replicas.bin`);
    const started = await SyncNode.start(key, account, snapshot ?? undefined, (event: string) => handle(event));
    if (run !== generation) {
      await started.stop();
      return;
    }
    node = started;
    setSync({ status: "running", deviceId: node.deviceId() });
    unwatch = fs.onChange(({ paths }) => {
      for (const path of paths) {
        const folder = fs.split(path)[0] === SPACES ? fs.split(path)[1] : undefined;
        const id = folder && spaceId(folder);
        if (id) scheduleScan(id);
      }
    });
    for (const [id, folder] of Object.entries(sync.spaces)) open(id, folder);
  } catch (err) {
    setSync({ status: "error", lastError: `Couldn't start syncing: ${(err as Error).message ?? err}` });
    releaseLock?.();
  }
}

export async function stop() {
  generation++;
  const current = node;
  node = null;
  unwatch?.();
  unwatch = null;
  if (current) {
    saveState();
    await saveSnapshot(current);
    await current.stop().catch(() => {});
  }
  engines.clear();
  scanned.clear();
  livePaths.clear();
  setSync({ status: "off", deviceId: null, connected: [], devices: [], accountSpaces: [], shared: {} });
  releaseLock?.();
  releaseLock = null;
}

if (typeof window !== "undefined") {
  // Replicas live in memory; their snapshot brings them back on the next visit.
  addEventListener("pagehide", () => {
    saveState();
    if (node) void saveSnapshot(node);
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden" && node) void saveSnapshot(node);
  });
  setInterval(() => node && void saveSnapshot(node), 30_000);
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

// MARK: - Spaces

/** Starts syncing a space; the account lists it for the other devices. */
export function share(folder: string) {
  if (!node || isSynced(folder)) return;
  const id = crypto.randomUUID().toLowerCase();
  remember(id, folder);
  node.shareSpace(id, folder);
  open(id, folder, false);
}

/** Stops syncing here; the files stay and the other devices keep syncing. */
export function stopSyncing(folder: string) {
  const id = spaceId(folder);
  if (!id) return;
  node?.closeSpace(id);
  forget(id);
}

/** Stops syncing a space on every device; each keeps its files. */
export function removeEverywhere(id: string) {
  if (!node) return;
  node.removeSpace(id);
  setSync("accountSpaces", (all) => all.filter((s) => s.id !== id));
  forget(id);
}

function forget(id: string) {
  engines.delete(id);
  known.delete(id);
  setSync("spaces", id, undefined!);
  persistSpaces();
  void fs.remove(stateFile(id), true);
}

/** Downloads a space from the other devices into a new space folder. */
export async function join(space: AccountSpace): Promise<string | null> {
  if (!node) return null;
  const folder = await createSpace(space.name, false);
  remember(space.id, folder);
  open(space.id, folder);
  return folder;
}

/** An invite link to the space; anyone holding it can sync and edit the space from their account. */
export function inviteLink(folder: string): string | null {
  const id = spaceId(folder);
  if (!node || !id) return null;
  const secret = node.invite(id, folder);
  // This device first: it's online right now, so the first join doesn't wait for the space's record.
  const hints = [sync.deviceId!, ...sync.devices.filter((d) => d !== sync.deviceId)];
  return core.inviteLink({ id, name: folder, secret, hints }) ?? null;
}

/** The web app's address for an invite link, which joins in the browser. */
export function webInviteLink(link: string): string {
  return core.webInviteLink(link, `${location.origin}${import.meta.env.BASE_URL}`) ?? link;
}

export function parseInvite(link: string): SpaceInvite | null {
  return core.parseInvite(link) ?? null;
}

/** Downloads a space from an invite into a new space folder; the account lists it for the other devices. */
export async function joinInvite(invite: SpaceInvite): Promise<string | null> {
  if (!node) return null;
  if (sync.spaces[invite.id]) return sync.spaces[invite.id];
  const folder = await createSpace(invite.name, false);
  remember(invite.id, folder);
  node.joinSpace(invite.id, invite.name, invite.secret, invite.hints);
  open(invite.id, folder, false);
  return folder;
}

/** Follows a space folder that was renamed here. */
export function renamed(old: string, folder: string) {
  const id = spaceId(old);
  if (!id) return;
  setSync("spaces", id, folder);
  persistSpaces();
}

function remember(id: string, folder: string) {
  setSync("spaces", id, folder);
  persistSpaces();
}

function stateFile(id: string): string {
  return `${dataDir}/state/${id}.txt`;
}

async function open(id: string, folder: string, announce = true) {
  if (!node) return;
  const engine = new SpaceSync(settings.lfsThresholdMB * 1_048_576);
  const state = await fs.readText(stateFile(id));
  if (state) engine.load(state);
  engines.set(id, engine);
  // The first scan has to finish before replica entries are compared with the folder.
  scheduleScan(id, 0);
  if (announce) node.openSpace(id);
  else node.listSpace(id);
}

/** Applies a changed merge limit to every open space. */
export function setLfsThreshold(megabytes: number) {
  for (const engine of engines.values()) engine.lfsThreshold = megabytes * 1_048_576;
}

// MARK: - Local changes

function scheduleScan(id: string, delay = 500) {
  scanPending.add(id);
  if (scanning.has(id)) return;
  scanning.add(id);
  void (async () => {
    while (scanPending.has(id)) {
      await new Promise((r) => setTimeout(r, delay));
      scanPending.delete(id);
      await scan(id).catch((err) => setSync("lastError", `Scan: ${err.message}`));
    }
    scanning.delete(id);
  })();
}

async function describe(abs: string, path: string, file: File): Promise<LocalFile | null> {
  const cached = hashes.get(abs);
  if (cached && cached.size === file.size && cached.modified === file.lastModified) {
    return { path, hash: cached.hash, size: file.size, isText: cached.isText };
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  const hash = hashBytes(bytes);
  // Kinds like PDF, Office and images, and contents that sniff as binary, are never diffed.
  const isText = isEditable(kindWithContents(path, fs.decodeText(bytes) !== null));
  hashes.set(abs, { size: file.size, modified: file.lastModified, hash, isText });
  // Browsers keep blobs in memory; the files themselves are what other devices download.
  if (node && !seeded.has(hash)) {
    seeded.add(hash);
    void node.seed(bytes).catch(() => seeded.delete(hash));
  }
  return { path, hash, size: file.size, isText };
}

/** Walks a space like git would: `.gitignore` rules apply and ignored folders aren't entered. */
async function walk(root: string): Promise<{ files: LocalFile[]; ignore: IgnoreRules; paths: Set<string> }> {
  const ignore = new IgnoreRules();
  const files: LocalFile[] = [];
  const paths = new Set<string>();
  async function visit(rel: string) {
    const items = await fs.children(fs.join(root, rel));
    const gitignore = items.find((i) => i.name === ".gitignore" && i.file);
    if (gitignore?.file) ignore.add(rel, await gitignore.file.text());
    for (const item of items) {
      const path = rel ? `${rel}/${item.name}` : item.name;
      paths.add(path);
      if (item.name.endsWith(".crswap")) continue;
      if (item.dir) {
        if (!ignore.matches(path, true)) await visit(path);
      } else if (item.file && !ignore.matches(path, false)) {
        const local = await describe(fs.join(root, path), path, item.file);
        if (local) files.push(local);
      }
    }
  }
  await visit("");
  return { files, ignore, paths };
}

async function scan(id: string) {
  const folder = sync.spaces[id];
  const engine = engines.get(id);
  if (!folder || !engine || !node) return;
  // A missing folder (renamed or deleted meanwhile) must not read as every file deleted.
  if (!(await fs.exists(spacePath(folder)))) return;
  const result = await walk(spacePath(folder));
  ignores.set(id, result.ignore);
  known.set(id, result.paths);
  scanned.add(id);
  const actions = engine.scan(result.files, result.ignore);
  for (const action of actions) await perform(action, id);
  if (actions.length) scheduleSave();
}

async function localFile(id: string, path: string): Promise<LocalFile | null> {
  const abs = spacePath(sync.spaces[id], path);
  const file = await fs.readBlob(abs);
  return file ? describe(abs, path, file) : null;
}

// MARK: - Events

type Event = {
  type: string;
  message?: string;
  device?: string;
  peers?: string[];
  devices?: string[];
  shared?: Record<string, string[]>;
  spaces?: { id: string; name?: string; members?: string[]; shared?: boolean }[];
  removed?: string[];
  space?: string;
  entries?: { path: string; hash: string; size: number; deleted: boolean }[];
  path?: string;
  hash?: string;
  size?: number;
  deleted?: boolean;
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
      batch(() => {
        setSync({ connected: event.peers ?? [], devices: event.devices ?? [], shared: event.shared ?? {} });
      });
      break;
    case "spaces": {
      const all = (event.spaces ?? [])
        .map((s) => ({ id: s.id, name: s.name ?? "Space", members: s.members ?? [], shared: s.shared ?? false }))
        .sort((a, b) => a.name.localeCompare(b.name));
      setSync("accountSpaces", all);
      // Removed from all devices elsewhere: stop here too, keeping the files.
      for (const id of event.removed ?? []) {
        if (sync.spaces[id]) {
          node?.closeSpace(id);
          forget(id);
        }
      }
      scheduleSnapshot();
      break;
    }
    case "live":
      if (event.space && event.path) liveListeners.forEach((l) => l(event.space!, event.path!));
      break;
    case "entries":
      if (!event.space) return;
      for (const e of event.entries ?? []) enqueue(event.space, { path: e.path, hash: e.hash, size: e.size, deleted: e.deleted });
      scheduleSnapshot();
      break;
    case "remote":
      if (!event.space || !event.path || !event.hash) return;
      enqueue(event.space, { path: event.path, hash: event.hash, size: event.size ?? 0, deleted: event.deleted ?? false });
      scheduleSnapshot();
      break;
    case "published":
      if (!event.space || !event.path || !event.hash) return;
      engines.get(event.space)?.published(event.path, event.hash, event.deleted ?? false);
      scheduleSave();
      scheduleSnapshot();
      break;
    case "error":
      setSync("lastError", event.message ?? null);
      console.warn("Sync:", event.message);
      break;
  }
}

function enqueue(id: string, entry: RemoteEntry) {
  const previous = queues.get(id) ?? Promise.resolve();
  queues.set(
    id,
    previous.then(() => applyRemote(entry, id)).catch((err) => setSync("lastError", `Sync: ${err.message}`)),
  );
}

async function applyRemote(entry: RemoteEntry, id: string) {
  // Wait for the first scan, which knows the ignore rules.
  while (!scanned.has(id) && engines.has(id)) await new Promise((r) => setTimeout(r, 100));
  const folder = sync.spaces[id];
  const engine = engines.get(id);
  if (!folder || !engine) return;
  for (const hook of willChange) await hook(folder);
  const local = await localFile(id, entry.path);
  const ignore = ignores.get(id) ?? new IgnoreRules();
  // The live session already has this version's edits; writing it could undo newer ones.
  if (livePaths.has(`${id}/${entry.path}`) && !entry.deleted && local) {
    engine.accepted(entry.path, entry.hash);
    scheduleSave();
    return;
  }
  const paths = known.get(id) ?? new Set();
  const actions = engine.remote(entry, local, ignore, (candidate) => paths.has(candidate));
  for (const action of actions) await perform(action, id);
  if (actions.length) scheduleSave();
}

// MARK: - Live editing

export function liveOpen(folder: string, path: string, text: string) {
  const id = spaceId(folder);
  if (node && id) node.liveOpen(id, path, text, settings.deviceName);
}

export function liveClose(folder: string, path: string) {
  const id = spaceId(folder);
  if (!node || !id) return;
  livePaths.delete(`${id}/${path}`);
  node.liveClose(id, path);
}

/** `step` 1 undoes and 2 redoes this device's last edit of the file. */
export function liveSync(folder: string, path: string, text: string, location: number, length: number, step = 0): LiveResult | null {
  const id = spaceId(folder);
  if (!node || !id) return null;
  const result = JSON.parse(node.liveSync(id, path, text, location, length, step)) as Partial<LiveResult>;
  const full: LiveResult = { edits: [], adopted: null, cursors: [], peers: 0, undone: false, ...result };
  if (full.peers > 0) livePaths.add(`${id}/${path}`);
  else livePaths.delete(`${id}/${path}`);
  return full;
}

// MARK: - Actions

async function perform(action: SyncAction, id: string) {
  const folder = sync.spaces[id];
  const engine = engines.get(id);
  if (!node || !folder || !engine) return;
  const target = spacePath(folder, action.path);
  switch (action.kind) {
    case "publish": {
      const bytes = await fs.readFile(target);
      // Gone since the scan; the next one unpublishes it.
      if (bytes) node.publish(id, action.path, bytes);
      break;
    }
    case "unpublish":
      node.unpublish(id, action.path);
      break;
    case "write":
      engine.wrote(action.path, action.hash, await place(action.hash, action.size, target));
      break;
    case "trash":
      await moveToTrash(folder, action.path);
      break;
    case "merge":
      await performMerge(action, id, folder, engine);
      break;
    case "conflictCopy":
      await place(action.hash, action.size, spacePath(folder, action.copyPath));
      known.get(id)?.add(action.copyPath);
      break;
  }
}

/** Three-way merge of a small text file both sides edited; leftovers become a conflict copy. */
async function performMerge(merge: Extract<SyncAction, { kind: "merge" }>, id: string, folder: string, engine: SpaceSync) {
  const target = spacePath(folder, merge.path);
  const base = await text(merge.baseHash);
  const remote = await text(merge.remoteHash);
  const local = await fs.readText(target);
  if (base !== null && remote !== null && local !== null) {
    const result = merge3(base, local, remote);
    if (result.conflicts === 0) {
      await fs.writeFile(target, result.text);
      engine.merged(merge.path, merge.remoteHash);
      scheduleScan(id);
      return;
    }
  }
  const size = remote === null ? 0 : new TextEncoder().encode(remote).length;
  const paths = known.get(id) ?? new Set();
  const fallback = engine.mergeFailed(merge.path, merge.remoteHash, size, (candidate) => paths.has(candidate));
  for (const action of fallback) await perform(action, id);
}

async function place(hash: string, size: number, target: string): Promise<boolean> {
  try {
    const bytes = size > 0 ? await node!.readBlob(hash) : new Uint8Array(0);
    await fs.writeFile(target, bytes);
    return true;
  } catch (err) {
    setSync("lastError", `Couldn't write ${fs.basename(target)}: ${(err as Error).message ?? err}`);
    return false;
  }
}

async function text(hash: string): Promise<string | null> {
  try {
    return new TextDecoder().decode(await node!.readBlob(hash));
  } catch {
    return null;
  }
}

/** Deleted files go to the trash in origin storage, where Settings can bring them back. */
export async function moveToTrash(folder: string, path: string) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  await fs.move(spacePath(folder, path), fs.join("trash", stamp, folder, path));
}

// MARK: - State

function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveState, 1000);
}

function saveState() {
  if (!dataDir) return;
  for (const [id, engine] of engines) void fs.writeFile(stateFile(id), engine.save(), true);
}

