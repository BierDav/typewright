import { expect, test } from "bun:test";
import { contents, MemFS, memDir, Wasi } from "./wasi";

// Drives the host's imports directly against a scratch memory, like a module would.
function host() {
  const fs = new MemFS();
  fs.put("work", memDir());
  const wasi = new Wasi(fs, { preopens: { "/work": "work" } });
  wasi.memory = new WebAssembly.Memory({ initial: 1 });
  const imports = wasi.imports as Record<string, (...args: any[]) => number>;
  const mem = () => new DataView(wasi.memory.buffer);
  let heap = 1024;
  const str = (s: string): [number, number] => {
    const bytes = new TextEncoder().encode(s);
    new Uint8Array(wasi.memory.buffer).set(bytes, heap);
    const at = heap;
    heap += bytes.length + 8;
    return [at, bytes.length];
  };
  const preopen = 3;
  const open = (path: string, oflags = 0) => {
    const out = heap;
    heap += 8;
    const errno = imports.path_open(preopen, 0, ...str(path), oflags, 0n, 0n, 0, out);
    return { errno, fd: mem().getUint32(out, true) };
  };
  const write = (fd: number, text: string) => {
    const [ptr, len] = str(text);
    const iov = heap;
    heap += 16;
    mem().setUint32(iov, ptr, true);
    mem().setUint32(iov + 4, len, true);
    return imports.fd_write(fd, iov, 1, heap + 32);
  };
  const mtime = (path: string) => {
    const buf = heap;
    heap += 64;
    expect(imports.path_filestat_get(preopen, 0, ...str(path), buf)).toBe(0);
    return mem().getBigUint64(buf + 48, true);
  };
  return { fs, imports, str, open, write, mtime, preopen };
}

test("writes create files and mark them dirty", () => {
  const h = host();
  const { errno, fd } = h.open("a.txt", 1);
  expect(errno).toBe(0);
  expect(h.write(fd, "hello")).toBe(0);
  const node = h.fs.lookup(["work", "a.txt"]);
  expect(node?.kind).toBe("file");
  expect(new TextDecoder().decode(contents(node as any))).toBe("hello");
  expect(h.fs.takeDirty()).toEqual(["work/a.txt"]);
});

test("a same-size rewrite still moves the mtime", () => {
  const h = host();
  h.write(h.open("a.txt", 1).fd, "aaaa");
  const before = h.mtime("a.txt");
  h.write(h.open("a.txt", 8).fd, "bbbb");
  expect(h.mtime("a.txt")).toBeGreaterThan(before);
});

test("rename replaces the target, like an atomic save", () => {
  const h = host();
  h.write(h.open("target", 1).fd, "old");
  h.write(h.open("tmp", 1).fd, "new");
  h.fs.takeDirty();
  expect(h.imports.path_rename(h.preopen, ...h.str("tmp"), h.preopen, ...h.str("target"))).toBe(0);
  expect(h.fs.lookup(["work", "tmp"])).toBeNull();
  expect(new TextDecoder().decode(contents(h.fs.lookup(["work", "target"]) as any))).toBe("new");
  expect(h.fs.takeDirty().sort()).toEqual(["work/target", "work/tmp"]);
});

test("paths can't leave the preopened folder", () => {
  const h = host();
  expect(h.open("../escape", 1).errno).toBe(76);
  // `..` is resolved lexically, so it works through folders that don't exist.
  expect(h.open("dir/../../escape", 1).errno).toBe(76);
  expect(h.open("dir/../ok", 1).errno).toBe(0);
});

test("hard links share content until one is unlinked", () => {
  const h = host();
  h.write(h.open("a", 1).fd, "x");
  expect(h.imports.path_link(h.preopen, 0, ...h.str("a"), h.preopen, ...h.str("b"))).toBe(0);
  expect(h.fs.lookup(["work", "b"])).toBe(h.fs.lookup(["work", "a"]));
  expect(h.imports.path_unlink_file(h.preopen, ...h.str("a"))).toBe(0);
  expect(h.fs.lookup(["work", "b"])?.kind).toBe("file");
});
