// Hosts the internal jj repository (`jjBridge` built for wasm32-wasip1) off the main thread. Its working copy is
// origin storage's `spaces/` folder (each space a top-level folder, `.jj` beside them); the module reads and writes
// it directly through the OPFS host in `lib/wasi.ts`. `jj-host/` beside it keeps the host's mtimes (`state.json`)
// and a journal of files being written, so a tab closed mid-call can't leave a file looking unchanged.
import jspiUrl from "~/wasm/jj/jj_bridge.wasm?url";
import asyncifyUrl from "~/wasm/jj/jj_bridge.asyncify.wasm?url";
import { hasJSPI, type HostState, moveFile, OpfsFS, unlocked, Wasi } from "~/lib/wasi";

export type Arg = string | number | null;
export type Request =
  | { id: number; op: "open"; lfsLimit: number; stale: string[] }
  | { id: number; op: "call"; fn: string; args: Arg[] }
  | { id: number; op: "invalidate"; paths: string[] }
  | { id: number; op: "nodeObjects"; node: string }
  | { id: number; op: "mergeNode"; share: string; path: string; manifest: string; objects: [string, Uint8Array][]; lfs: [string, Uint8Array][]; label: string; keep: string[] };
export type Response =
  | { id: number; ok: true; value: unknown; written: string[]; mode?: "jspi" | "asyncify" }
  | { id: number; ok: false; error: string; fatal?: boolean; busy?: boolean };

export const ROOT = "spaces";
const HOST = "jj-host";
const GUEST_ROOT = "/repo";

/** Argument kinds after the repo handle, as in `jjBridge/include/JJBridge.h`; `void` calls return nothing. */
const SIGNATURES: Record<string, { args: ("str" | "str?" | "u32" | "i32" | "u64")[]; void?: true }> = {
  twj_set_lfs_limit: { args: ["u64"], void: true },
  twj_set_utc_offset: { args: ["i32"], void: true },
  twj_commit: { args: ["str"] },
  twj_squash: { args: ["str"] },
  twj_file_history: { args: ["str", "u32"] },
  twj_file_at: { args: ["str", "str"] },
  twj_restore_file: { args: ["str", "str"] },
  twj_delete: { args: ["str", "str"] },
  twj_deleted: { args: ["str", "u32"] },
  twj_restore_deleted: { args: ["str", "str"] },
  twj_conflicts: { args: ["str"] },
  twj_conflict: { args: ["str"] },
  twj_resolve: { args: ["str", "str?", "i32"] },
  twj_export_node: { args: ["str", "str"] },
  twj_node: { args: ["str", "str"] },
  twj_missing_objects: { args: ["str"] },
  twj_write_objects: { args: ["str", "str"] },
  twj_import_node: { args: ["str", "str", "str", "str"] },
  twj_merge_node: { args: ["str", "str", "str", "str"] },
  twj_merge_node_keeping: { args: ["str", "str", "str", "str", "str?"] },
};

/** Where node objects and LFS files pass between the module and sync, inside `.jj` so no snapshot sees them. */
const TRANSPORT = [".jj", "typewright", "transport"];

type Exports = {
  memory: WebAssembly.Memory;
  twj_alloc(len: number): number;
  twj_dealloc(ptr: number, len: number): void;
  twj_string_free(ptr: number): void;
};

let fs: OpfsFS | undefined;
let wasi: Wasi | undefined;
let exports: Exports | undefined;
let repo = 0;
let host: FileSystemDirectoryHandle | undefined;
let journal: FileSystemSyncAccessHandle | undefined;
let journalSize = 0;

async function readJSON<T>(name: string): Promise<T | null> {
  try {
    return JSON.parse(await (await (await host!.getFileHandle(name)).getFile()).text()) as T;
  } catch {
    return null;
  }
}

/** Flushes the replacement before clearing the recovery journal. */
async function writeAtomically(name: string, text: string) {
  const temp = await host!.getFileHandle(`${name}.tmp`, { create: true });
  const access = await unlocked(() => temp.createSyncAccessHandle());
  try {
    const bytes = new TextEncoder().encode(text);
    access.truncate(0);
    access.write(bytes, { at: 0 });
    access.flush();
  } finally {
    access.close();
  }
  await moveFile(temp, host!, host!, name);
}

