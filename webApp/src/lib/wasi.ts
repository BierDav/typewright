// A WASI preview 1 host for one module over an in-memory file system, enough for jj-lib (`jjBridge` built for
// wasm32-wasip1). Files carry real mtimes, since jj skips files whose size and mtime didn't change.
// Paths the module touched collect in `MemFS.dirty`, so the caller can persist them.

export type MemFile = { kind: "file"; data: Uint8Array; size: number; mtime: bigint; ino: bigint; nlink: number };
export type MemDir = { kind: "dir"; entries: Map<string, MemNode>; mtime: bigint; ino: bigint };
export type MemNode = MemFile | MemDir;

const E = {
  SUCCESS: 0, ACCES: 2, BADF: 8, EXIST: 20, INVAL: 28, IO: 29, ISDIR: 31, NOENT: 44, NOSYS: 52, NOTDIR: 54,
  NOTEMPTY: 55, NOTSUP: 58, NOTCAPABLE: 76, SPIPE: 70,
} as const;
const FILETYPE = { CHAR: 2, DIR: 3, FILE: 4 } as const;
const OFLAGS = { CREAT: 1, DIRECTORY: 2, EXCL: 4, TRUNC: 8 } as const;
const FDFLAGS_APPEND = 1;
const FST = { ATIM: 1, ATIM_NOW: 2, MTIM: 4, MTIM_NOW: 8 } as const;

let lastNow = 0n;

/** Nanoseconds since the epoch, strictly increasing, so two writes never share an mtime. */
export function now(): bigint {
  const t = BigInt(Date.now()) * 1_000_000n;
  lastNow = t > lastNow ? t : lastNow + 1n;
  return lastNow;
}

let nextIno = 1n;

export function memFile(data: Uint8Array, mtime = now()): MemFile {
  return { kind: "file", data, size: data.length, mtime, ino: nextIno++, nlink: 1 };
}

export function memDir(mtime = now()): MemDir {
  return { kind: "dir", entries: new Map(), mtime, ino: nextIno++ };
}

export function splitPath(path: string): string[] {
  return path.split("/").filter((p) => p && p !== ".");
}

export class MemFS {
  root = memDir();
  /** Root-relative paths written, created, removed or renamed since the last `takeDirty`. */
  dirty = new Set<string>();

  lookup(path: string[]): MemNode | null {
    let node: MemNode = this.root;
    for (const part of path) {
      if (node.kind !== "dir") return null;
      const next = node.entries.get(part);
      if (!next) return null;
      node = next;
    }
    return node;
  }

  /** The folder holding `path`, created on the way if `create`. */
  parent(path: string[], create = false): MemDir | null {
    let dir = this.root;
    for (const part of path.slice(0, -1)) {
      let next = dir.entries.get(part);
      if (!next && create) {
        next = memDir();
        dir.entries.set(part, next);
      }
      if (!next || next.kind !== "dir") return null;
      dir = next;
    }
    return dir;
  }

  /** Puts a node at `path` (from outside the module, so it's not dirty), replacing what was there. */
  put(path: string, node: MemNode) {
    const parts = splitPath(path);
    if (parts.length === 0) {
      if (node.kind === "dir") this.root = node;
      return;
    }
    this.parent(parts, true)?.entries.set(parts[parts.length - 1], node);
  }

  delete(path: string) {
    const parts = splitPath(path);
    if (parts.length) this.parent(parts)?.entries.delete(parts[parts.length - 1]);
  }

  touch(path: string[]) {
    this.dirty.add(path.join("/"));
  }

  takeDirty(): string[] {
    const paths = [...this.dirty];
    this.dirty.clear();
    return paths;
  }
}

class Exit extends Error {
  constructor(readonly code: number) {
    super(`exit ${code}`);
  }
}

type Fd =
  | { kind: "stdio"; write?: (text: string) => void }
  | { kind: "file"; node: MemFile; path: string[]; pos: number; append: boolean }
  | { kind: "dir"; node: MemDir; path: string[]; preopen?: string };

