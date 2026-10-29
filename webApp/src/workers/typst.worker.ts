// Hosts the typst compiler (`typstBridge` built for wasm) off the main thread. Packages a compile asks
// for come from origin storage (`packages/<namespace>/<name>/<version>/`) or Typst Universe.
import { acceptDiskWorker, libraryFolder, storageRoot } from "~/lib/disk";
import init, * as typst from "~/wasm/typst/typst.js";
import wasmUrl from "~/wasm/typst/typst_bg.wasm?url";

export type Request = { id: number; op: string; [key: string]: unknown };

let compiler: typst.Compiler | undefined;
const ready = init({ module_or_path: wasmUrl }).then(() => {
  compiler = new typst.Compiler();
});

const UNIVERSE = "https://packages.typst.org";
/** Packages that failed to load, so every keystroke doesn't fetch them again. */
const failed = new Map<string, string>();
const loaded = new Set<string>();

function parseSpec(spec: string): { namespace: string; name: string; version: string } | null {
  const match = /^@([a-z0-9_-]+)\/([a-zA-Z0-9_-]+):(\d+\.\d+\.\d+)$/.exec(spec);
  return match ? { namespace: match[1], name: match[2], version: match[3] } : null;
}

async function directory(path: string[], create: boolean): Promise<FileSystemDirectoryHandle | null> {
  let dir = await storageRoot();
  for (const part of path) {
    try {
      dir = await dir.getDirectoryHandle(part, { create });
    } catch {
      return null;
    }
  }
  return dir;
}

async function readTree(dir: FileSystemDirectoryHandle, prefix = ""): Promise<[string, Uint8Array][]> {
  const out: [string, Uint8Array][] = [];
  for await (const [name, handle] of dir.entries()) {
    const path = prefix ? `${prefix}/${name}` : name;
    if (handle.kind === "directory") out.push(...(await readTree(handle as FileSystemDirectoryHandle, path)));
    else out.push([path, new Uint8Array(await (await (handle as FileSystemFileHandle).getFile()).arrayBuffer())]);
  }
  return out;
}

async function writeTree(dir: FileSystemDirectoryHandle, files: [string, Uint8Array][]) {
  for (const [path, bytes] of files) {
    const parts = path.split("/").filter(Boolean);
    const name = parts.pop()!;
    let parent = dir;
    for (const part of parts) parent = await parent.getDirectoryHandle(part, { create: true });
    const writable = await (await parent.getFileHandle(name, { create: true })).createWritable();
    await writable.write(bytes as Uint8Array<ArrayBuffer>);
    await writable.close();
  }
}

