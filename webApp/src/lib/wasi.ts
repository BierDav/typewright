// A WASI preview 1 host for one module whose files live in the origin private file system (OPFS), enough for jj-lib
// (`jjBridge` built for wasm32-wasip1). File calls are async (OPFS is), so the module runs through JSPI
// (`WebAssembly.Suspending`/`promising`) or, without it, an Asyncify build of the module (`AsyncifyDriver`).
// Memory holds only bounded caches: folder handles, file metadata and a byte-capped LRU of small file contents.
//
// OPFS can't set mtimes and doesn't even move `lastModified` on same-size writes, but jj skips files whose size and
// mtime didn't change. So mtimes of working-copy files are our own (strictly increasing, see `now`), persisted with
// `mtimes()`; files written from outside, or by a module killed before the mtimes were saved, are marked `stale`
// and get a fresh mtime on their next stat.

const E = {
  SUCCESS: 0, ACCES: 2, BADF: 8, BUSY: 10, EXIST: 20, INVAL: 28, IO: 29, ISDIR: 31, NOENT: 44, NOSPC: 51, NOSYS: 52,
  NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58, NOTCAPABLE: 76, SPIPE: 70,
} as const;
const FILETYPE = { CHAR: 2, DIR: 3, FILE: 4 } as const;
const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 } as const;
const FDFLAGS_APPEND = 1;
const RIGHTS_WRITE = (1n << 6n) | (1n << 8n) | (1n << 22n); // fd_write, fd_allocate, fd_filestat_set_size
const FST = { MTIM: 4, MTIM_NOW: 8 } as const;

let lastNow = 0n;

/** Nanoseconds since the epoch, strictly increasing, so two writes never share an mtime. */
export function now(): bigint {
  const t = BigInt(Date.now()) * 1_000_000n;
  lastNow = t > lastNow ? t : lastNow + 1n;
  return lastNow;
}

export function splitPath(path: string): string[] {
  return path.split("/").filter((p) => p && p !== ".");
}

class Errno extends Error {
  constructor(readonly errno: number) {
    super(`errno ${errno}`);
  }
}