function appendJournal(path: string) {
  const bytes = new TextEncoder().encode(`${path}\n`);
  journalSize += journal!.write(bytes, { at: journalSize });
  journal!.flush();
}

/** Saves the host's mtimes after a call; the journal then only needs files still open for writing. */
async function saveState() {
  const state = fs!.state();
  if (state) await writeAtomically("state.json", JSON.stringify(state));
  if (journalSize > 0 && (state || fs!.open.size === 0)) {
    journal!.truncate(0);
    journalSize = 0;
    for (const path of fs!.open.keys()) appendJournal(path);
  }
}

async function open(lfsLimit: number, staleFromTabs: string[]) {
  const storage = await navigator.storage.getDirectory();
  const root = await storage.getDirectoryHandle(ROOT, { create: true });
  host = await storage.getDirectoryHandle(HOST, { create: true });
  const state = await readJSON<HostState>("state.json");
  const journalHandle = await host.getFileHandle("journal", { create: true });
  const pending = (await (await journalHandle.getFile()).text()).split("\n").filter(Boolean);
  journal = await unlocked(() => journalHandle.createSyncAccessHandle());
  journalSize = journal.getSize();
  fs = new OpfsFS(root, {
    tracked: (path) => path !== ".jj" && !path.startsWith(".jj/"),
    state: state ?? undefined,
    // Without saved mtimes every file counts as changed once.
    stale: state ? [...pending, ...staleFromTabs] : [""],
  });
  fs.onWillWrite = appendJournal;
  const jspi = hasJSPI();
  wasi = new Wasi(fs, { args: ["jj_bridge"], preopens: { [GUEST_ROOT]: "" } }, jspi ? "jspi" : "asyncify");
  const { instance } = await WebAssembly.instantiateStreaming(fetch(jspi ? jspiUrl : asyncifyUrl), { wasi_snapshot_preview1: wasi.imports });
  wasi.attach(instance);
  exports = instance.exports as unknown as Exports;
  const [ptr, len] = string(GUEST_ROOT);
  repo = await wasi.call("twj_open", ptr);
  exports.twj_dealloc(ptr, len);
  if (!repo) throw new Error("Can't open the repository");
  await wasi.call("twj_set_lfs_limit", repo, BigInt(lfsLimit));
  return jspi ? "jspi" : "asyncify";
}

/** A NUL-terminated copy of `text` in the module's memory: [pointer, allocated length]. */
function string(text: string): [number, number] {
  const bytes = new TextEncoder().encode(text);
  const ptr = exports!.twj_alloc(bytes.length + 1);
  const memory = new Uint8Array(exports!.memory.buffer);
  memory.set(bytes, ptr);
  memory[ptr + bytes.length] = 0;
  return [ptr, bytes.length + 1];
}

function readString(ptr: number): string {
  const memory = new Uint8Array(exports!.memory.buffer);
  let end = ptr;
  while (memory[end]) end++;
  return new TextDecoder().decode(memory.subarray(ptr, end));
}

async function call(fn: string, args: Arg[]): Promise<unknown> {
  const signature = SIGNATURES[fn];
  if (!exports || !repo || !wasi) throw new Error("The repository isn't open");
  if (!signature) throw new Error(`Unknown call ${fn}`);
  const allocated: [number, number][] = [];
  try {
    const raw = signature.args.map((kind, i) => {
      const value = args[i];
      if (kind === "u64") return BigInt(Number(value ?? 0));
      if (kind === "u32" || kind === "i32") return Number(value ?? 0);
      if (value === null || value === undefined) {
        if (kind === "str?") return 0;
        throw new Error(`${fn}: argument ${i} is missing`);
      }
      const s = string(String(value));
      allocated.push(s);
      return s[0];
    });
    // WASI has no time zone; commits carry the browser's offset so history and retention use local days.
    await wasi.call("twj_set_utc_offset", repo, -new Date().getTimezoneOffset());
    const result = await wasi.call(fn, repo, ...raw);
    if (signature.void) return null;
    const text = readString(result);
    exports.twj_string_free(result);
    const value = JSON.parse(text);
    // A taken destination is an answer, not a failure.
    if (value && typeof value === "object" && "error" in value && typeof value.error === "string" && !value.exists) {
      throw Object.assign(new Error(value.error), { busy: value.busy === true });
    }
    return value;
  } finally {
    for (const [ptr, len] of allocated) exports.twj_dealloc(ptr, len);
  }
}

