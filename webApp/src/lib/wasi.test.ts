import { expect, test } from "bun:test";
import { fakeOpfs } from "./fakeOpfs";
import { type HostState, OpfsFS, type OpfsOptions, Wasi } from "./wasi";

const RIGHTS_WRITE = 1n << 6n;
const CREAT = 1;
const EXCL = 4;
const TRUNC = 8;

// Drives the host's raw imports against a scratch memory, like a module would.
function host(root = fakeOpfs(), options: OpfsOptions = {}) {
  const fs = new OpfsFS(root, options);
  const wasi = new Wasi(fs, { preopens: { "/work": "" } });
  wasi.memory = new WebAssembly.Memory({ initial: 64 });
  const imports = wasi.raw as Record<string, (...args: any[]) => any>;
  const mem = () => new DataView(wasi.memory.buffer);
  let heap = 1024;
  const alloc = (n: number) => {
    const at = heap;
    heap += n + 8;
    return at;
  };
  const str = (s: string): [number, number] => {
    const bytes = new TextEncoder().encode(s);
    const at = alloc(bytes.length);
    new Uint8Array(wasi.memory.buffer).set(bytes, at);
    return [at, bytes.length];
  };
  const preopen = 3;
  const open = async (path: string, oflags = 0, rights = 0n) => {
    const out = alloc(4);
    const errno = await imports.path_open(preopen, 0, ...str(path), oflags, rights, 0n, 0, out);
    return { errno, fd: mem().getUint32(out, true) };
  };
  const iov = (ptr: number, len: number) => {
    const at = alloc(8);
    mem().setUint32(at, ptr, true);
    mem().setUint32(at + 4, len, true);
    return at;
  };
  const write = async (fd: number, text: string) => imports.fd_write(fd, iov(...str(text)), 1, alloc(4));
  const read = async (fd: number) => {
    const buf = alloc(4096);
    const n = alloc(4);
    expect(await imports.fd_read(fd, iov(buf, 4096), 1, n)).toBe(0);
    return new TextDecoder().decode(new Uint8Array(wasi.memory.buffer, buf, mem().getUint32(n, true)));
  };
  const create = async (path: string, text: string) => {
    const { errno, fd } = await open(path, CREAT | TRUNC, RIGHTS_WRITE);
    expect(errno).toBe(0);
    expect(await write(fd, text)).toBe(0);
    expect(await imports.fd_close(fd)).toBe(0);
  };
  const cat = async (path: string) => {
    const { errno, fd } = await open(path);
    if (errno) return `errno ${errno}`;
    const text = await read(fd);
    await imports.fd_close(fd);
    return text;
  };
  const mtime = async (path: string) => {
    const buf = alloc(64);
    expect(await imports.path_filestat_get(preopen, 0, ...str(path), buf)).toBe(0);
    return mem().getBigUint64(buf + 48, true);
  };
  return { root, fs, imports, str, open, write, read, create, cat, mtime, preopen };
}

async function opfsText(root: FileSystemDirectoryHandle, path: string) {
  const parts = path.split("/");
  let dir = root;
  for (const part of parts.slice(0, -1)) dir = await dir.getDirectoryHandle(part);
  return (await (await dir.getFileHandle(parts[parts.length - 1])).getFile()).text();
}

test("writes go straight to OPFS", async () => {
  const h = host();
  await h.create("a.txt", "hello");
  expect(await opfsText(h.root, "a.txt")).toBe("hello");
  expect(await h.cat("a.txt")).toBe("hello");
  expect(h.fs.takeWritten()).toEqual(["a.txt"]);
});

test("a same-size rewrite still moves the mtime", async () => {
  const h = host();
  await h.create("a.txt", "aaaa");
  const before = await h.mtime("a.txt");
  await h.create("a.txt", "bbbb");
  expect(await h.mtime("a.txt")).toBeGreaterThan(before);
});

test("mtimes survive a restart, and files changed meanwhile get new ones", async () => {
  const h = host();
  await h.create("same.txt", "1111");
  await h.create("edited.txt", "2222");
  const same = await h.mtime("same.txt");
  const edited = await h.mtime("edited.txt");
  const state = JSON.parse(JSON.stringify(h.fs.state())) as HostState;
  // The editor rewrites edited.txt with the same size; the change is announced as stale.
  const handle = await h.root.getFileHandle("edited.txt");
  const writable = await handle.createWritable();
  await writable.write("3333");
  await writable.close();
  const next = host(h.root, { state, stale: ["edited.txt"] });
  expect(await next.mtime("same.txt")).toBe(same);
  expect(await next.mtime("edited.txt")).toBeGreaterThan(edited);
});

