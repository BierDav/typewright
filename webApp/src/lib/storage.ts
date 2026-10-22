// The origin private file system: spaces are folders under `spaces/`, everything else lives beside them.
// It has no change events, so every write goes through here and is announced, also to other tabs.

export type Entry = { path: string; kind: "file" | "dir"; size: number; modified: number };

export type Change = { paths: string[] };

const channel = typeof BroadcastChannel === "undefined" ? undefined : new BroadcastChannel("typewright-fs");
const listeners = new Set<(change: Change) => void>();

/** Calls `listener` with the absolute paths written, moved or removed, here or in another tab. */
export function onChange(listener: (change: Change) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Announces paths written behind this module's back, like the jj repository's working-copy writes. */
export function notify(paths: string[]) {
  announce(paths);
}

function announce(paths: string[]) {
  const change = { paths };
  listeners.forEach((l) => l(change));
  channel?.postMessage(change);
}

channel?.addEventListener("message", (event) => listeners.forEach((l) => l(event.data as Change)));

let rootPromise: Promise<FileSystemDirectoryHandle> | undefined;

export function root(): Promise<FileSystemDirectoryHandle> {
  rootPromise ??= navigator.storage.getDirectory();
  return rootPromise;
}

export function split(path: string): string[] {
  return path.split("/").filter((p) => p && p !== ".");
}

export function join(...parts: string[]): string {
  return parts.flatMap(split).join("/");
}

export function dirname(path: string): string {
  const parts = split(path);
  parts.pop();
  return parts.join("/");
}

export function basename(path: string): string {
  return split(path).pop() ?? "";
}

export function extension(path: string): string {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : "";
}

async function directory(path: string, create = false): Promise<FileSystemDirectoryHandle | null> {
  let dir = await root();
  for (const part of split(path)) {
    try {
      dir = await dir.getDirectoryHandle(part, { create });
    } catch {
      return null;
    }
  }
  return dir;
}

async function fileHandle(path: string, create = false): Promise<FileSystemFileHandle | null> {
  const parent = await directory(dirname(path), create);
  if (!parent) return null;
  try {
    return await parent.getFileHandle(basename(path), { create });
  } catch {
    return null;
  }
}

export async function exists(path: string): Promise<boolean> {
  return (await stat(path)) !== null;
}

export async function stat(path: string): Promise<Entry | null> {
  if (split(path).length === 0) return { path: "", kind: "dir", size: 0, modified: 0 };
  const parent = await directory(dirname(path));
  if (!parent) return null;
  const name = basename(path);
  try {
    const file = await (await parent.getFileHandle(name)).getFile();
    return { path, kind: "file", size: file.size, modified: file.lastModified };
  } catch {}
  try {
    await parent.getDirectoryHandle(name);
    return { path, kind: "dir", size: 0, modified: 0 };
  } catch {
    return null;
  }
}

export async function readFile(path: string): Promise<Uint8Array | null> {
  const handle = await fileHandle(path);
  if (!handle) return null;
  try {
    return new Uint8Array(await (await handle.getFile()).arrayBuffer());
  } catch {
    return null;
  }
}

export async function readBlob(path: string): Promise<File | null> {
  const handle = await fileHandle(path);
  return handle ? handle.getFile().catch(() => null) : null;
}

export async function readText(path: string): Promise<string | null> {
  const bytes = await readFile(path);
  return bytes ? new TextDecoder().decode(bytes) : null;
}

/** Retries while the jj worker holds the file's lock (a sync access handle, open only during a call). */
async function unlocked<T>(body: () => Promise<T>): Promise<T> {
  const deadline = Date.now() + 10_000;
  for (let wait = 5; ; wait = Math.min(wait * 2, 200)) {
    try {
      return await body();
    } catch (err) {
      const name = (err as DOMException)?.name;
      // WebKit reports the lock as InvalidStateError.
      if ((name !== "NoModificationAllowedError" && name !== "InvalidStateError") || Date.now() > deadline) throw err;
      await new Promise((r) => setTimeout(r, wait));
    }
  }
}

async function write(handle: FileSystemFileHandle, data: Uint8Array | string) {
  const writable = await unlocked(() => handle.createWritable());
  await writable.write(typeof data === "string" ? data : (data as Uint8Array<ArrayBuffer>));
  await writable.close();
}

/** Writes a file, creating its folders; `quiet` skips the change announcement, for internal state. */
export async function writeFile(path: string, data: Uint8Array | string, quiet = false): Promise<void> {
  const handle = await fileHandle(path, true);
  if (!handle) throw new Error(`Can't write ${path}`);
  await write(handle, data);
  if (!quiet) announce([path]);
}

export async function makeDirectory(path: string): Promise<void> {
  if (!(await directory(path, true))) throw new Error(`Can't create ${path}`);
  announce([path]);
}

export async function remove(path: string, quiet = false): Promise<void> {
  const parent = await directory(dirname(path));
  if (!parent) return;
  try {
    await unlocked(() => parent.removeEntry(basename(path), { recursive: true }));
  } catch {}
  if (!quiet) announce([path]);
}

/** Every file and folder below `path`, depth first, with paths relative to it. */
export async function walk(path: string): Promise<Entry[]> {
  const dir = await directory(path);
  if (!dir) return [];
  const out: Entry[] = [];
  async function visit(handle: FileSystemDirectoryHandle, prefix: string) {
    for await (const [name, child] of handle.entries()) {
      const rel = prefix ? `${prefix}/${name}` : name;
      if (child.kind === "directory") {
        out.push({ path: rel, kind: "dir", size: 0, modified: 0 });
        await visit(child as FileSystemDirectoryHandle, rel);
      } else {
        const file = await (child as FileSystemFileHandle).getFile();
        out.push({ path: rel, kind: "file", size: file.size, modified: file.lastModified });
      }
    }
  }
  await visit(dir, "");
  return out;
}

/** The names directly inside `path`. */
export async function list(path: string): Promise<Entry[]> {
  const dir = await directory(path);
  if (!dir) return [];
  const out: Entry[] = [];
  for await (const [name, child] of dir.entries()) {
    out.push({ path: join(path, name), kind: child.kind === "directory" ? "dir" : "file", size: 0, modified: 0 });
  }
  return out;
}

/** The items directly inside `path`, files with their contents' handle for size, date and bytes. */
export async function children(path: string): Promise<{ name: string; dir: boolean; file?: File }[]> {
  const dir = await directory(path);
  if (!dir) return [];
  const out: { name: string; dir: boolean; file?: File }[] = [];
  for await (const [name, child] of dir.entries()) {
    if (child.kind === "directory") out.push({ name, dir: true });
    else {
      const file = await (child as FileSystemFileHandle).getFile().catch(() => undefined);
      if (file) out.push({ name, dir: false, file });
    }
  }
  return out;
}

/** Copies a file or folder; the target must not exist yet. */
export async function copy(from: string, to: string, quiet = false): Promise<void> {
  const info = await stat(from);
  if (!info) throw new Error(`${from} doesn't exist`);
  if (info.kind === "file") {
    const handle = await fileHandle(to, true);
    const source = await fileHandle(from);
    if (!handle || !source) throw new Error(`Can't copy ${from}`);
    const writable = await unlocked(() => handle.createWritable());
    await (await source.getFile()).stream().pipeTo(writable);
  } else {
    await directory(to, true);
    for (const entry of await walk(from)) {
      if (entry.kind === "dir") await directory(join(to, entry.path), true);
      else await copy(join(from, entry.path), join(to, entry.path), true);
    }
  }
  if (!quiet) announce([to]);
}

/** Moves or renames a file or folder. */
export async function move(from: string, to: string): Promise<void> {
  if (from === to) return;
  const handle = (await fileHandle(from)) ?? (await directory(from));
  const target = await directory(dirname(to), true);
  // Chromium and WebKit move in place; elsewhere it's a copy.
  const movable = handle as (FileSystemHandle & { move?: (dir: FileSystemDirectoryHandle, name: string) => Promise<void> }) | null;
  if (movable?.move && target) {
    try {
      await unlocked(() => movable.move!(target, basename(to)));
      announce([from, to]);
      return;
    } catch {}
  }
  await copy(from, to, true);
  await remove(from, true);
  announce([from, to]);
}

/** Bytes as text if they decode as UTF-8 without NUL bytes, like a binary sniff. */
export function decodeText(bytes: Uint8Array): string | null {
  if (bytes.subarray(0, 8000).includes(0)) return null;
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
}

/** Asks the browser not to evict origin storage under pressure. */
export async function persist(): Promise<boolean> {
  try {
    return (await navigator.storage.persisted()) || (await navigator.storage.persist());
  } catch {
    return false;
  }
}