/** A fresh transport folder: [parts relative to the root, path the module sees]. */
async function transportDir(): Promise<[string[], string]> {
  const parts = [...TRANSPORT, crypto.randomUUID()];
  await fs!.dir(parts, true);
  return [parts, [GUEST_ROOT, ...parts].join("/")];
}

/** Writes files the module reads, past the host's caches (they're then forgotten for the folder). */
async function writeFiles(parts: string[], files: [string, Uint8Array][]) {
  const dir = await fs!.dir(parts, true);
  for (const [name, bytes] of files) {
    const access = await unlocked(async () => (await dir.getFileHandle(name, { create: true })).createSyncAccessHandle());
    try {
      access.truncate(0);
      access.write(bytes, { at: 0 });
      access.flush();
    } finally {
      access.close();
    }
  }
  fs!.invalidate([parts.join("/")]);
}

/** Reads what the module wrote into a folder. */
async function readFiles(parts: string[]): Promise<[string, Uint8Array][]> {
  const dir = await fs!.dir(parts);
  const out: [string, Uint8Array][] = [];
  for await (const [name, handle] of (dir as unknown as { entries(): AsyncIterable<[string, FileSystemHandle]> }).entries()) {
    if (handle.kind === "file") out.push([name, new Uint8Array(await (await (handle as FileSystemFileHandle).getFile()).arrayBuffer())]);
  }
  return out;
}

async function removeDir(parts: string[]) {
  const parent = await fs!.dir(parts.slice(0, -1));
  await parent.removeEntry(parts[parts.length - 1], { recursive: true }).catch(() => {});
  fs!.invalidate([parts.join("/")]);
}

/** The git objects of a node (its commit and whole tree), for its bundle. */
async function nodeObjects(node: string): Promise<[string, Uint8Array][]> {
  const [parts, guest] = await transportDir();
  try {
    await call("twj_write_objects", [JSON.stringify([node]), guest]);
    return await readFiles(parts);
  } finally {
    await removeDir(parts);
  }
}

/** Imports another device's node from its bundle's parts and merges it into the share at `path`. */
async function mergeNode(request: Extract<Request, { op: "mergeNode" }>): Promise<unknown> {
  const [parts, guest] = await transportDir();
  try {
    await writeFiles([...parts, "objects"], request.objects);
    await writeFiles([...parts, "lfs"], request.lfs);
    const imported = (await call("twj_import_node", [request.share, request.manifest, `${guest}/objects`, request.label])) as { node: string };
    return await call("twj_merge_node_keeping", [request.share, request.path, imported.node, `${guest}/lfs`, JSON.stringify(request.keep)]);
  } finally {
    await removeDir(parts);
  }
}

// One request at a time: the module isn't reentrant, and suspended calls must not interleave.
let queue: Promise<void> = Promise.resolve();

self.onmessage = (event: MessageEvent<Request>) => {
  const request = event.data;
  queue = queue.then(async () => {
    let response: Response;
    try {
      let value: unknown = null;
      let mode: "jspi" | "asyncify" | undefined;
      if (request.op === "open") mode = await open(request.lfsLimit, request.stale);
      else if (request.op === "invalidate") fs?.invalidate(request.paths);
      else if (request.op === "nodeObjects") value = await nodeObjects(request.node);
      else if (request.op === "mergeNode") value = await mergeNode(request);
      else value = await call(request.fn, request.args);
      await saveState();
      response = { id: request.id, ok: true, value, written: fs?.takeWritten() ?? [], mode };
    } catch (err) {
      // A trap leaves the module's memory unusable; the client starts a new worker.
      const fatal = err instanceof WebAssembly.RuntimeError;
      await saveState().catch(() => {});
      const busy = (err as { busy?: boolean }).busy === true;
      response = { id: request.id, ok: false, error: err instanceof Error ? err.message : String(err), fatal, busy };
    }
    self.postMessage(response);
  });
};