function errno(err: unknown): number {
  if (err instanceof Errno) return err.errno;
  const name = (err as DOMException)?.name;
  if (name === "NotFoundError") return E.NOENT;
  if (name === "TypeMismatchError") return E.NOTDIR;
  if (name === "InvalidModificationError") return E.NOTEMPTY;
  if (isLocked(err)) return E.BUSY;
  if (name === "QuotaExceededError") return E.NOSPC;
  console.error("wasi:", err);
  return E.IO;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Whether OPFS refused because a sync access handle holds the file (WebKit says InvalidStateError). */
export function isLocked(err: unknown): boolean {
  const name = (err as DOMException)?.name;
  return name === "NoModificationAllowedError" || name === "InvalidStateError";
}

/** Retries while another context (the editor, another tab) holds the file's lock; locks are held briefly. */
export async function unlocked<T>(body: () => Promise<T>, timeout = 10_000): Promise<T> {
  const deadline = Date.now() + timeout;
  for (let wait = 2; ; wait = Math.min(wait * 2, 100)) {
    try {
      return await body();
    } catch (err) {
      if (!isLocked(err) || Date.now() > deadline) throw err;
      await sleep(wait);
    }
  }
}

/** A Map that forgets its least recently used entries beyond `cap` (by count or by `weigh`). */
class LRU<V> {
  private map = new Map<string, V>();
  private total = 0;
  constructor(private cap: number, private weigh: (v: V) => number = () => 1) {}

  get(key: string): V | undefined {
    const v = this.map.get(key);
    if (v !== undefined) {
      this.map.delete(key);
      this.map.set(key, v);
    }
    return v;
  }

  set(key: string, value: V) {
    this.delete(key);
    this.map.set(key, value);
    this.total += this.weigh(value);
    for (const [k, v] of this.map) {
      if (this.total <= this.cap) break;
      this.map.delete(k);
      this.total -= this.weigh(v);
    }
  }

  delete(key: string) {
    const v = this.map.get(key);
    if (v === undefined) return;
    this.map.delete(key);
    this.total -= this.weigh(v);
  }

  /** Drops `prefix` and everything below it. */
  deleteTree(prefix: string) {
    for (const key of [...this.map.keys()]) if (key === prefix || key.startsWith(`${prefix}/`)) this.delete(key);
  }

  get size() {
    return this.total;
  }
}

type Meta = { kind: "file"; size: number; mtime: bigint; ino: bigint } | { kind: "dir"; ino: bigint } | { kind: "none" };
/** A persisted mtime: nanoseconds, the size it belongs to, and when it was recorded (all as strings or numbers). */
export type MtimeRecord = [mtime: string, size: number, recorded: string];
/** What `OpfsFS.state()` saves: mtimes, and paths (or folders) changed behind the host's back since a time. */
export type HostState = { records: Record<string, MtimeRecord>; marks: Record<string, string> };

type SyncHandle = FileSystemSyncAccessHandle;
/** A file the module holds open for writing; `path` follows renames. */
type Open = { path: string; access: SyncHandle | null; refs: number; written: boolean; orphan: boolean };

export type OpfsOptions = {
  /** Bytes of file contents kept in memory. */
  cacheBytes?: number;
  /** Larger files are read in slices, never cached whole. */
  maxCachedFile?: number;
  /** Whether a path is part of the working copy, whose mtimes persist (the rest report OPFS's `lastModified`). */
  tracked?: (path: string) => boolean;
  state?: HostState;
  /** Paths changed since `state` was saved ("" for all). */
  stale?: string[];
};

let nextIno = 1n;

export class OpfsFS {
  private dirs = new Map<string, FileSystemDirectoryHandle>();
  private files = new LRU<FileSystemFileHandle>(4096);
  private meta = new LRU<Meta>(50_000);
  private content: LRU<Uint8Array>;
  private maxCachedFile: number;
  private tracked: (path: string) => boolean;
  private records: Map<string, MtimeRecord>;
  /** Path → when it was found changed; records of it (or below it) from before don't count. */
  private marks: Map<string, bigint>;
  private recordsDirty = false;
  private inos = new LRU<bigint>(50_000);
  readonly open = new Map<string, Open>();
  /** Tracked paths written since the last `takeWritten`. */
  private written = new Set<string>();
  /** Called before a tracked file is first written, so a crash can't leave it with its old mtime. */
  onWillWrite: (path: string) => void = () => {};

  constructor(root: FileSystemDirectoryHandle, options: OpfsOptions = {}) {
    this.dirs.set("", root);
    this.content = new LRU(options.cacheBytes ?? 32 << 20, (v) => v.byteLength);
    this.maxCachedFile = options.maxCachedFile ?? 1 << 20;
    this.tracked = options.tracked ?? (() => true);
    this.records = new Map(Object.entries(options.state?.records ?? {}));
    this.marks = new Map(Object.entries(options.state?.marks ?? {}).map(([k, v]) => [k, BigInt(v)]));
    const t = now();
    for (const path of options.stale ?? []) this.marks.set(splitPath(path).join("/"), t);
    if (options.stale?.length) this.recordsDirty = true;
  }

  get cachedBytes() {
    return this.content.size;
  }

  private ino(path: string): bigint {
    let ino = this.inos.get(path);
    if (ino === undefined) this.inos.set(path, (ino = nextIno++));
    return ino;
  }

  /** Forgets what's known about `paths`: something else wrote them. */
  invalidate(paths: string[]) {
    for (const path of paths) {
      const parts = splitPath(path);
      for (let i = 1; i <= parts.length; i++) this.meta.delete(parts.slice(0, i).join("/"));
      this.meta.deleteTree(path);
      this.content.deleteTree(path);
      this.files.deleteTree(path);
      for (const key of [...this.dirs.keys()]) if (key === path || key.startsWith(`${path}/`)) this.dirs.delete(key);
      this.marks.set(parts.join("/"), now());
      this.recordsDirty = true;
    }
  }

  /** Whether a record from `recorded` predates a change mark on `parts` or a folder above. */
  private outdated(parts: string[], recorded: bigint): boolean {
    if ((this.marks.get("") ?? -1n) >= recorded) return true;
    for (const p of parentsAndSelf(parts)) if ((this.marks.get(p) ?? -1n) >= recorded) return true;
    return false;
  }

  /** The state to persist, if it changed since the last call; marks every record has outgrown are dropped. */
  state(): HostState | null {
    if (!this.recordsDirty) return null;
    this.recordsDirty = false;
    for (const [mark, time] of this.marks) {
      let needed = false;
      for (const [path, record] of this.records) {
        if ((mark === "" || path === mark || path.startsWith(`${mark}/`)) && BigInt(record[2]) <= time) {
          needed = true;
          break;
        }
      }
      if (!needed) this.marks.delete(mark);
    }
    return {
      records: Object.fromEntries(this.records),
      marks: Object.fromEntries([...this.marks].map(([k, v]) => [k, v.toString()])),
    };
  }

  takeWritten(): string[] {
    const paths = [...this.written];
    this.written.clear();
    return paths;
  }

  async dir(parts: string[], create = false): Promise<FileSystemDirectoryHandle> {
    const key = parts.join("/");
    const cached = this.dirs.get(key);
    if (cached) return cached;
    const parent = await this.dir(parts.slice(0, -1), create);
    const handle = await parent.getDirectoryHandle(parts[parts.length - 1], { create });
    this.dirs.set(key, handle);
    return handle;
  }

  /** The file's handle (cached), created if `create`. */
  async fileHandle(parts: string[], create = false): Promise<FileSystemFileHandle> {
    const path = parts.join("/");
    const cached = this.files.get(path);
    if (cached) return cached;
    const handle = await (await this.dir(parts.slice(0, -1))).getFileHandle(parts[parts.length - 1], { create });
    this.files.set(path, handle);
    return handle;
  }

  private async parentOf(parts: string[], create = false): Promise<FileSystemDirectoryHandle | null> {
    try {
      return await this.dir(parts.slice(0, -1), create);
    } catch {
      return null;
    }
  }

  private setFileMeta(path: string, size: number, mtime: bigint) {
    this.meta.set(path, { kind: "file", size, mtime, ino: this.ino(path) });
    if (this.tracked(path)) {
      this.records.set(path, [mtime.toString(), size, now().toString()]);
      this.recordsDirty = true;
    }
  }

  private forget(path: string) {
    this.meta.set(path, { kind: "none" });
    this.files.delete(path);
    this.content.delete(path);
    if (this.records.delete(path)) this.recordsDirty = true;
  }

  /** What's known about `parts` without touching OPFS. */
  cachedStat(parts: string[]): Meta | undefined {
    const path = parts.join("/");
    if (parts.length === 0) return { kind: "dir", ino: 0n };
    const cached = this.meta.get(path);
    if (cached) return cached;
    const open = this.open.get(path);
    if (open?.access) return { kind: "file", size: open.access.getSize(), mtime: now(), ino: this.ino(path) };
    return undefined;
  }

  cachedContent(parts: string[]): Uint8Array | undefined {
    return this.content.get(parts.join("/"));
  }

  async stat(parts: string[]): Promise<Meta> {
    const known = this.cachedStat(parts);
    if (known) return known;
    const path = parts.join("/");
    const parent = await this.parentOf(parts);
    const name = parts[parts.length - 1];
    if (!parent) return { kind: "none" };
    let file: File | null = null;
    try {
      file = await (await this.fileHandle(parts)).getFile();
    } catch (err) {
      const kind = (err as DOMException)?.name;
      if (kind === "TypeMismatchError") {
        const meta: Meta = { kind: "dir", ino: this.ino(path) };
        this.meta.set(path, meta);
        return meta;
      }
      if (kind !== "NotFoundError") throw err;
    }
    if (!file) {
      this.meta.set(path, { kind: "none" });
      return { kind: "none" };
    }
    let mtime = BigInt(file.lastModified) * 1_000_000n;
    if (this.tracked(path)) {
      const record = this.records.get(path);
      const changed = this.outdated(parts, record ? BigInt(record[2]) : 0n);
      if (record && !changed && record[1] === file.size) mtime = BigInt(record[0]);
      else if (record || changed) mtime = now();
      this.setFileMeta(path, file.size, mtime);
    } else this.meta.set(path, { kind: "file", size: file.size, mtime, ino: this.ino(path) });
    return this.meta.get(path)!;
  }

  /** Bytes of a whole small file, or the File to slice for a large one. */
  async readable(parts: string[]): Promise<Uint8Array | File> {
    const path = parts.join("/");
    const cached = this.content.get(path);
    if (cached) return cached;
    const file = await (await this.fileHandle(parts)).getFile();
    if (file.size > this.maxCachedFile) return file;
    const bytes = new Uint8Array(await file.arrayBuffer());
    this.content.set(path, bytes);
    return bytes;
  }

  /** The sync access handle of an open writable file, (re)opened on demand: renames close it. */
  async access(open: Open): Promise<SyncHandle> {
    if (open.orphan) throw new Errno(E.BADF);
    if (open.access) return open.access;
    const handle = await this.fileHandle(splitPath(open.path), true);
    open.access = await unlocked(() => handle.createSyncAccessHandle());
    return open.access;
  }

  async acquire(path: string, create: boolean): Promise<Open> {
    let open = this.open.get(path);
    if (open) {
      open.refs++;
      return open;
    }
    const handle = await this.fileHandle(splitPath(path), create);
    open = { path, access: await unlocked(() => handle.createSyncAccessHandle()), refs: 1, written: false, orphan: false };
    this.open.set(path, open);
    this.meta.delete(path);
    return open;
  }

  markWritten(open: Open) {
    const path = open.path;
    if (!open.written && this.tracked(path)) this.onWillWrite(path);
    open.written = true;
    this.content.delete(path);
    this.meta.delete(path);
  }

  async release(open: Open) {
    const path = open.path;
    if (--open.refs > 0) return;
    let size: number | null = null;
    if (open.access) {
      size = open.access.getSize();
      // Closing flushes.
      open.access.close();
      open.access = null;
    }
    if (this.open.get(path) === open) this.open.delete(path);
    if (open.orphan || !open.written) return;
    // Detached by a rename: the size comes from the file.
    size ??= (await (await this.fileHandle(splitPath(path))).getFile()).size;
    this.setFileMeta(path, size, now());
    if (this.tracked(path)) this.written.add(path);
  }

  /** Closes the sync access handles of `path` and below, so OPFS lets it move or go. */
  private detach(path: string, orphan: boolean): Map<string, Open> {
    const detached = new Map<string, Open>();
    for (const [key, open] of this.open) {
      if (key !== path && !key.startsWith(`${path}/`)) continue;
      open.access?.close();
      open.access = null;
      open.orphan ||= orphan;
      detached.set(key, open);
      this.open.delete(key);
    }
    return detached;
  }

  async mkdir(parts: string[]) {
    if ((await this.stat(parts)).kind !== "none") throw new Errno(E.EXIST);
    const parent = await this.parentOf(parts);
    if (!parent) throw new Errno(E.NOENT);
    await parent.getDirectoryHandle(parts[parts.length - 1], { create: true });
    this.meta.set(parts.join("/"), { kind: "dir", ino: this.ino(parts.join("/")) });
  }

  async rmdir(parts: string[]) {
    const path = parts.join("/");
    const meta = await this.stat(parts);
    if (meta.kind === "none") throw new Errno(E.NOENT);
    if (meta.kind !== "dir") throw new Errno(E.NOTDIR);
    if (parts.length === 0) throw new Errno(E.ACCES);
    await (await this.dir(parts.slice(0, -1))).removeEntry(parts[parts.length - 1]);
    this.dirs.delete(path);
    this.forget(path);
  }

  async unlink(parts: string[]) {
    const path = parts.join("/");
    const meta = await this.stat(parts);
    if (meta.kind === "none") throw new Errno(E.NOENT);
    if (meta.kind === "dir") throw new Errno(E.ISDIR);
    this.detach(path, true);
    const parent = await this.dir(parts.slice(0, -1));
    await unlocked(() => parent.removeEntry(parts[parts.length - 1]));
    this.forget(path);
    if (this.tracked(path)) this.written.add(path);
  }

  async rename(fromParts: string[], toParts: string[]) {
    const from = fromParts.join("/");
    const to = toParts.join("/");
    const meta = await this.stat(fromParts);
    if (meta.kind === "none" || fromParts.length === 0) throw new Errno(E.NOENT);
    if (toParts.length === 0) throw new Errno(E.ACCES);
    if (from === to) return;
    const target = await this.stat(toParts);
    if (meta.kind === "dir") {
      if (toParts.length > fromParts.length && fromParts.every((p, i) => toParts[i] === p)) throw new Errno(E.INVAL);
      if (target.kind === "file") throw new Errno(E.NOTDIR);
      if (target.kind === "dir") await this.rmdir(toParts);
    } else if (target.kind === "dir") throw new Errno(E.ISDIR);
    const toParent = await this.parentOf(toParts);
    if (!toParent) throw new Errno(E.NOENT);
    const fromParent = await this.dir(fromParts.slice(0, -1));
    const name = fromParts[fromParts.length - 1];
    const newName = toParts[toParts.length - 1];
    this.detach(to, true);
    const moving = this.detach(from, false);
    if (meta.kind === "dir") {
      this.files.deleteTree(from);
      this.files.deleteTree(to);
    } else {
      this.files.delete(from);
      this.files.delete(to);
    }
    if (meta.kind === "file") {
      const handle = await fromParent.getFileHandle(name);
      // OPFS moves files atomically, replacing the target; jj's op heads and working-copy state rely on that.
      const movable = handle as FileSystemFileHandle & { move?: (dir: FileSystemDirectoryHandle, name: string) => Promise<void> };
      if (movable.move) await unlocked(() => movable.move!(toParent, newName));
      else {
        await copyFile(handle, toParent, newName);
        await fromParent.removeEntry(name);
      }
      const cached = this.content.get(from);
      this.forget(from);
      if (cached) this.content.set(to, cached);
      this.setFileMeta(to, meta.size, meta.mtime);
    } else {
      // Folders don't move in OPFS (Chromium 156 throws), so they're copied; only jj's own folders ever get here.
      await copyTree(await fromParent.getDirectoryHandle(name), await toParent.getDirectoryHandle(newName, { create: true }));
      await fromParent.removeEntry(name, { recursive: true });
      for (const lru of [this.meta, this.content]) {
        lru.deleteTree(from);
        lru.deleteTree(to);
      }
      for (const key of [...this.dirs.keys()]) if (key === from || key.startsWith(`${from}/`)) this.dirs.delete(key);
      for (const key of [...this.records.keys()]) {
        if (key.startsWith(`${from}/`)) {
          this.records.set(to + key.slice(from.length), this.records.get(key)!);
          this.records.delete(key);
          this.recordsDirty = true;
        }
      }
      this.meta.set(from, { kind: "none" });
    }
    for (const [key, open] of moving) {
      open.path = to + key.slice(from.length);
      this.open.set(open.path, open);
    }
    if (this.tracked(from)) this.written.add(from);
    if (this.tracked(to)) this.written.add(to);
  }

  /** A hard link, as a copy: OPFS has none. Only used to persist a temp file without replacing (then unlinked). */
  async link(fromParts: string[], toParts: string[]) {
    const meta = await this.stat(fromParts);
    if (meta.kind === "none") throw new Errno(E.NOENT);
    if (meta.kind === "dir") throw new Errno(E.NOTSUP);
    if ((await this.stat(toParts)).kind !== "none") throw new Errno(E.EXIST);
    const toParent = await this.parentOf(toParts);
    if (!toParent) throw new Errno(E.NOENT);
    const from = fromParts.join("/");
    this.detach(from, false).forEach((open, key) => this.open.set(key, open));
    await copyFile(await (await this.dir(fromParts.slice(0, -1))).getFileHandle(fromParts[fromParts.length - 1]), toParent, toParts[toParts.length - 1]);
    this.setFileMeta(toParts.join("/"), meta.size, meta.mtime);
    if (this.tracked(toParts.join("/"))) this.written.add(toParts.join("/"));
  }

  async setMtime(parts: string[], mtime: bigint) {
    const meta = await this.stat(parts);
    if (meta.kind === "none") throw new Errno(E.NOENT);
    if (meta.kind === "file") this.setFileMeta(parts.join("/"), meta.size, mtime);
  }

  async list(parts: string[]): Promise<[string, "file" | "dir"][]> {
    const dir = await this.dir(parts);
    const out: [string, "file" | "dir"][] = [];
    for await (const [name, handle] of dir.entries()) out.push([name, handle.kind === "directory" ? "dir" : "file"]);
    return out;
  }
}

function* parentsAndSelf(parts: string[]) {
  for (let i = 1; i <= parts.length; i++) yield parts.slice(0, i).join("/");
}

async function copyFile(handle: FileSystemFileHandle, to: FileSystemDirectoryHandle, name: string) {
  const bytes = new Uint8Array(await (await handle.getFile()).arrayBuffer());
  const target = await to.getFileHandle(name, { create: true });
  const access = await unlocked(() => target.createSyncAccessHandle());
  try {
    access.truncate(0);
    access.write(bytes, { at: 0 });
    access.flush();
  } finally {
    access.close();
  }
}

async function copyTree(from: FileSystemDirectoryHandle, to: FileSystemDirectoryHandle) {
  for await (const [name, handle] of from.entries()) {
    if (handle.kind === "directory") await copyTree(handle as FileSystemDirectoryHandle, await to.getDirectoryHandle(name, { create: true }));
    else await copyFile(handle as FileSystemFileHandle, to, name);
  }
}

class Exit extends Error {
  constructor(readonly code: number) {
    super(`exit ${code}`);
  }
}

type Fd =
  | { kind: "stdio"; write?: (text: string) => void }
  | { kind: "dir"; path: string[]; preopen?: string; listing?: [string, "file" | "dir"][] }
  | { kind: "file"; path: string; pos: number; append: boolean; open?: Open; data?: Uint8Array | File };

export type WasiOptions = {
  args?: string[];
  env?: Record<string, string>;
  /** Guest path (like `/repo`) to the folder of the file system it shows, relative to its root. */
  preopens: Record<string, string>;
  stdout?: (text: string) => void;
  stderr?: (text: string) => void;
};

type Import = (...args: any[]) => number | void | Promise<number>;

/** Imports that wait on OPFS; also the list for wasm-opt's `asyncify-imports` (see scripts/build-webApp-jj.sh). */
export const ASYNC = new Set([
  "fd_write", "fd_pwrite", "fd_read", "fd_pread", "fd_seek", "fd_filestat_get", "fd_filestat_set_size", "fd_allocate",
  "fd_filestat_set_times", "fd_sync", "fd_close", "fd_readdir", "path_open", "path_filestat_get", "path_filestat_set_times",
  "path_create_directory", "path_remove_directory", "path_unlink_file", "path_rename", "path_link", "path_readlink",
]);

/** How the module waits for async imports. */
export type Mode = "jspi" | "asyncify";

export function hasJSPI(): boolean {
  return typeof (WebAssembly as any).Suspending === "function" && typeof (WebAssembly as any).promising === "function";
}

export class Wasi {
  memory!: WebAssembly.Memory;
  private fds: (Fd | undefined)[] = [];
  private exports!: WebAssembly.Exports;
  private asyncify?: AsyncifyDriver;

  constructor(readonly fs: OpfsFS, private options: WasiOptions, readonly mode: Mode = "jspi") {
    const line = (sink?: (text: string) => void) => {
      let buffered = "";
      return (text: string) => {
        buffered += text;
        const lines = buffered.split("\n");
        buffered = lines.pop() ?? "";
        lines.forEach((l) => (sink ?? console.log)(l));
      };
    };
    this.fds[0] = { kind: "stdio" };
    this.fds[1] = { kind: "stdio", write: line(options.stdout) };
    this.fds[2] = { kind: "stdio", write: line(options.stderr ?? console.error) };
    for (const [guest, host] of Object.entries(options.preopens)) {
      this.fds.push({ kind: "dir", path: splitPath(host), preopen: guest });
    }
  }

  /** Takes the instance's exports; call before any export. */
  attach(instance: WebAssembly.Instance) {
    this.exports = instance.exports;
    this.memory = instance.exports.memory as WebAssembly.Memory;
    if (this.mode === "asyncify") this.asyncify = new AsyncifyDriver(instance.exports, this.memory);
    (instance.exports._initialize as (() => void) | undefined)?.();
  }

  /** Calls an export that may reach async imports. */
  call(name: string, ...args: unknown[]): Promise<any> {
    const fn = this.exports[name] as (...a: unknown[]) => unknown;
    if (this.asyncify) return this.asyncify.call(fn, args);
    return (WebAssembly as any).promising(fn)(...args);
  }

  /** Runs a command module's `_start`; resolves to its exit code. */
  async start(instance: WebAssembly.Instance): Promise<number> {
    this.attach(instance);
    try {
      await this.call("_start");
      return 0;
    } catch (err) {
      if (err instanceof Exit) return err.code;
      throw err;
    }
  }

  private get view() {
    return new DataView(this.memory.buffer);
  }

  private get bytes() {
    return new Uint8Array(this.memory.buffer);
  }

  private string(ptr: number, len: number): string {
    return new TextDecoder().decode(this.bytes.subarray(ptr, ptr + len));
  }

  /** `fd`'s folder joined with the path at `ptr`, with `..` resolved lexically; throws if it leaves the preopen. */
  private resolve(fd: number, ptr: number, len: number): string[] {
    const dir = this.fds[fd];
    if (!dir) throw new Errno(E.BADF);
    if (dir.kind !== "dir") throw new Errno(E.NOTDIR);
    const rel = this.string(ptr, len);
    if (rel.startsWith("/")) throw new Errno(E.NOTCAPABLE);
    const path = [...dir.path];
    const floor = this.preopenFloor(dir.path);
    for (const part of rel.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") {
        if (path.length <= floor) throw new Errno(E.NOTCAPABLE);
        path.pop();
      } else path.push(part);
    }
    return path;
  }

  private preopenFloor(path: string[]): number {
    let floor = 0;
    for (const fd of this.fds) {
      if (fd?.kind === "dir" && fd.preopen !== undefined && fd.path.every((p, i) => path[i] === p)) floor = Math.max(floor, fd.path.length);
    }
    return floor;
  }

  private filestat(ptr: number, meta: Meta) {
    const v = this.view;
    for (let i = 0; i < 64; i += 8) v.setBigUint64(ptr + i, 0n, true);
    if (meta.kind === "none") return;
    const mtime = meta.kind === "file" ? meta.mtime : 0n;
    v.setBigUint64(ptr + 8, meta.ino, true);
    v.setUint8(ptr + 16, meta.kind === "dir" ? FILETYPE.DIR : FILETYPE.FILE);
    v.setBigUint64(ptr + 24, 1n, true);
    v.setBigUint64(ptr + 32, BigInt(meta.kind === "file" ? meta.size : 0), true);
    v.setBigUint64(ptr + 40, mtime, true);
    v.setBigUint64(ptr + 48, mtime, true);
    v.setBigUint64(ptr + 56, mtime, true);
  }

  private iovecs(ptr: number, count: number): Uint8Array[] {
    const v = this.view;
    const out: Uint8Array[] = [];
    for (let i = 0; i < count; i++) {
      out.push(new Uint8Array(this.memory.buffer, v.getUint32(ptr + i * 8, true), v.getUint32(ptr + i * 8 + 4, true)));
    }
    return out;
  }

  private file(fd: number): Extract<Fd, { kind: "file" }> {
    const f = this.fds[fd];
    if (!f) throw new Errno(E.BADF);
    if (f.kind === "dir") throw new Errno(E.ISDIR);
    if (f.kind !== "file") throw new Errno(E.SPIPE);
    return f;
  }

  private async size(f: Extract<Fd, { kind: "file" }>): Promise<number> {
    if (f.open) return (await this.fs.access(f.open)).getSize();
    const data = f.data!;
    return data instanceof Uint8Array ? data.byteLength : data.size;
  }

  private async read(f: Extract<Fd, { kind: "file" }>, iovs: number, count: number, at: number): Promise<number> {
    if (f.open) {
      const access = await this.fs.access(f.open);
      let read = 0;
      for (const buf of this.iovecs(iovs, count)) {
        const n = access.read(buf, { at: at + read });
        read += n;
        if (n < buf.length) break;
      }
      return read;
    }
    const data = f.data!;
    const chunks = this.iovecs(iovs, count);
    const want = chunks.reduce((n, c) => n + c.length, 0);
    const bytes = data instanceof Uint8Array ? data.subarray(at, at + want) : new Uint8Array(await data.slice(at, at + want).arrayBuffer());
    // The await may have moved memory; take fresh views.
    let pos = 0;
    for (const buf of this.iovecs(iovs, count)) {
      const n = Math.min(buf.length, bytes.length - pos);
      buf.set(bytes.subarray(pos, pos + n));
      pos += n;
      if (n < buf.length) break;
    }
    return pos;
  }

  private async write(f: Extract<Fd, { kind: "file" }>, iovs: number, count: number, at: number): Promise<number> {
    if (!f.open) throw new Errno(E.BADF);
    const access = await this.fs.access(f.open);
    this.fs.markWritten(f.open);
    let pos = at;
    for (const chunk of this.iovecs(iovs, count)) pos += access.write(chunk, { at: pos });
    return pos - at;
  }

  /** The import object; file calls are async. */
  get imports(): WebAssembly.ModuleImports {
    const raw = this.raw;
    const wrapped: Record<string, Import | object> = {};
    for (const [name, fn] of Object.entries(raw)) {
      if (!ASYNC.has(name)) wrapped[name] = fn;
      else if (this.mode === "jspi") wrapped[name] = new (WebAssembly as any).Suspending(fn);
      else wrapped[name] = (...args: any[]) => this.asyncify!.handle(() => fn(...args) as Promise<number>);
    }
    // Anything else the module imports fails as unsupported instead of failing instantiation.
    return new Proxy(wrapped, { get: (target, name: string) => target[name] ?? (() => E.NOSYS) }) as WebAssembly.ModuleImports;
  }

  /** The imports unwrapped: file calls return promises of an errno. */
  get raw(): Record<string, Import> {
    const self = this;
    const fs = this.fs;
    const enc = new TextEncoder();
    const sync: Record<string, Import> = {
      args_sizes_get(argc: number, size: number) {
        const args = self.options.args ?? [];
        self.view.setUint32(argc, args.length, true);
        self.view.setUint32(size, args.reduce((n, a) => n + enc.encode(a).length + 1, 0), true);
        return E.SUCCESS;
      },
      args_get(argv: number, buf: number) {
        return writeStrings(self, self.options.args ?? [], argv, buf);
      },
      environ_sizes_get(count: number, size: number) {
        const env = Object.entries(self.options.env ?? {}).map(([k, v]) => `${k}=${v}`);
        self.view.setUint32(count, env.length, true);
        self.view.setUint32(size, env.reduce((n, a) => n + enc.encode(a).length + 1, 0), true);
        return E.SUCCESS;
      },
      environ_get(environ: number, buf: number) {
        return writeStrings(self, Object.entries(self.options.env ?? {}).map(([k, v]) => `${k}=${v}`), environ, buf);
      },
      clock_res_get(_id: number, ptr: number) {
        self.view.setBigUint64(ptr, 1_000n, true);
        return E.SUCCESS;
      },
      clock_time_get(id: number, _precision: bigint, ptr: number) {
        const t = id === 0 ? BigInt(Date.now()) * 1_000_000n : BigInt(Math.round(performance.now() * 1e6));
        self.view.setBigUint64(ptr, t, true);
        return E.SUCCESS;
      },
      random_get(ptr: number, len: number) {
        for (let at = 0; at < len; at += 65536) crypto.getRandomValues(new Uint8Array(self.memory.buffer, ptr + at, Math.min(65536, len - at)));
        return E.SUCCESS;
      },
      sched_yield: () => E.SUCCESS,
      proc_exit(code: number) {
        throw new Exit(code);
      },
      // Timeouts expire at once; nothing in jj waits on them (its file locks are no-ops on WASI).
      poll_oneoff(subs: number, events: number, count: number, nevents: number) {
        const v = self.view;
        for (let i = 0; i < count; i++) {
          const s = subs + i * 48;
          const e = events + i * 32;
          v.setBigUint64(e, v.getBigUint64(s, true), true);
          v.setUint16(e + 8, E.SUCCESS, true);
          v.setUint8(e + 10, v.getUint8(s + 8));
          v.setBigUint64(e + 16, 0n, true);
          v.setUint16(e + 24, 0, true);
        }
        v.setUint32(nevents, count, true);
        return E.SUCCESS;
      },
      fd_prestat_get(fd: number, ptr: number) {
        const f = self.fds[fd];
        if (f?.kind !== "dir" || f.preopen === undefined) return E.BADF;
        self.view.setUint8(ptr, 0);
        self.view.setUint32(ptr + 4, enc.encode(f.preopen).length, true);
        return E.SUCCESS;
      },
      fd_prestat_dir_name(fd: number, ptr: number, len: number) {
        const f = self.fds[fd];
        if (f?.kind !== "dir" || f.preopen === undefined) return E.BADF;
        self.bytes.set(enc.encode(f.preopen).subarray(0, len), ptr);
        return E.SUCCESS;
      },
      fd_fdstat_get(fd: number, ptr: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        const v = self.view;
        v.setUint8(ptr, f.kind === "dir" ? FILETYPE.DIR : f.kind === "file" ? FILETYPE.FILE : FILETYPE.CHAR);
        v.setUint16(ptr + 2, f.kind === "file" && f.append ? FDFLAGS_APPEND : 0, true);
        v.setBigUint64(ptr + 8, 0xffff_ffffn, true);
        v.setBigUint64(ptr + 16, 0xffff_ffffn, true);
        return E.SUCCESS;
      },
      fd_fdstat_set_flags(fd: number, flags: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind === "file") f.append = (flags & FDFLAGS_APPEND) !== 0;
        return E.SUCCESS;
      },
      fd_advise: () => E.SUCCESS,
      fd_datasync: () => E.SUCCESS,
      fd_renumber(from: number, to: number) {
        if (!self.fds[from]) return E.BADF;
        self.fds[to] = self.fds[from];
        self.fds[from] = undefined;
        return E.SUCCESS;
      },
      fd_tell(fd: number, ptr: number) {
        const f = self.fds[fd];
        if (f?.kind !== "file") return E.BADF;
        self.view.setBigUint64(ptr, BigInt(f.pos), true);
        return E.SUCCESS;
      },
      path_symlink: () => E.NOTSUP,
    };
    const async: Record<string, (...args: any[]) => Promise<number | void>> = {
      async fd_write(fd: number, iovs: number, count: number, nwritten: number) {
        const f = self.fds[fd];
        if (f?.kind === "stdio") {
          const chunks = self.iovecs(iovs, count);
          f.write?.(chunks.map((c) => new TextDecoder().decode(c)).join(""));
          self.view.setUint32(nwritten, chunks.reduce((n, c) => n + c.length, 0), true);
          return;
        }
        const file = self.file(fd);
        if (file.append) file.pos = await self.size(file);
        const n = await self.write(file, iovs, count, file.pos);
        file.pos += n;
        self.view.setUint32(nwritten, n, true);
      },
      async fd_pwrite(fd: number, iovs: number, count: number, offset: bigint, nwritten: number) {
        self.view.setUint32(nwritten, await self.write(self.file(fd), iovs, count, Number(offset)), true);
      },
      async fd_read(fd: number, iovs: number, count: number, nread: number) {
        const f = self.fds[fd];
        if (f?.kind === "stdio") return void self.view.setUint32(nread, 0, true);
        const file = self.file(fd);
        const n = await self.read(file, iovs, count, file.pos);
        file.pos += n;
        self.view.setUint32(nread, n, true);
      },
      async fd_pread(fd: number, iovs: number, count: number, offset: bigint, nread: number) {
        self.view.setUint32(nread, await self.read(self.file(fd), iovs, count, Number(offset)), true);
      },
      async fd_seek(fd: number, offset: bigint, whence: number, ptr: number) {
        const f = self.file(fd);
        const base = whence === 0 ? 0 : whence === 1 ? f.pos : await self.size(f);
        const pos = base + Number(offset);
        if (pos < 0) return E.INVAL;
        f.pos = pos;
        self.view.setBigUint64(ptr, BigInt(pos), true);
      },
      async fd_filestat_get(fd: number, ptr: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind === "stdio") {
          self.filestat(ptr, { kind: "none" });
          self.view.setUint8(ptr + 16, FILETYPE.CHAR);
          return;
        }
        if (f.kind === "dir") return void self.filestat(ptr, await fs.stat(f.path));
        if (f.open) {
          const meta = await fs.stat(splitPath(f.open.path));
          const size = (await fs.access(f.open)).getSize();
          return void self.filestat(ptr, meta.kind === "file" ? { ...meta, size } : meta);
        }
        self.filestat(ptr, await fs.stat(splitPath(f.path)));
      },
      async fd_filestat_set_size(fd: number, size: bigint) {
        const f = self.file(fd);
        if (!f.open) return E.BADF;
        const access = await fs.access(f.open);
        fs.markWritten(f.open);
        access.truncate(Number(size));
      },
      async fd_allocate(fd: number, offset: bigint, len: bigint) {
        const f = self.file(fd);
        if (!f.open) return E.BADF;
        const access = await fs.access(f.open);
        const end = Number(offset + len);
        if (end > access.getSize()) {
          fs.markWritten(f.open);
          access.truncate(end);
        }
      },
      async fd_filestat_set_times(fd: number, _atim: bigint, mtim: bigint, flags: number) {
        const f = self.fds[fd];
        if (!f || f.kind === "stdio") return E.BADF;
        if (flags & (FST.MTIM | FST.MTIM_NOW)) await fs.setMtime(f.kind === "dir" ? f.path : splitPath(f.open?.path ?? f.path), flags & FST.MTIM_NOW ? now() : mtim);
      },
      async fd_sync(fd: number) {
        const f = self.fds[fd];
        if (f?.kind === "file" && f.open?.access) f.open.access.flush();
      },
      async fd_close(fd: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        self.fds[fd] = undefined;
        if (f.kind === "file" && f.open) await fs.release(f.open);
      },
      async fd_readdir(fd: number, buf: number, len: number, cookie: bigint, used: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind !== "dir") return E.NOTDIR;
        if (cookie === 0n || !f.listing) f.listing = await fs.list(f.path);
        return self.writeDirents(f.listing, buf, len, cookie, used);
      },
      async path_open(dirfd: number, _lookup: number, ptr: number, len: number, oflags: number, rights: bigint, _ri: bigint, fdflags: number, out: number) {
        const path = self.resolve(dirfd, ptr, len);
        let meta = await fs.stat(path);
        if (meta.kind !== "none" && oflags & OFLAGS.CREAT && oflags & OFLAGS.EXCL) return E.EXIST;
        if (meta.kind === "none" && !(oflags & OFLAGS.CREAT)) return E.NOENT;
        if (oflags & OFLAGS.DIRECTORY && meta.kind !== "dir") return meta.kind === "none" ? E.NOENT : E.NOTDIR;
        let fd: Fd;
        if (meta.kind === "dir") fd = { kind: "dir", path };
        else {
          const key = path.join("/");
          // A file this module holds open for writing is read through that handle too.
          const writable = (BigInt(rights) & RIGHTS_WRITE) !== 0n || (oflags & (OFLAGS.CREAT | OFLAGS.TRUNC)) !== 0 || fs.open.has(key);
          const append = (fdflags & FDFLAGS_APPEND) !== 0;
          if (writable) {
            if (path.length === 0) return E.ISDIR;
            const open = await fs.acquire(key, true);
            if (oflags & OFLAGS.TRUNC) {
              const access = await fs.access(open);
              if (access.getSize() > 0 || meta.kind === "none") {
                fs.markWritten(open);
                access.truncate(0);
              }
            } else if (meta.kind === "none") fs.markWritten(open);
            fd = { kind: "file", path: key, pos: 0, append, open };
          } else fd = { kind: "file", path: key, pos: 0, append, data: await fs.readable(path) };
          meta = { kind: "file", size: 0, mtime: 0n, ino: 0n };
        }
        self.view.setUint32(out, self.addFd(fd), true);
      },
      async path_filestat_get(dirfd: number, _flags: number, ptr: number, len: number, buf: number) {
        const meta = await fs.stat(self.resolve(dirfd, ptr, len));
        if (meta.kind === "none") return E.NOENT;
        self.filestat(buf, meta);
      },
      async path_filestat_set_times(dirfd: number, _flags: number, ptr: number, len: number, _atim: bigint, mtim: bigint, flags: number) {
        const path = self.resolve(dirfd, ptr, len);
        if (flags & (FST.MTIM | FST.MTIM_NOW)) await fs.setMtime(path, flags & FST.MTIM_NOW ? now() : mtim);
      },
      async path_create_directory(dirfd: number, ptr: number, len: number) {
        await fs.mkdir(self.resolve(dirfd, ptr, len));
      },
      async path_remove_directory(dirfd: number, ptr: number, len: number) {
        await fs.rmdir(self.resolve(dirfd, ptr, len));
      },
      async path_unlink_file(dirfd: number, ptr: number, len: number) {
        await fs.unlink(self.resolve(dirfd, ptr, len));
      },
      async path_rename(fromfd: number, fromptr: number, fromlen: number, tofd: number, toptr: number, tolen: number) {
        await fs.rename(self.resolve(fromfd, fromptr, fromlen), self.resolve(tofd, toptr, tolen));
      },
      async path_link(oldfd: number, _flags: number, oldptr: number, oldlen: number, newfd: number, newptr: number, newlen: number) {
        await fs.link(self.resolve(oldfd, oldptr, oldlen), self.resolve(newfd, newptr, newlen));
      },
      async path_readlink(dirfd: number, ptr: number, len: number) {
        return (await fs.stat(self.resolve(dirfd, ptr, len))).kind === "none" ? E.NOENT : E.INVAL;
      },
    };
    const fast = this.fastPaths();
    const out: Record<string, Import> = { ...sync };
    for (const [name, fn] of Object.entries(async)) {
      const quick = fast[name];
      // Errors become errnos here: a thrown JS error would unwind through the module.
      out[name] = (...args: any[]) => {
        if (quick) {
          try {
            const r = quick(...args);
            if (r !== undefined) return r;
          } catch (err) {
            return errno(err);
          }
        }
        return fn(...args).then(
          (r) => (typeof r === "number" ? r : E.SUCCESS),
          (err) => errno(err),
        );
      };
    }
    return out;
  }

  /** Answers from memory where possible: returning a number instead of a promise doesn't suspend the module,
   * which matters for jj's thousands of stats per snapshot. `undefined` falls back to the async import. */
  private fastPaths(): Record<string, (...args: any[]) => number | undefined> {
    const self = this;
    const fs = this.fs;
    const readSync = (f: Extract<Fd, { kind: "file" }>, iovs: number, count: number, at: number): number | undefined => {
      let source: Uint8Array | SyncHandle | undefined;
      if (f.open) source = f.open.orphan ? undefined : (f.open.access ?? undefined);
      else if (f.data instanceof Uint8Array) source = f.data;
      if (!source) return undefined;
      let read = 0;
      for (const buf of self.iovecs(iovs, count)) {
        let n: number;
        if (source instanceof Uint8Array) {
          n = Math.max(0, Math.min(buf.length, source.length - at - read));
          buf.set(source.subarray(at + read, at + read + n));
        } else n = source.read(buf, { at: at + read });
        read += n;
        if (n < buf.length) break;
      }
      return read;
    };
    const writeSync = (f: Extract<Fd, { kind: "file" }>, iovs: number, count: number, at: number): number | undefined => {
      const access = f.open?.access;
      if (!f.open || !access) return undefined;
      fs.markWritten(f.open);
      let pos = at;
      for (const chunk of self.iovecs(iovs, count)) pos += access.write(chunk, { at: pos });
      return pos - at;
    };
    const fileFd = (fd: number) => {
      const f = self.fds[fd];
      return f?.kind === "file" ? f : undefined;
    };
    return {
      path_filestat_get(dirfd: number, _flags: number, ptr: number, len: number, buf: number) {
        const meta = fs.cachedStat(self.resolve(dirfd, ptr, len));
        if (!meta) return undefined;
        if (meta.kind === "none") return E.NOENT;
        self.filestat(buf, meta);
        return E.SUCCESS;
      },
      fd_filestat_get(fd: number, ptr: number) {
        const f = self.fds[fd];
        if (!f || f.kind === "stdio") return undefined;
        const parts = f.kind === "dir" ? f.path : splitPath(f.open?.path ?? f.path);
        const meta = fs.cachedStat(parts);
        if (!meta) return undefined;
        if (f.kind === "file" && f.open?.access && meta.kind === "file") self.filestat(ptr, { ...meta, size: f.open.access.getSize() });
        else self.filestat(ptr, meta);
        return E.SUCCESS;
      },
      fd_read(fd: number, iovs: number, count: number, nread: number) {
        const f = fileFd(fd);
        if (!f) return undefined;
        const n = readSync(f, iovs, count, f.pos);
        if (n === undefined) return undefined;
        f.pos += n;
        self.view.setUint32(nread, n, true);
        return E.SUCCESS;
      },
      fd_pread(fd: number, iovs: number, count: number, offset: bigint, nread: number) {
        const f = fileFd(fd);
        const n = f && readSync(f, iovs, count, Number(offset));
        if (n === undefined) return undefined;
        self.view.setUint32(nread, n, true);
        return E.SUCCESS;
      },
      fd_write(fd: number, iovs: number, count: number, nwritten: number) {
        const f = fileFd(fd);
        if (!f || f.append) return undefined;
        const n = writeSync(f, iovs, count, f.pos);
        if (n === undefined) return undefined;
        f.pos += n;
        self.view.setUint32(nwritten, n, true);
        return E.SUCCESS;
      },
      fd_pwrite(fd: number, iovs: number, count: number, offset: bigint, nwritten: number) {
        const f = fileFd(fd);
        const n = f && writeSync(f, iovs, count, Number(offset));
        if (n === undefined) return undefined;
        self.view.setUint32(nwritten, n, true);
        return E.SUCCESS;
      },
      fd_seek(fd: number, offset: bigint, whence: number, ptr: number) {
        const f = fileFd(fd);
        if (!f) return undefined;
        let base: number;
        if (whence === 0) base = 0;
        else if (whence === 1) base = f.pos;
        else if (f.open?.access) base = f.open.access.getSize();
        else if (f.data instanceof Uint8Array) base = f.data.length;
        else return undefined;
        const pos = base + Number(offset);
        if (pos < 0) return E.INVAL;
        f.pos = pos;
        self.view.setBigUint64(ptr, BigInt(pos), true);
        return E.SUCCESS;
      },
      fd_close(fd: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind === "file" && f.open && f.open.refs <= 1) return undefined;
        self.fds[fd] = undefined;
        if (f.kind === "file" && f.open) f.open.refs--;
        return E.SUCCESS;
      },
      fd_readdir(fd: number, buf: number, len: number, cookie: bigint, used: number) {
        const f = self.fds[fd];
        if (f?.kind !== "dir" || !f.listing || cookie === 0n) return undefined;
        return self.writeDirents(f.listing, buf, len, cookie, used);
      },
      path_open(dirfd: number, _lookup: number, ptr: number, len: number, oflags: number, rights: bigint, _ri: bigint, _fdflags: number, out: number) {
        if (oflags & (OFLAGS.CREAT | OFLAGS.TRUNC) || (BigInt(rights) & RIGHTS_WRITE) !== 0n) return undefined;
        const path = self.resolve(dirfd, ptr, len);
        const meta = fs.cachedStat(path);
        if (!meta || fs.open.has(path.join("/"))) return undefined;
        if (meta.kind === "none") return E.NOENT;
        let fd: Fd;
        if (meta.kind === "dir") fd = { kind: "dir", path };
        else {
          if (oflags & OFLAGS.DIRECTORY) return E.NOTDIR;
          const data = fs.cachedContent(path);
          if (!data) return undefined;
          fd = { kind: "file", path: path.join("/"), pos: 0, append: false, data };
        }
        self.view.setUint32(out, self.addFd(fd), true);
        return E.SUCCESS;
      },
    };
  }

  private addFd(fd: Fd): number {
    let index = this.fds.findIndex((f, i) => i > 2 && !f);
    if (index < 0) index = this.fds.length;
    this.fds[index] = fd;
    return index;
  }

  private writeDirents(listing: [string, "file" | "dir"][], buf: number, len: number, cookie: bigint, used: number): number {
    const enc = new TextEncoder();
    let at = 0;
    for (let i = Number(cookie); i < listing.length && at < len; i++) {
      const [name, kind] = listing[i];
      const encoded = enc.encode(name);
      const entry = new Uint8Array(24 + encoded.length);
      const ev = new DataView(entry.buffer);
      ev.setBigUint64(0, BigInt(i + 1), true);
      ev.setBigUint64(8, BigInt(i + 1), true);
      ev.setUint32(16, encoded.length, true);
      ev.setUint8(20, kind === "dir" ? FILETYPE.DIR : FILETYPE.FILE);
      entry.set(encoded, 24);
      // A truncated last entry tells the caller to come back with a bigger buffer.
      const n = Math.min(entry.length, len - at);
      this.bytes.set(entry.subarray(0, n), buf + at);
      at += n;
    }
    this.view.setUint32(used, at, true);
    return E.SUCCESS;
  }
}

