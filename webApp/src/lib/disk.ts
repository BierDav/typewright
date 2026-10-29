// The desktop app keeps the library in a real folder instead of the origin private file system, so other programs
// (agents, editors) can work on spaces by path. These handles give `storage.ts`, the jj host and the typst worker
// OPFS's API over that folder: workers reach the disk through Node (Electron's `nodeIntegrationInWorker`), the page
// through the preload's bridge (`desktopApp/preload.cjs`, the same operations), both limited to the folder.

export type DiskStat = { dir: boolean; size: number; mtime: number };

/** Paths are relative to the library folder; failures throw an Error whose message is the errno code (ENOENT …). */
export type DiskBackend = {
  stat(path: string): Promise<DiskStat | null>;
  list(path: string): Promise<{ name: string; dir: boolean }[]>;
  read(path: string): Promise<Uint8Array>;
  write(path: string, data: Uint8Array): Promise<void>;
  mkdir(path: string): Promise<void>;
  remove(path: string, recursive: boolean): Promise<void>;
  rename(from: string, to: string): Promise<void>;
  /** Workers only: a file open for synchronous reads and writes, like OPFS's sync access handles. */
  openSync?(path: string): SyncFile;
};

export type SyncFile = {
  read(buffer: ArrayBufferView, at: number): number;
  write(buffer: ArrayBufferView, at: number): number;
  truncate(size: number): void;
  size(): number;
  flush(): void;
  close(): void;
};

/** The library's folder name for `spaces/`, as the Mac app names it. */
const SPACES_ON_DISK = "Spaces";

/** Maps a storage path to its place in the folder; the library's spaces live in `Spaces`. */
export function toDisk(path: string): string {
  const parts = path.split("/").filter(Boolean);
  if (parts.some((p) => p === "." || p === "..")) throw new Error("EACCES");
  if (parts[0] === "spaces") parts[0] = SPACES_ON_DISK;
  return parts.join("/");
}

function fromDisk(parent: string, name: string): string {
  return parent === "" && name === SPACES_ON_DISK ? "spaces" : name;
}

function domError(err: unknown): DOMException {
  const code = (err as Error)?.message ?? "";
  const name =
    code.includes("ENOENT") ? "NotFoundError"
    : code.includes("ENOTDIR") || code.includes("EISDIR") ? "TypeMismatchError"
    : code.includes("ENOTEMPTY") || code.includes("EEXIST") ? "InvalidModificationError"
    : code.includes("ENOSPC") ? "QuotaExceededError"
    : code.includes("EACCES") || code.includes("EPERM") ? "NotAllowedError"
    : "InvalidStateError";
  return new DOMException(code || "disk error", name);
}

async function guard<T>(body: () => Promise<T>): Promise<T> {
  try {
    return await body();
  } catch (err) {
    throw err instanceof DOMException ? err : domError(err);
  }
}

function checkName(name: string) {
  if (!name || name.includes("/") || name.includes("\\") || name === "." || name === "..") throw new TypeError(`Invalid name: ${name}`);
}

const join = (dir: string, name: string) => (dir ? `${dir}/${name}` : name);

function bytesOf(data: unknown): Uint8Array {
  if (typeof data === "string") return new TextEncoder().encode(data);
  if (data instanceof Uint8Array) return data;
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  throw new TypeError("Unsupported data");
}

class DiskSyncAccessHandle {
  private position = 0;
  constructor(private file: SyncFile) {}

  read(buffer: ArrayBufferView, options?: { at?: number }): number {
    const n = this.file.read(buffer, options?.at ?? this.position);
    this.position = (options?.at ?? this.position) + n;
    return n;
  }

  write(buffer: ArrayBufferView, options?: { at?: number }): number {
    const n = this.file.write(buffer, options?.at ?? this.position);
    this.position = (options?.at ?? this.position) + n;
    return n;
  }

  truncate(size: number) {
    this.file.truncate(size);
    this.position = Math.min(this.position, size);
  }

  getSize(): number {
    return this.file.size();
  }

  flush() {
    this.file.flush();
  }

  close() {
    this.file.close();
  }
}

class DiskFileHandle {
  readonly kind = "file";
  constructor(private backend: DiskBackend, readonly name: string, readonly path: string) {}

  async getFile(): Promise<File> {
    return guard(async () => {
      const [data, info] = await Promise.all([this.backend.read(this.path), this.backend.stat(this.path)]);
      return new File([data as Uint8Array<ArrayBuffer>], this.name, { lastModified: info?.mtime ?? Date.now() });
    });
  }

