// Browser storage handles over the desktop library; all desktop operations run in Rust.
import { nativeConfig, invokeNative, listenNative } from "./native";

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

// MARK: - Native bridge

type DesktopStorage = DiskBackend & { library: string };
let workerStorage: DesktopStorage | null = null;

const nativeStorage: DesktopStorage | null = nativeConfig ? {
  library: nativeConfig.library,
  stat: (path) => invokeNative("disk_op", { op: "stat", path }),
  list: (path) => invokeNative("disk_op", { op: "list", path }),
  read: async (path) => new Uint8Array(await invokeNative<ArrayBuffer>("disk_read", { path })),
  write: (path, data) => invokeNative("disk_write", data, { headers: { "x-typewright-path": encodeURIComponent(path) } }),
  mkdir: (path) => invokeNative("disk_op", { op: "mkdir", path }),
  remove: (path, recursive) => invokeNative("disk_op", { op: "remove", path, recursive }),
  rename: (path, to) => invokeNative("disk_op", { op: "rename", path, to }),
} : null;

/** Workers ask the page to call Tauri; no Node, OPFS or synchronous IPC is needed. */
export function connectDiskWorker(worker: Worker) {
  if (!nativeStorage) return;
  const { port1, port2 } = new MessageChannel();
  port1.onmessage = async ({ data: { id, op, args } }) => {
    try {
      let value: unknown;
      switch (op) {
        case "stat": value = await nativeStorage.stat(args[0]); break;
        case "list": value = await nativeStorage.list(args[0]); break;
        case "read": value = await nativeStorage.read(args[0]); break;
        case "write": value = await nativeStorage.write(args[0], args[1]); break;
        case "mkdir": value = await nativeStorage.mkdir(args[0]); break;
        case "remove": value = await nativeStorage.remove(args[0], args[1]); break;
        case "rename": value = await nativeStorage.rename(args[0], args[1]); break;
        default: throw new Error("Unknown disk operation");
      }
      port1.postMessage({ id, value });
    } catch (error) {
      port1.postMessage({ id, error: String((error as Error)?.message ?? error) });
    }
  };
  worker.postMessage({ diskPort: port2, library: nativeStorage.library }, [port2]);
}

export function acceptDiskWorker(message: unknown): boolean {
  const data = message as { diskPort?: MessagePort; library?: string };
  if (!data.diskPort || !data.library) return false;
  const port = data.diskPort;
  let next = 0;
  const pending = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  port.onmessage = ({ data }) => {
    const request = pending.get(data.id);
    pending.delete(data.id);
    if (data.error) request?.reject(new Error(data.error));
    else request?.resolve(data.value);
  };
  const call = <T>(op: string, ...args: unknown[]): Promise<T> => new Promise((resolve, reject) => {
    const id = ++next;
    pending.set(id, { resolve, reject });
    port.postMessage({ id, op, args });
  });
  workerStorage = {
    library: data.library,
    stat: (path) => call("stat", path),
    list: (path) => call("list", path),
    read: (path) => call("read", path),
    write: (path, data) => call("write", path, data),
    mkdir: (path) => call("mkdir", path),
    remove: (path, recursive) => call("remove", path, recursive),
    rename: (from, to) => call("rename", from, to),
  };
  return true;
}

/** The desktop library's absolute path, or null in the browser. */
export function libraryFolder(): string | null {
  return (nativeStorage ?? workerStorage)?.library ?? null;
}

let diskRoot: DiskDirectoryHandle | undefined;

/** Desktop always uses the native library; the web app keeps browser storage. */
export async function storageRoot(): Promise<FileSystemDirectoryHandle> {
  const backend = nativeStorage ?? workerStorage;
  if (!backend) return navigator.storage.getDirectory();
  diskRoot ??= new DiskDirectoryHandle(backend, "", "");
  return diskRoot as unknown as FileSystemDirectoryHandle;
}

export function watchLibrary(listener: (paths: string[]) => void) {
  if (nativeConfig) void listenNative<string[]>("library-changed", listener);
}