function grow(file: MemFile, size: number) {
  if (size <= file.data.length) return;
  const data = new Uint8Array(Math.max(size, file.data.length * 2, 64));
  data.set(file.data.subarray(0, file.size));
  file.data = data;
}

/** The file's bytes, trimmed to its size. */
export function contents(file: MemFile): Uint8Array {
  return file.data.length === file.size ? file.data : file.data.slice(0, file.size);
}

export type WasiOptions = {
  args?: string[];
  env?: Record<string, string>;
  /** Guest path (like `/repo`) to the root-relative folder of `fs` it shows. */
  preopens: Record<string, string>;
  stdout?: (text: string) => void;
  stderr?: (text: string) => void;
};

export class Wasi {
  memory!: WebAssembly.Memory;
  private fds: (Fd | undefined)[] = [];

  constructor(readonly fs: MemFS, private options: WasiOptions) {
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
      const path = splitPath(host);
      const node = fs.lookup(path);
      if (node?.kind !== "dir") throw new Error(`${host} is not a folder`);
      this.fds.push({ kind: "dir", node, path, preopen: guest });
    }
  }

  /** Runs a command module's `_start`; returns its exit code. */
  start(instance: WebAssembly.Instance): number {
    this.memory = instance.exports.memory as WebAssembly.Memory;
    try {
      (instance.exports._start as () => void)();
      return 0;
    } catch (err) {
      if (err instanceof Exit) return err.code;
      throw err;
    }
  }

  /** Prepares a library (reactor) module, calling `_initialize` if it has one. */
  initialize(instance: WebAssembly.Instance) {
    this.memory = instance.exports.memory as WebAssembly.Memory;
    (instance.exports._initialize as (() => void) | undefined)?.();
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

  /** `fd`'s folder joined with `rel`, with `..` resolved lexically; an error if it leaves the preopen. */
  private resolve(fd: number, ptr: number, len: number): { path: string[] } | { error: number } {
    const dir = this.fds[fd];
    if (!dir) return { error: E.BADF };
    if (dir.kind !== "dir") return { error: E.NOTDIR };
    const rel = this.string(ptr, len);
    if (rel.startsWith("/")) return { error: E.NOTCAPABLE };
    const path = [...dir.path];
    const floor = this.preopenFloor(dir.path);
    for (const part of rel.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") {
        if (path.length <= floor) return { error: E.NOTCAPABLE };
        path.pop();
      } else path.push(part);
    }
    return { path };
  }

  /** Depth of the preopen that contains `path`. */
  private preopenFloor(path: string[]): number {
    let floor = 0;
    for (const fd of this.fds) {
      if (fd?.kind === "dir" && fd.preopen !== undefined && fd.path.every((p, i) => path[i] === p)) {
        floor = Math.max(floor, fd.path.length);
      }
    }
    return floor;
  }

  private filestat(ptr: number, node: MemNode) {
    const v = this.view;
    v.setBigUint64(ptr, 0n, true);
    v.setBigUint64(ptr + 8, node.ino, true);
    v.setUint8(ptr + 16, node.kind === "dir" ? FILETYPE.DIR : FILETYPE.FILE);
    v.setBigUint64(ptr + 24, BigInt(node.kind === "file" ? node.nlink : 1), true);
    v.setBigUint64(ptr + 32, BigInt(node.kind === "file" ? node.size : 0), true);
    v.setBigUint64(ptr + 40, node.mtime, true);
    v.setBigUint64(ptr + 48, node.mtime, true);
    v.setBigUint64(ptr + 56, node.mtime, true);
  }

  private setTimes(node: MemNode, mtim: bigint, flags: number) {
    if (flags & FST.MTIM_NOW) node.mtime = now();
    else if (flags & FST.MTIM) node.mtime = mtim;
  }

  private iovecs(ptr: number, count: number): Uint8Array[] {
    const v = this.view;
    const out: Uint8Array[] = [];
    for (let i = 0; i < count; i++) {
      const buf = v.getUint32(ptr + i * 8, true);
      const len = v.getUint32(ptr + i * 8 + 4, true);
      out.push(new Uint8Array(this.memory.buffer, buf, len));
    }
    return out;
  }

  private readAt(file: MemFile, iovs: number, count: number, at: number): number {
    let read = 0;
    for (const buf of this.iovecs(iovs, count)) {
      const n = Math.max(0, Math.min(buf.length, file.size - at - read));
      buf.set(file.data.subarray(at + read, at + read + n));
      read += n;
      if (n < buf.length) break;
    }
    return read;
  }

  private writeAt(file: MemFile, iovs: number, count: number, at: number): number {
    const chunks = this.iovecs(iovs, count);
    const total = chunks.reduce((n, c) => n + c.length, 0);
    grow(file, at + total);
    let pos = at;
    for (const chunk of chunks) {
      file.data.set(chunk, pos);
      pos += chunk.length;
    }
    file.size = Math.max(file.size, pos);
    file.mtime = now();
    return total;
  }

  get imports(): WebAssembly.ModuleImports {
    const self = this;
    const fs = this.fs;
    const fileFd = (fd: number) => {
      const f = self.fds[fd];
      return f?.kind === "file" ? f : null;
    };
    const imports: Record<string, (...args: any[]) => number | void> = {
      args_sizes_get(argc: number, size: number) {
        const args = self.options.args ?? [];
        self.view.setUint32(argc, args.length, true);
        self.view.setUint32(size, args.reduce((n, a) => n + new TextEncoder().encode(a).length + 1, 0), true);
        return E.SUCCESS;
      },
      args_get(argv: number, buf: number) {
        return writeStrings(self, self.options.args ?? [], argv, buf);
      },
      environ_sizes_get(count: number, size: number) {
        const env = Object.entries(self.options.env ?? {}).map(([k, v]) => `${k}=${v}`);
        self.view.setUint32(count, env.length, true);
        self.view.setUint32(size, env.reduce((n, a) => n + new TextEncoder().encode(a).length + 1, 0), true);
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
        for (let at = 0; at < len; at += 65536) {
          crypto.getRandomValues(new Uint8Array(self.memory.buffer, ptr + at, Math.min(65536, len - at)));
        }
        return E.SUCCESS;
      },
      sched_yield() {
        return E.SUCCESS;
      },
      proc_exit(code: number) {
        throw new Exit(code);
      },
      // Nothing can wait in a worker without shared memory, so timeouts expire at once.
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
        self.view.setUint32(ptr + 4, new TextEncoder().encode(f.preopen).length, true);
        return E.SUCCESS;
      },
      fd_prestat_dir_name(fd: number, ptr: number, len: number) {
        const f = self.fds[fd];
        if (f?.kind !== "dir" || f.preopen === undefined) return E.BADF;
        self.bytes.set(new TextEncoder().encode(f.preopen).subarray(0, len), ptr);
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
      fd_filestat_get(fd: number, ptr: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind === "stdio") {
          self.view.setUint8(ptr + 16, FILETYPE.CHAR);
          return E.SUCCESS;
        }
        self.filestat(ptr, f.node);
        return E.SUCCESS;
      },
      fd_filestat_set_size(fd: number, size: bigint) {
        const f = fileFd(fd);
        if (!f) return E.BADF;
        const n = Number(size);
        grow(f.node, n);
        if (n < f.node.size) f.node.data.fill(0, n, f.node.size);
        f.node.size = n;
        f.node.mtime = now();
        fs.touch(f.path);
        return E.SUCCESS;
      },
      fd_filestat_set_times(fd: number, _atim: bigint, mtim: bigint, flags: number) {
        const f = self.fds[fd];
        if (!f || f.kind === "stdio") return E.BADF;
        self.setTimes(f.node, mtim, flags);
        fs.touch(f.path);
        return E.SUCCESS;
      },
      fd_advise() {
        return E.SUCCESS;
      },
      fd_allocate(fd: number, offset: bigint, len: bigint) {
        const f = fileFd(fd);
        if (!f) return E.BADF;
        const end = Number(offset + len);
        if (end > f.node.size) {
          grow(f.node, end);
          f.node.size = end;
          fs.touch(f.path);
        }
        return E.SUCCESS;
      },
      fd_close(fd: number) {
        if (!self.fds[fd]) return E.BADF;
        self.fds[fd] = undefined;
        return E.SUCCESS;
      },
      fd_sync() {
        return E.SUCCESS;
      },
      fd_datasync() {
        return E.SUCCESS;
      },
      fd_read(fd: number, iovs: number, count: number, nread: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind === "dir") return E.ISDIR;
        if (f.kind === "stdio") {
          self.view.setUint32(nread, 0, true);
          return E.SUCCESS;
        }
        const n = self.readAt(f.node, iovs, count, f.pos);
        f.pos += n;
        self.view.setUint32(nread, n, true);
        return E.SUCCESS;
      },
      fd_pread(fd: number, iovs: number, count: number, offset: bigint, nread: number) {
        const f = fileFd(fd);
        if (!f) return E.BADF;
        self.view.setUint32(nread, self.readAt(f.node, iovs, count, Number(offset)), true);
        return E.SUCCESS;
      },
      fd_write(fd: number, iovs: number, count: number, nwritten: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind === "dir") return E.ISDIR;
        if (f.kind === "stdio") {
          const chunks = self.iovecs(iovs, count);
          const text = chunks.map((c) => new TextDecoder().decode(c)).join("");
          f.write?.(text);
          self.view.setUint32(nwritten, chunks.reduce((n, c) => n + c.length, 0), true);
          return E.SUCCESS;
        }
        if (f.append) f.pos = f.node.size;
        const n = self.writeAt(f.node, iovs, count, f.pos);
        f.pos += n;
        fs.touch(f.path);
        self.view.setUint32(nwritten, n, true);
        return E.SUCCESS;
      },
      fd_pwrite(fd: number, iovs: number, count: number, offset: bigint, nwritten: number) {
        const f = fileFd(fd);
        if (!f) return E.BADF;
        self.view.setUint32(nwritten, self.writeAt(f.node, iovs, count, Number(offset)), true);
        fs.touch(f.path);
        return E.SUCCESS;
      },
      fd_seek(fd: number, offset: bigint, whence: number, ptr: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind !== "file") return f.kind === "dir" ? E.ISDIR : E.SPIPE;
        const base = whence === 0 ? 0 : whence === 1 ? f.pos : f.node.size;
        const pos = base + Number(offset);
        if (pos < 0) return E.INVAL;
        f.pos = pos;
        self.view.setBigUint64(ptr, BigInt(pos), true);
        return E.SUCCESS;
      },
      fd_tell(fd: number, ptr: number) {
        const f = fileFd(fd);
        if (!f) return E.BADF;
        self.view.setBigUint64(ptr, BigInt(f.pos), true);
        return E.SUCCESS;
      },
      fd_readdir(fd: number, buf: number, len: number, cookie: bigint, used: number) {
        const f = self.fds[fd];
        if (!f) return E.BADF;
        if (f.kind !== "dir") return E.NOTDIR;
        const v = self.view;
        const entries = [...f.node.entries];
        let at = 0;
        for (let i = Number(cookie); i < entries.length && at < len; i++) {
          const [name, node] = entries[i];
          const encoded = new TextEncoder().encode(name);
          const header = new Uint8Array(24);
          const hv = new DataView(header.buffer);
          hv.setBigUint64(0, BigInt(i + 1), true);
          hv.setBigUint64(8, node.ino, true);
          hv.setUint32(16, encoded.length, true);
          hv.setUint8(20, node.kind === "dir" ? FILETYPE.DIR : FILETYPE.FILE);
          const entry = new Uint8Array(24 + encoded.length);
          entry.set(header);
          entry.set(encoded, 24);
          // A truncated last entry tells the caller to come back with a bigger buffer.
          const n = Math.min(entry.length, len - at);
          self.bytes.set(entry.subarray(0, n), buf + at);
          at += n;
        }
        v.setUint32(used, at, true);
        return E.SUCCESS;
      },
      fd_renumber(from: number, to: number) {
        if (!self.fds[from]) return E.BADF;
        self.fds[to] = self.fds[from];
        self.fds[from] = undefined;
        return E.SUCCESS;
      },
      path_open(dirfd: number, _lookup: number, ptr: number, len: number, oflags: number, _rb: bigint, _ri: bigint, fdflags: number, out: number) {
        const r = self.resolve(dirfd, ptr, len);
        if ("error" in r) return r.error;
        let node = fs.lookup(r.path);
        if (node && oflags & OFLAGS.CREAT && oflags & OFLAGS.EXCL) return E.EXIST;
        if (!node) {
          if (!(oflags & OFLAGS.CREAT) || r.path.length === 0) return E.NOENT;
          const parent = fs.lookup(r.path.slice(0, -1));
          if (!parent) return E.NOENT;
          if (parent.kind !== "dir") return E.NOTDIR;
          node = memFile(new Uint8Array(0));
          parent.entries.set(r.path[r.path.length - 1], node);
          parent.mtime = now();
          fs.touch(r.path);
        }
        if (oflags & OFLAGS.DIRECTORY && node.kind !== "dir") return E.NOTDIR;
        let fd: Fd;
        if (node.kind === "dir") fd = { kind: "dir", node, path: r.path };
        else {
          if (oflags & OFLAGS.TRUNC && node.size > 0) {
            node.size = 0;
            node.data = new Uint8Array(0);
            node.mtime = now();
            fs.touch(r.path);
          }
          fd = { kind: "file", node, path: r.path, pos: 0, append: (fdflags & FDFLAGS_APPEND) !== 0 };
        }
        let index = self.fds.findIndex((f, i) => i > 2 && !f);
        if (index < 0) index = self.fds.length;
        self.fds[index] = fd;
        self.view.setUint32(out, index, true);
        return E.SUCCESS;
      },
      path_filestat_get(dirfd: number, _flags: number, ptr: number, len: number, buf: number) {
        const r = self.resolve(dirfd, ptr, len);
        if ("error" in r) return r.error;
        const node = fs.lookup(r.path);
        if (!node) return E.NOENT;
        self.filestat(buf, node);
        return E.SUCCESS;
      },
      path_filestat_set_times(dirfd: number, _flags: number, ptr: number, len: number, _atim: bigint, mtim: bigint, flags: number) {
        const r = self.resolve(dirfd, ptr, len);
        if ("error" in r) return r.error;
        const node = fs.lookup(r.path);
        if (!node) return E.NOENT;
        self.setTimes(node, mtim, flags);
        fs.touch(r.path);
        return E.SUCCESS;
      },
      path_create_directory(dirfd: number, ptr: number, len: number) {
        const r = self.resolve(dirfd, ptr, len);
        if ("error" in r) return r.error;
        if (fs.lookup(r.path)) return E.EXIST;
        const parent = fs.lookup(r.path.slice(0, -1));
        if (!parent) return E.NOENT;
        if (parent.kind !== "dir") return E.NOTDIR;
        parent.entries.set(r.path[r.path.length - 1], memDir());
        parent.mtime = now();
        fs.touch(r.path);
        return E.SUCCESS;
      },
      path_remove_directory(dirfd: number, ptr: number, len: number) {
        const r = self.resolve(dirfd, ptr, len);
        if ("error" in r) return r.error;
        const node = fs.lookup(r.path);
        if (!node) return E.NOENT;
        if (node.kind !== "dir") return E.NOTDIR;
        if (node.entries.size) return E.NOTEMPTY;
        if (r.path.length === 0) return E.ACCES;
        const parent = fs.parent(r.path)!;
        parent.entries.delete(r.path[r.path.length - 1]);
        parent.mtime = now();
        fs.touch(r.path);
        return E.SUCCESS;
      },
      path_unlink_file(dirfd: number, ptr: number, len: number) {
        const r = self.resolve(dirfd, ptr, len);
        if ("error" in r) return r.error;
        const node = fs.lookup(r.path);
        if (!node) return E.NOENT;
        if (node.kind === "dir") return E.ISDIR;
        const parent = fs.parent(r.path)!;
        parent.entries.delete(r.path[r.path.length - 1]);
        parent.mtime = now();
        node.nlink--;
        fs.touch(r.path);
        return E.SUCCESS;
      },
      path_rename(fromfd: number, fromptr: number, fromlen: number, tofd: number, toptr: number, tolen: number) {
        const from = self.resolve(fromfd, fromptr, fromlen);
        if ("error" in from) return from.error;
        const to = self.resolve(tofd, toptr, tolen);
        if ("error" in to) return to.error;
        const node = fs.lookup(from.path);
        if (!node || from.path.length === 0) return E.NOENT;
        if (to.path.length === 0) return E.ACCES;
        if (from.path.join("/") === to.path.join("/")) return E.SUCCESS;
        if (node.kind === "dir" && to.path.length > from.path.length && from.path.every((p, i) => to.path[i] === p)) return E.INVAL;
        const target = fs.lookup(to.path);
        const toParent = fs.lookup(to.path.slice(0, -1));
        if (!toParent) return E.NOENT;
        if (toParent.kind !== "dir") return E.NOTDIR;
        if (target) {
          if (node.kind === "dir" && target.kind !== "dir") return E.NOTDIR;
          if (node.kind !== "dir" && target.kind === "dir") return E.ISDIR;
          if (target.kind === "dir" && target.entries.size) return E.NOTEMPTY;
          if (target.kind === "file") target.nlink--;
        }
        const fromParent = fs.parent(from.path)!;
        fromParent.entries.delete(from.path[from.path.length - 1]);
        toParent.entries.set(to.path[to.path.length - 1], node);
        fromParent.mtime = toParent.mtime = now();
        fs.touch(from.path);
        fs.touch(to.path);
        return E.SUCCESS;
      },
      path_link(oldfd: number, _flags: number, oldptr: number, oldlen: number, newfd: number, newptr: number, newlen: number) {
        const from = self.resolve(oldfd, oldptr, oldlen);
        if ("error" in from) return from.error;
        const to = self.resolve(newfd, newptr, newlen);
        if ("error" in to) return to.error;
        const node = fs.lookup(from.path);
        if (!node) return E.NOENT;
        if (node.kind === "dir") return E.NOTSUP;
        if (fs.lookup(to.path)) return E.EXIST;
        const parent = fs.lookup(to.path.slice(0, -1));
        if (!parent) return E.NOENT;
        if (parent.kind !== "dir") return E.NOTDIR;
        parent.entries.set(to.path[to.path.length - 1], node);
        node.nlink++;
        fs.touch(to.path);
        return E.SUCCESS;
      },
      path_readlink(dirfd: number, ptr: number, len: number) {
        const r = self.resolve(dirfd, ptr, len);
        if ("error" in r) return r.error;
        return fs.lookup(r.path) ? E.INVAL : E.NOENT;
      },
      path_symlink() {
        return E.NOTSUP;
      },
    };
    // Anything else the module imports fails as unsupported instead of failing instantiation.
    return new Proxy(imports, {
      get: (target, name: string) => target[name] ?? (() => E.NOSYS),
    }) as WebAssembly.ModuleImports;
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