  /** A real WritableStream, so `pipeTo` works, with the file stream's own `write`; the file changes on close. */
  async createWritable(options?: { keepExistingData?: boolean }) {
    let chunks: Uint8Array[] = options?.keepExistingData ? [await guard(() => this.backend.read(this.path))] : [];
    const append = (data: unknown) => {
      if (data && typeof data === "object" && "type" in data) {
        const command = data as { type: string; data?: unknown; size?: number };
        if (command.type === "truncate") chunks = [concat(chunks).subarray(0, command.size ?? 0)];
        else if (command.type === "write") chunks.push(bytesOf(command.data));
        return;
      }
      chunks.push(bytesOf(data));
    };
    const backend = this.backend;
    const path = this.path;
    const stream = new WritableStream<unknown>({
      async write(chunk) {
        append(chunk instanceof Blob ? new Uint8Array(await chunk.arrayBuffer()) : chunk);
      },
      async close() {
        await guard(() => backend.write(path, concat(chunks)));
      },
    });
    return Object.assign(stream, {
      async write(data: unknown) {
        append(data instanceof Blob ? new Uint8Array(await data.arrayBuffer()) : data);
      },
      async truncate(size: number) {
        append({ type: "truncate", size });
      },
    });
  }

  async createSyncAccessHandle() {
    if (!this.backend.openSync) throw new DOMException("Sync access needs a worker", "InvalidStateError");
    try {
      return new DiskSyncAccessHandle(this.backend.openSync(this.path));
    } catch (err) {
      throw domError(err);
    }
  }

  async move(dir: DiskDirectoryHandle | string, name?: string) {
    const target = typeof dir === "string" ? join(parentOf(this.path), dir) : join(dir.path, name!);
    await guard(() => this.backend.rename(this.path, target));
  }

  async isSameEntry(other: { path?: string }) {
    return other?.path === this.path;
  }
}