test("a folder marked stale refreshes its files once", async () => {
  const h = host();
  expect(await h.imports.path_create_directory(h.preopen, ...h.str("Space"))).toBe(0);
  await h.create("Space/a.typ", "x");
  const first = await h.mtime("Space/a.typ");
  h.fs.invalidate(["Space"]);
  const second = await h.mtime("Space/a.typ");
  expect(second).toBeGreaterThan(first);
  const next = host(h.root, { state: JSON.parse(JSON.stringify(h.fs.state())) });
  expect(await next.mtime("Space/a.typ")).toBe(second);
});

test("a temp file renamed while open replaces its target, like an atomic save", async () => {
  const h = host();
  await h.create("target", "old");
  const { fd } = await h.open("tmp", CREAT | EXCL, RIGHTS_WRITE);
  await h.write(fd, "new");
  expect(await h.imports.path_rename(h.preopen, ...h.str("tmp"), h.preopen, ...h.str("target"))).toBe(0);
  await h.write(fd, "er");
  expect(await h.imports.fd_close(fd)).toBe(0);
  expect(await opfsText(h.root, "target")).toBe("newer");
  expect(await h.cat("tmp")).toBe("errno 44");
});

test("reading a file renamed over a cached one gives the new bytes", async () => {
  // jj saves its working-copy state like this; stale bytes made every call look like a stale working copy.
  const h = host();
  await h.create("state", "op 1");
  expect(await h.cat("state")).toBe("op 1");
  await h.create("state.tmp", "op 2");
  expect(await h.imports.path_rename(h.preopen, ...h.str("state.tmp"), h.preopen, ...h.str("state"))).toBe(0);
  expect(await h.cat("state")).toBe("op 2");
});

test("a lock held elsewhere is waited out", async () => {
  const h = host();
  await h.create("busy", "x");
  const outside = await (await h.root.getFileHandle("busy")).createSyncAccessHandle();
  setTimeout(() => outside.close(), 30);
  const { errno, fd } = await h.open("busy", TRUNC, RIGHTS_WRITE);
  expect(errno).toBe(0);
  await h.write(fd, "mine");
  await h.imports.fd_close(fd);
  expect(await opfsText(h.root, "busy")).toBe("mine");
});

test("folders move by copying", async () => {
  const h = host();
  await h.imports.path_create_directory(h.preopen, ...h.str("d1"));
  await h.create("d1/f", "inside");
  expect(await h.imports.path_rename(h.preopen, ...h.str("d1"), h.preopen, ...h.str("d2"))).toBe(0);
  expect(await h.cat("d2/f")).toBe("inside");
  expect(await h.cat("d1/f")).toBe("errno 44");
});

test("hard links are copies that refuse to replace", async () => {
  const h = host();
  await h.create("a", "x");
  await h.create("c", "y");
  expect(await h.imports.path_link(h.preopen, 0, ...h.str("a"), h.preopen, ...h.str("b"))).toBe(0);
  expect(await h.imports.path_link(h.preopen, 0, ...h.str("a"), h.preopen, ...h.str("c"))).toBe(20);
  expect(await h.cat("b")).toBe("x");
});

test("paths can't leave the preopened folder", async () => {
  const h = host();
  expect((await h.open("../escape", CREAT, RIGHTS_WRITE)).errno).toBe(76);
  // `..` is resolved lexically, so it works through folders that don't exist.
  expect((await h.open("dir/../../escape", CREAT, RIGHTS_WRITE)).errno).toBe(76);
  expect((await h.open("dir/../ok", CREAT, RIGHTS_WRITE)).errno).toBe(0);
});

test("cached contents stay under the cap", async () => {
  const h = host(fakeOpfs(), { cacheBytes: 10_000 });
  for (let i = 0; i < 50; i++) await h.create(`f${i}`, "x".repeat(1000));
  for (let i = 0; i < 50; i++) expect(await h.cat(`f${i}`)).toHaveLength(1000);
  expect(h.fs.cachedBytes).toBeLessThanOrEqual(10_000);
});
