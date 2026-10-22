// An in-memory stand-in for the origin private file system, for tests and benchmarks outside a browser. It keeps
// the rules the jj host depends on, as Chromium 156 behaves: a sync access handle locks its file (moves, removals
// and other handles fail with NoModificationAllowedError, getFile works), file moves replace their target, folders
// don't move, and same-size writes leave lastModified alone.

function domError(name: string): DOMException {
  return new DOMException(name, name);
}

type Entry = FakeFile | FakeDir;

class FakeFile {
  data = new Uint8Array(0);
  lastModified = Date.now();
  locked = false;
}

class FakeDir {
  entries = new Map<string, Entry>();
}

class FakeSyncAccessHandle {
  private closed = false;
  constructor(private file: FakeFile) {}

  private check() {
    if (this.closed) throw domError("InvalidStateError");
  }

  getSize() {
    this.check();
    return this.file.data.length;
  }

  read(buf: Uint8Array, opts: { at?: number } = {}) {
    this.check();
    const at = opts.at ?? 0;
    const n = Math.max(0, Math.min(buf.length, this.file.data.length - at));
    buf.set(this.file.data.subarray(at, at + n));
    return n;
  }

  write(buf: Uint8Array, opts: { at?: number } = {}) {
    this.check();
    const at = opts.at ?? 0;
    const sizeBefore = this.file.data.length;
    if (at + buf.length > this.file.data.length) {
      const grown = new Uint8Array(at + buf.length);
      grown.set(this.file.data);
      this.file.data = grown;
    }
    this.file.data.set(buf, at);
    if (this.file.data.length !== sizeBefore) this.file.lastModified = Date.now();
    return buf.length;
  }

  truncate(size: number) {
    this.check();
    const data = new Uint8Array(size);
    data.set(this.file.data.subarray(0, size));
    if (size !== this.file.data.length) this.file.lastModified = Date.now();
    this.file.data = data;
  }

  flush() {
    this.check();
  }

  close() {
    if (!this.closed) this.file.locked = false;
    this.closed = true;
  }
}

class FakeFileHandle {
  readonly kind = "file";
  constructor(readonly name: string, private parent: FakeDir, private file: FakeFile) {}

  async getFile(): Promise<File> {
    const data = this.file.data.slice();
    return new File([data], this.name, { lastModified: this.file.lastModified });
  }

  async createSyncAccessHandle() {
    if (this.file.locked) throw domError("NoModificationAllowedError");
    this.file.locked = true;
    return new FakeSyncAccessHandle(this.file);
  }

  async createWritable() {
    if (this.file.locked) throw domError("NoModificationAllowedError");
    const file = this.file;
    let data = new Uint8Array(0);
    return {
      async write(chunk: Uint8Array | string) {
        const bytes = typeof chunk === "string" ? new TextEncoder().encode(chunk) : chunk;
        const next = new Uint8Array(data.length + bytes.length);
        next.set(data);
        next.set(bytes, data.length);
        data = next;
      },
      async close() {
        file.data = data;
        file.lastModified = Date.now();
      },
    };
  }

  async move(dir: FakeDirectoryHandle, name: string) {
    if (this.file.locked) throw domError("NoModificationAllowedError");
    const target = dir.dir.entries.get(name);
    if (target instanceof FakeDir) throw domError("InvalidModificationError");
    if (target instanceof FakeFile && target.locked) throw domError("NoModificationAllowedError");
    if (this.parent.entries.get(this.name) === this.file) this.parent.entries.delete(this.name);
    dir.dir.entries.set(name, this.file);
  }
}

export class FakeDirectoryHandle {
  readonly kind = "directory";
  constructor(readonly name: string, readonly dir: FakeDir = new FakeDir()) {}

  async getDirectoryHandle(name: string, opts: { create?: boolean } = {}) {
    let entry = this.dir.entries.get(name);
    if (entry instanceof FakeFile) throw domError("TypeMismatchError");
    if (!entry) {
      if (!opts.create) throw domError("NotFoundError");
      entry = new FakeDir();
      this.dir.entries.set(name, entry);
    }
    return new FakeDirectoryHandle(name, entry);
  }

  async getFileHandle(name: string, opts: { create?: boolean } = {}) {
    let entry = this.dir.entries.get(name);
    if (entry instanceof FakeDir) throw domError("TypeMismatchError");
    if (!entry) {
      if (!opts.create) throw domError("NotFoundError");
      entry = new FakeFile();
      this.dir.entries.set(name, entry);
    }
    return new FakeFileHandle(name, this.dir, entry);
  }

  async removeEntry(name: string, opts: { recursive?: boolean } = {}) {
    const entry = this.dir.entries.get(name);
    if (!entry) throw domError("NotFoundError");
    if (entry instanceof FakeDir && entry.entries.size && !opts.recursive) throw domError("InvalidModificationError");
    if (locked(entry)) throw domError("NoModificationAllowedError");
    this.dir.entries.delete(name);
  }

  async *entries(): AsyncIterableIterator<[string, FakeFileHandle | FakeDirectoryHandle]> {
    for (const [name, entry] of [...this.dir.entries]) {
      yield [name, entry instanceof FakeDir ? new FakeDirectoryHandle(name, entry) : new FakeFileHandle(name, this.dir, entry)];
    }
  }

  async move() {
    throw new TypeError("folders can't move");
  }
}

function locked(entry: Entry): boolean {
  return entry instanceof FakeFile ? entry.locked : [...entry.entries.values()].some(locked);
}

/** A fresh fake OPFS root, typed as the real one. */
export function fakeOpfs(): FileSystemDirectoryHandle {
  return new FakeDirectoryHandle("") as unknown as FileSystemDirectoryHandle;
}
