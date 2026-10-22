// Hosts the internal jj repository (`jjBridge` built for wasm32-wasip1) off the main thread. The repository's
// working copy is origin storage's `spaces/` folder (each space a top-level folder, `.jj` beside them); the worker
// holds it in memory for the module and writes back what the module touched after every call.
import wasmUrl from "~/wasm/jj/jj_bridge.wasm?url";
import { contents, MemFS, memDir, memFile, type MemDir, splitPath, Wasi } from "~/lib/wasi";

export type Arg = string | number | null;
export type Request =
  | { id: number; op: "open"; lfsLimit: number }
  | { id: number; op: "call"; fn: string; args: Arg[] }
  | { id: number; op: "reload"; paths: string[] };
export type Response = { id: number; ok: true; value: unknown; written: string[] } | { id: number; ok: false; error: string; fatal?: boolean };

export const ROOT = "spaces";
const GUEST_ROOT = "/repo";

/** Argument kinds after the repo handle, as in `jjBridge/include/JJBridge.h`; `void` calls return nothing. */
const SIGNATURES: Record<string, { args: ("str" | "str?" | "u32" | "i32" | "u64")[]; void?: true }> = {
  twj_set_lfs_limit: { args: ["u64"], void: true },
  twj_commit: { args: ["str"] },
  twj_squash: { args: ["u32"] },
  twj_file_history: { args: ["str", "u32"] },
  twj_file_at: { args: ["str", "str"] },
  twj_restore_file: { args: ["str", "str"] },
  twj_conflicts: { args: ["str"] },
  twj_conflict: { args: ["str"] },
  twj_resolve: { args: ["str", "str?", "i32"] },
  twj_export_node: { args: ["str", "str"] },
  twj_node: { args: ["str", "str"] },
  twj_missing_objects: { args: ["str"] },
  twj_write_objects: { args: ["str", "str"] },
  twj_import_node: { args: ["str", "str", "str", "str"] },
  twj_merge_node: { args: ["str", "str", "str", "str"] },
};

type Exports = {
  memory: WebAssembly.Memory;
  twj_alloc(len: number): number;
  twj_dealloc(ptr: number, len: number): void;
  twj_open(root: number): number;
  twj_string_free(ptr: number): void;
} & Record<string, (...args: any[]) => any>;

const fs = new MemFS();
let wasi: Wasi | undefined;
let exports: Exports | undefined;
let repo = 0;

async function directory(path: string[], create: boolean): Promise<FileSystemDirectoryHandle | null> {
  let dir = await navigator.storage.getDirectory();
  for (const part of path) {
    try {
      dir = await dir.getDirectoryHandle(part, { create });
    } catch {
      return null;
    }
  }
  return dir;
}

async function readDir(handle: FileSystemDirectoryHandle): Promise<MemDir> {
  const dir = memDir();
  for await (const [name, child] of handle.entries()) {
    if (child.kind === "directory") dir.entries.set(name, await readDir(child as FileSystemDirectoryHandle));
    else {
      const file = await (child as FileSystemFileHandle).getFile();
      dir.entries.set(name, memFile(new Uint8Array(await file.arrayBuffer()), BigInt(file.lastModified) * 1_000_000n));
    }
  }
  return dir;
}

/** Takes `paths` (relative to `spaces/`) as they are in origin storage now, after the app wrote them. */
async function reload(paths: string[]) {
  for (const path of paths) {
    const parts = splitPath(path);
    if (parts[0] === ".jj" || parts.length === 0) continue;
    const parent = await directory([ROOT, ...parts.slice(0, -1)], false);
    const name = parts[parts.length - 1];
    const file = await parent?.getFileHandle(name).then((h) => h.getFile()).catch(() => null);
    if (file) {
      // A fresh mtime, so jj rehashes even if origin storage reports an old date.
      fs.put(path, memFile(new Uint8Array(await file.arrayBuffer())));
      continue;
    }
    const dir = await parent?.getDirectoryHandle(name).catch(() => null);
    if (dir) fs.put(path, await readDir(dir));
    else fs.delete(path);
  }
}

async function writeFile(dir: FileSystemDirectoryHandle, name: string, bytes: Uint8Array) {
  await dir.removeEntry(name, { recursive: true }).catch(() => {});
  const handle = await dir.getFileHandle(name, { create: true });
  // Sync access handles are the one writer every browser offers in workers.
  if (typeof handle.createSyncAccessHandle === "function") {
    const access = await handle.createSyncAccessHandle();
    try {
      access.truncate(0);
      access.write(bytes as Uint8Array<ArrayBuffer>, { at: 0 });
      access.flush();
    } finally {
      access.close();
    }
  } else {
    const writable = await (handle as FileSystemFileHandle).createWritable();
    await writable.write(bytes as Uint8Array<ArrayBuffer>);
    await writable.close();
  }
}