/** Files of a tar archive; handles ustar prefixes and pax and GNU long names. */
export function untar(data: Uint8Array): [string, Uint8Array][] {
  const files: [string, Uint8Array][] = [];
  const text = (from: number, length: number) => {
    const bytes = data.subarray(from, from + length);
    const end = bytes.indexOf(0);
    return new TextDecoder().decode(end < 0 ? bytes : bytes.subarray(0, end));
  };
  let offset = 0;
  let longName: string | null = null;
  while (offset + 512 <= data.length) {
    if (data.subarray(offset, offset + 512).every((b) => b === 0)) break;
    const size = parseInt(text(offset + 124, 12).trim() || "0", 8);
    const type = String.fromCharCode(data[offset + 156] || 48);
    const prefix = text(offset + 257, 6).startsWith("ustar") ? text(offset + 345, 155) : "";
    let name = prefix ? `${prefix}/${text(offset, 100)}` : text(offset, 100);
    const body = data.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
    if (type === "x") {
      const path = /\d+ path=([^\n]*)\n/.exec(new TextDecoder().decode(body));
      if (path) longName = path[1];
      continue;
    }
    if (type === "L") {
      longName = new TextDecoder().decode(body).replace(/\0.*$/s, "");
      continue;
    }
    if (longName) {
      name = longName;
      longName = null;
    }
    if (type === "0" || type === "\0" || type === "7") files.push([name.replace(/^\.\//, ""), body.slice()]);
  }
  return files;
}

/** Loads a package into the compiler, downloading `@preview` ones once. */
async function obtain(spec: string): Promise<void> {
  if (loaded.has(spec)) return;
  const parsed = parseSpec(spec);
  if (!parsed) throw new Error(`invalid package spec ${spec}`);
  const path = ["packages", parsed.namespace, parsed.name, parsed.version];
  let files: [string, Uint8Array][] = [];
  const cached = await directory(path, false);
  if (cached) files = await readTree(cached);
  if (files.length === 0) {
    if (parsed.namespace !== "preview") throw new Error(`package ${spec} isn't installed`);
    const response = await fetch(`${UNIVERSE}/preview/${parsed.name}-${parsed.version}.tar.gz`);
    if (!response.ok) throw new Error(response.status === 404 ? `package ${spec} doesn't exist` : `downloading ${spec} failed (${response.status})`);
    const tar = new Uint8Array(await new Response(response.body!.pipeThrough(new DecompressionStream("gzip"))).arrayBuffer());
    files = untar(tar);
    await writeTree((await directory(path, true))!, files);
  }
  for (const [file, bytes] of files) compiler!.addPackageFile(spec, file, bytes);
  compiler!.finishPackage(spec);
  loaded.add(spec);
}

let compiles: Promise<unknown> = Promise.resolve();

/** Splits the bridge's `svg_page_updates`: per page its hash, and its SVG when the last compile didn't send it. */
function svgUpdates(data: Uint8Array): { key: string; svg: string | null }[] {
  const pages: { key: string; svg: string | null }[] = [];
  const decoder = new TextDecoder();
  let start = 0;
  for (let i = 0; i <= data.length; i++) {
    if (i < data.length && data[i] !== 0) continue;
    const key = decoder.decode(data.subarray(start, start + 32));
    pages.push({ key, svg: i > start + 32 ? decoder.decode(data.subarray(start + 32, i)) : null });
    start = i + 1;
  }
  return pages;
}

async function compile(main: string, format: number) {
  if (libraryFolder()) {
    for (const spec of [...loaded].filter(s => !s.startsWith("@preview/"))) {
      loaded.delete(spec);
      await obtain(spec).catch(error => failed.set(spec, String(error)));
    }
  }
  compiler!.setMain(main);
  const started = performance.now();
  // Each round can reveal imports of the packages loaded in the one before.
  for (let round = 0; ; round++) {
    const result = compiler!.compile(format);
    const missing = result.missing.filter((spec) => !failed.has(spec));
    if (missing.length === 0 || round >= 8) {
      const errors = result.missing.flatMap((spec) => (failed.has(spec) ? [failed.get(spec)!] : []));
      const data = result.data ?? null;
      // SVG updates are decoded here, so the page thread only gets the changed pages' text.
      const pages = format === 2 && data ? svgUpdates(data) : null;
      return { data: pages ? null : data, pages, diagnostics: result.diagnostics, packageErrors: errors, duration: performance.now() - started, solveng: result.solveng };
    }
    await Promise.all(
      missing.map((spec) =>
        obtain(spec).catch((err: Error) => {
          failed.set(spec, err.message);
        }),
      ),
    );
  }
}

let index: string | null = null;

async function packageIndex(): Promise<string> {
  if (index) return index;
  const response = await fetch(`${UNIVERSE}/preview/index.json`);
  index = await response.text();
  compiler!.setPackageIndex(index);
  return index;
}

/** Lists the packages in origin storage as specs. */
async function installedPackages(): Promise<string[]> {
  const root = await directory(["packages"], false);
  if (!root) return [];
  const specs: string[] = [];
  for await (const [namespace, ns] of root.entries()) {
    if (ns.kind !== "directory") continue;
    for await (const [name, pkg] of (ns as FileSystemDirectoryHandle).entries()) {
      if (pkg.kind !== "directory") continue;
      for await (const [version] of (pkg as FileSystemDirectoryHandle).entries()) specs.push(`@${namespace}/${name}:${version}`);
    }
  }
  return specs.sort();
}

async function handle(request: Request): Promise<unknown> {
  await ready;
  const c = compiler!;
  const r = request as Record<string, any>;
  switch (request.op) {
    case "version":
      return typst.Compiler.version();
    case "clear":
      c.clearFiles();
      return null;
    case "setFile":
      c.setFile(r.path, r.bytes);
      return null;
    case "setText":
      c.setText(r.path, r.text);
      return null;
    case "resetSvg":
      c.resetSvg();
      return null;
    case "removeFile":
      c.removeFile(r.path);
      return null;
    case "setFonts":
      return c.setFonts(r.files);
    case "fontFamilies":
      return c.fontFamilies();
    case "fontFaces":
      return JSON.parse(c.fontFaces());
    case "compile": {
      // One at a time: a compile waiting for packages would otherwise see another's main file.
      const run = compiles.then(() => compile(r.main, r.format));
      compiles = run.catch(() => {});
      return run;
    }
    case "complete":
      return JSON.parse(c.complete(r.path, r.cursor, r.explicit));
    case "tooltip":
      return JSON.parse(c.tooltip(r.path, r.cursor));
    case "definition":
      return JSON.parse(c.definition(r.path, r.cursor));
    case "jumpFromClick":
      return JSON.parse(c.jumpFromClick(r.page, r.x, r.y));
    case "jumpFromCursor":
      return JSON.parse(c.jumpFromCursor(r.path, r.cursor));
    case "highlight":
      return typst.highlight(r.text, r.code);
    case "solveng":
      return JSON.parse(typst.solveng(r.action, r.document, r.context, r.offset));
    case "refactor":
      return JSON.parse(typst.refactor(JSON.stringify(r.request)));
    case "markdown":
      return typst.markdownHtml(r.text);
    case "markdownCss":
      return typst.markdownCodeCss();
    case "packageIndex":
      return packageIndex();
    case "installedPackages":
      return installedPackages();
    case "downloadPackage":
      failed.delete(r.spec);
      loaded.delete(r.spec);
      await obtain(r.spec);
      return r.spec;
    case "removePackage": {
      const parsed = parseSpec(r.spec);
      if (!parsed) return null;
      const dir = await directory(["packages", parsed.namespace, parsed.name], false);
      await dir?.removeEntry(parsed.version, { recursive: true }).catch(() => {});
      loaded.delete(r.spec);
      return null;
    }
    case "retryPackages":
      failed.clear();
      return null;
    default:
      throw new Error(`unknown op ${request.op}`);
  }
}

self.onmessage = async (event: MessageEvent<Request>) => {
  if (acceptDiskWorker(event.data)) return;
  const request = event.data;
  try {
    const value = await handle(request);
    const data = (value as { data?: unknown } | null)?.data;
    const transfer = value instanceof Uint32Array ? [value.buffer] : data instanceof Uint8Array ? [data.buffer] : [];
    (self as unknown as Worker).postMessage({ id: request.id, ok: true, value }, transfer);
  } catch (err) {
    // A trap leaves the module unusable; the page starts a fresh worker.
    const fatal = err instanceof WebAssembly.RuntimeError;
    (self as unknown as Worker).postMessage({ id: request.id, ok: false, error: String((err as Error)?.message ?? err), fatal });
  }
};