// Asyncify (binaryen's `--asyncify`): an import returning a promise unwinds the stack into `data`; once the promise
// settles, the export is called again and rewinds to the import, which now returns the result.
const DATA_BYTES = 1 << 20;

class AsyncifyDriver {
  private data: number;
  private pending: Promise<number> | null = null;
  private result = 0;

  constructor(private exports: WebAssembly.Exports, memory: WebAssembly.Memory) {
    // A buffer past everything Rust's allocator owns; it grows memory itself from the new end.
    const start = memory.grow(Math.ceil((DATA_BYTES + 8) / 65536)) * 65536;
    const view = new DataView(memory.buffer);
    view.setUint32(start, start + 8, true);
    view.setUint32(start + 4, start + 8 + DATA_BYTES, true);
    this.data = start;
  }

  private get state(): number {
    return (this.exports.asyncify_get_state as () => number)();
  }

  handle(body: () => Promise<number>): number {
    if (this.state === 2) {
      (this.exports.asyncify_stop_rewind as () => void)();
      return this.result;
    }
    this.pending = body();
    (this.exports.asyncify_start_unwind as (p: number) => void)(this.data);
    return 0;
  }

  async call(fn: (...a: unknown[]) => unknown, args: unknown[]): Promise<unknown> {
    let value = fn(...args);
    while (this.state === 1) {
      (this.exports.asyncify_stop_unwind as () => void)();
      this.result = await this.pending!;
      this.pending = null;
      (this.exports.asyncify_start_rewind as (p: number) => void)(this.data);
      value = fn(...args);
    }
    return value;
  }
}

function writeStrings(wasi: Wasi, strings: string[], ptrs: number, buf: number): number {
  const view = new DataView(wasi.memory.buffer);
  const bytes = new Uint8Array(wasi.memory.buffer);
  let at = buf;
  strings.forEach((s, i) => {
    const encoded = new TextEncoder().encode(s);
    view.setUint32(ptrs + i * 4, at, true);
    bytes.set(encoded, at);
    bytes[at + encoded.length] = 0;
    at += encoded.length + 1;
  });
  return E.SUCCESS;
}