async function writeTree(dir: FileSystemDirectoryHandle, node: MemDir, skip: Set<string>, prefix: string) {
  for (const [name, child] of node.entries) {
    const path = prefix ? `${prefix}/${name}` : name;
    if (skip.has(path)) continue;
    if (child.kind === "dir") {
      const sub = await dir.getDirectoryHandle(name, { create: true }).catch(async () => {
        await dir.removeEntry(name);
        return dir.getDirectoryHandle(name, { create: true });
      });
      await writeTree(sub, child, skip, path);
    } else await writeFile(dir, name, contents(child));
  }
}

/** Writes what the module touched back to origin storage; operation heads and working-copy state go last, so a
 * tab closed halfway leaves the previous operation current. */
async function persist(): Promise<string[]> {
  const dirty = fs.takeDirty();
  const late = (p: string) => p.startsWith(".jj/repo/op_heads") || p.startsWith(".jj/working_copy");
  dirty.sort((a, b) => Number(late(a)) - Number(late(b)) || a.length - b.length);
  const set = new Set(dirty);
  for (const path of dirty) {
    const parts = splitPath(path);
    const name = parts[parts.length - 1];
    if (!name) continue;
    const node = fs.lookup(parts);
    const parent = await directory([ROOT, ...parts.slice(0, -1)], node !== null);
    if (!parent) continue;
    if (!node) await parent.removeEntry(name, { recursive: true }).catch(() => {});
    else if (node.kind === "file") await writeFile(parent, name, contents(node));
    else {
      const handle = await parent.getDirectoryHandle(name, { create: true }).catch(async () => {
        await parent.removeEntry(name);
        return parent.getDirectoryHandle(name, { create: true });
      });
      // Children dirty on their own are written in their turn; the rest arrived by a rename.
      const skip = new Set([...set].filter((p) => p.startsWith(`${path}/`)).map((p) => p.slice(path.length + 1)));
      await writeTree(handle, node, skip, "");
    }
  }
  return dirty.filter((p) => !p.startsWith(".jj/") && p !== ".jj");
}

async function open(lfsLimit: number) {
  const handle = await directory([ROOT], true);
  fs.root = await readDir(handle!);
  wasi = new Wasi(fs, { args: ["jj_bridge"], preopens: { [GUEST_ROOT]: "" } });
  const { instance } = await WebAssembly.instantiateStreaming(fetch(wasmUrl), { wasi_snapshot_preview1: wasi.imports });
  wasi.initialize(instance);
  exports = instance.exports as Exports;
  repo = withString(GUEST_ROOT, (ptr) => exports!.twj_open(ptr));
  if (!repo) throw new Error("Can't open the repository");
  exports.twj_set_lfs_limit(repo, BigInt(lfsLimit));
}

function withString<T>(text: string, body: (ptr: number) => T): T {
  const bytes = new TextEncoder().encode(text);
  const ptr = exports!.twj_alloc(bytes.length + 1);
  const memory = new Uint8Array(exports!.memory.buffer);
  memory.set(bytes, ptr);
  memory[ptr + bytes.length] = 0;
  try {
    return body(ptr);
  } finally {
    exports!.twj_dealloc(ptr, bytes.length + 1);
  }
}

function readString(ptr: number): string {
  const memory = new Uint8Array(exports!.memory.buffer);
  let end = ptr;
  while (memory[end]) end++;
  return new TextDecoder().decode(memory.subarray(ptr, end));
}

function call(fn: string, args: Arg[]): unknown {
  const signature = SIGNATURES[fn];
  if (!exports || !repo) throw new Error("The repository isn't open");
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
      const bytes = new TextEncoder().encode(String(value));
      const ptr = exports!.twj_alloc(bytes.length + 1);
      const memory = new Uint8Array(exports!.memory.buffer);
      memory.set(bytes, ptr);
      memory[ptr + bytes.length] = 0;
      allocated.push([ptr, bytes.length + 1]);
      return ptr;
    });
    const result = exports[fn](repo, ...raw);
    if (signature.void) return null;
    const text = readString(result);
    exports.twj_string_free(result);
    const value = JSON.parse(text);
    if (value && typeof value === "object" && "error" in value && typeof value.error === "string") throw new Error(value.error);
    return value;
  } finally {
    for (const [ptr, len] of allocated) exports.twj_dealloc(ptr, len);
  }
}

// One request at a time: the module isn't reentrant, and a reload must not land between a call and its persist.
let queue: Promise<void> = Promise.resolve();

self.onmessage = (event: MessageEvent<Request>) => {
  const request = event.data;
  queue = queue.then(async () => {
    let response: Response;
    try {
      let value: unknown = null;
      if (request.op === "open") await open(request.lfsLimit);
      else if (request.op === "reload") await reload(request.paths);
      else value = call(request.fn, request.args);
      response = { id: request.id, ok: true, value, written: await persist() };
    } catch (err) {
      // A trap leaves the module's memory unusable; the client starts a new worker.
      const fatal = err instanceof WebAssembly.RuntimeError;
      await persist().catch(() => {});
      response = { id: request.id, ok: false, error: err instanceof Error ? err.message : String(err), fatal };
    }
    self.postMessage(response);
  });
};