function concat(chunks: Uint8Array[]): Uint8Array {
  if (chunks.length === 1) return chunks[0];
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

function parentOf(path: string): string {
  const i = path.lastIndexOf("/");
  return i < 0 ? "" : path.slice(0, i);
}

export class DiskDirectoryHandle {
  readonly kind = "directory";
  constructor(private backend: DiskBackend, readonly name: string, readonly path: string) {}

  async getDirectoryHandle(name: string, options: { create?: boolean } = {}) {
    checkName(name);
    const path = join(this.path, name);
    return guard(async () => {
      const info = await this.backend.stat(path);
      if (info && !info.dir) throw new DOMException(path, "TypeMismatchError");
      if (!info) {
        if (!options.create) throw new DOMException(path, "NotFoundError");
        await this.backend.mkdir(path);
      }
      return new DiskDirectoryHandle(this.backend, name, path);
    });
  }

  async getFileHandle(name: string, options: { create?: boolean } = {}) {
    checkName(name);
    const path = join(this.path, name);
    return guard(async () => {
      const info = await this.backend.stat(path);
      if (info?.dir) throw new DOMException(path, "TypeMismatchError");
      if (!info) {
        if (!options.create) throw new DOMException(path, "NotFoundError");
        await this.backend.write(path, new Uint8Array(0));
      }
      return new DiskFileHandle(this.backend, name, path);
    });
  }

  async removeEntry(name: string, options: { recursive?: boolean } = {}) {
    checkName(name);
    const path = join(this.path, name);
    await guard(async () => {
      const info = await this.backend.stat(path);
      if (!info) throw new DOMException(path, "NotFoundError");
      if (info.dir && !options.recursive && (await this.backend.list(path)).length) throw new DOMException(path, "InvalidModificationError");
      await this.backend.remove(path, !!options.recursive);
    });
  }

  async *entries(): AsyncIterableIterator<[string, DiskFileHandle | DiskDirectoryHandle]> {
    const children = await guard(() => this.backend.list(this.path));
    for (const child of children) {
      const name = fromDisk(this.path, child.name);
      const path = join(this.path, name);
      yield [name, child.dir ? new DiskDirectoryHandle(this.backend, name, path) : new DiskFileHandle(this.backend, name, path)];
    }
  }

  async *keys(): AsyncIterableIterator<string> {
    for await (const [name] of this.entries()) yield name;
  }

  async *values(): AsyncIterableIterator<DiskFileHandle | DiskDirectoryHandle> {
    for await (const [, handle] of this.entries()) yield handle;
  }

  [Symbol.asyncIterator]() {
    return this.entries();
  }

  async move(dir: DiskDirectoryHandle | string, name?: string) {
    const target = typeof dir === "string" ? join(parentOf(this.path), dir) : join(dir.path, name!);
    await guard(() => this.backend.rename(this.path, target));
  }

  async isSameEntry(other: { path?: string }) {
    return other?.path === this.path;
  }
}

// MARK: - Backends

type NodeRequire = (id: string) => unknown;
type NodeFs = typeof import("node:fs");
type NodePath = typeof import("node:path");

/** Node's `require` in an Electron worker; absent in browsers. */
function nodeRequire(): NodeRequire | null {
  const req = (globalThis as { require?: NodeRequire }).require;
  return typeof req === "function" ? req : null;
}

/** The library folder, when this runs in the desktop app's worker. */
function workerLibrary(): string | null {
  const proc = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process;
  return nodeRequire() && proc?.env?.TYPEWRIGHT_LIBRARY ? proc.env.TYPEWRIGHT_LIBRARY : null;
}

/** Node's file system, for workers (the preload has its own copy of these few lines). */
function nodeBackend(library: string): DiskBackend {
  const req = nodeRequire()!;
  const fs = req("fs") as NodeFs;
  const path = req("path") as NodePath;
  const abs = (rel: string) => path.join(library, toDisk(rel));
  const wrap = async <T>(body: () => Promise<T>): Promise<T> => {
    try {
      return await body();
    } catch (err) {
      throw new Error((err as { code?: string }).code ?? String(err));
    }
  };
  return {
    stat: (rel) =>
      wrap(async () => {
        try {
          const info = await fs.promises.stat(abs(rel));
          return { dir: info.isDirectory(), size: info.size, mtime: info.mtimeMs };
        } catch (err) {
          if ((err as { code?: string }).code === "ENOENT") return null;
          throw err;
        }
      }),
    list: (rel) => wrap(async () => (await fs.promises.readdir(abs(rel), { withFileTypes: true })).map((e) => ({ name: e.name, dir: e.isDirectory() || (e.isSymbolicLink() && fs.statSync(path.join(abs(rel), e.name)).isDirectory()) }))),
    read: (rel) => wrap(async () => new Uint8Array(await fs.promises.readFile(abs(rel)))),
    write: (rel, data) => wrap(() => fs.promises.writeFile(abs(rel), data)),
    mkdir: (rel) => wrap(async () => void (await fs.promises.mkdir(abs(rel), { recursive: true }))),
    remove: (rel, recursive) => wrap(() => fs.promises.rm(abs(rel), { recursive, force: false })),
    rename: (from, to) => wrap(() => fs.promises.rename(abs(from), abs(to))),
    openSync(rel) {
      let fd: number;
      try {
        fd = fs.openSync(abs(rel), "r+");
      } catch (err) {
        throw new Error((err as { code?: string }).code ?? String(err));
      }
      const view = (b: ArrayBufferView) => new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
      return {
        read: (buffer, at) => fs.readSync(fd, view(buffer), 0, buffer.byteLength, at),
        write: (buffer, at) => fs.writeSync(fd, view(buffer), 0, buffer.byteLength, at),
        truncate: (size) => fs.ftruncateSync(fd, size),
        size: () => fs.fstatSync(fd).size,
        flush: () => fs.fsyncSync(fd),
        close: () => fs.closeSync(fd),
      };
    },
  };
}

type DesktopStorage = DiskBackend & { library: string };

function pageBackend(): DesktopStorage | null {
  if (typeof window === "undefined") return null;
  return (window as unknown as { typewrightDesktop?: { storage?: DesktopStorage } }).typewrightDesktop?.storage ?? null;
}

/** The desktop app's library folder (absolute), or null in the browser. */
export function libraryFolder(): string | null {
  return pageBackend()?.library ?? workerLibrary();
}

let diskRoot: DiskDirectoryHandle | null | undefined;

/** The storage root: the desktop app's library folder, or the origin private file system. */
export async function storageRoot(): Promise<FileSystemDirectoryHandle> {
  if (diskRoot === undefined) {
    const page = pageBackend();
    const library = workerLibrary();
    diskRoot = page ? new DiskDirectoryHandle(page, "", "") : library ? new DiskDirectoryHandle(nodeBackend(library), "", "") : null;
  }
  return diskRoot ? (diskRoot as unknown as FileSystemDirectoryHandle) : navigator.storage.getDirectory();
}

/** Reports changes other programs make in the desktop app's library folder. */
export function watchLibrary(listener: (paths: string[]) => void) {
  (pageBackend() as (DesktopStorage & { watch?(listener: (paths: string[]) => void): void }) | null)?.watch?.(listener);
}

/** Once, copies what the desktop app kept in browser storage before it used the folder; files on disk win. */
export async function migrateBrowserStorage() {
  const disk = pageBackend();
  if (!disk || (await disk.stat(".migrated"))) return;
  const opfs = await navigator.storage.getDirectory();
  async function copy(dir: FileSystemDirectoryHandle, rel: string) {
    for await (const [name, handle] of (dir as unknown as DiskDirectoryHandle).entries()) {
      const path = rel ? `${rel}/${name}` : name;
      // The jj host's mtimes belong to browser storage; without them every file is checked once.
      if (path === "jj-host") continue;
      if (handle.kind === "directory") {
        await disk!.mkdir(path);
        await copy(handle as unknown as FileSystemDirectoryHandle, path);
      } else if (!(await disk!.stat(path))) {
        await disk!.write(path, new Uint8Array(await (await (handle as unknown as FileSystemFileHandle).getFile()).arrayBuffer()));
      }
    }
  }
  await copy(opfs, "");
  await disk.write(".migrated", new TextEncoder().encode("Spaces from the browser storage were copied here.\n"));
}
