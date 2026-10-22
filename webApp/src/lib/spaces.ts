// A space is a folder under `spaces/` in origin storage; the sidebar keeps them in the user's order.
import { strToU8, unzipSync, zipSync } from "fflate";
import { createStore } from "solid-js/store";
import * as core from "./core";
import { spaceOrderAdd, spaceOrderMove, spaceOrderReplace } from "./core";
import * as fs from "./storage";

export const SPACES = "spaces";
const ORDER = "typewright.spaceOrder";

export const [spaces, setSpaces] = createStore({ names: [] as string[], loaded: false });

export function spacePath(name: string, rel = ""): string {
  return fs.join(SPACES, name, rel);
}

function storedOrder(): string[] {
  try {
    return JSON.parse(localStorage.getItem(ORDER) ?? "[]");
  } catch {
    return [];
  }
}

function saveOrder(order: string[]) {
  localStorage.setItem(ORDER, JSON.stringify(order));
}

export async function refreshSpaces() {
  // `.jj` is the history repository's own folder (see jj.ts).
  const folders = (await fs.list(SPACES)).filter((e) => e.kind === "dir" && !fs.basename(e.path).startsWith(".")).map((e) => fs.basename(e.path));
  let order = storedOrder();
  for (const name of folders.sort((a, b) => a.localeCompare(b))) order = spaceOrderAdd(order, name);
  saveOrder(order);
  setSpaces({ names: order.filter((n) => folders.includes(n)), loaded: true });
}

export function moveSpace(name: string, index: number) {
  const order = spaceOrderMove(storedOrder(), spaces.names, name, index);
  saveOrder(order);
  setSpaces("names", order.filter((n) => spaces.names.includes(n)));
}

/** A free folder name in `parent`: `name`, then `name 2` and so on. */
export async function uniqueName(parent: string, name: string, ext: string | null = null): Promise<string> {
  const taken = new Set((await fs.list(parent)).map((e) => fs.basename(e.path)));
  return core.uniqueName(name, ext, (candidate) => taken.has(candidate));
}

export function cleanName(name: string): string {
  return name.replace(/[/\\:\0]/g, "-").trim().replace(/^\.+/, "");
}

const TEMPLATE = `#set page(paper: "a4")
#set text(lang: "en")

= Hello, Typst

Start writing here.
`;

/** Creates a space folder with a `main.typ`, unless files are about to fill it. */
export async function createSpace(name: string, withTemplate = true): Promise<string> {
  const folder = await uniqueName(SPACES, cleanName(name) || "Untitled Space");
  await fs.makeDirectory(spacePath(folder));
  if (withTemplate) await fs.writeFile(spacePath(folder, "main.typ"), TEMPLATE);
  await refreshSpaces();
  return folder;
}

export async function renameSpace(old: string, name: string): Promise<string | null> {
  const clean = cleanName(name);
  if (!clean || clean === old || (await fs.exists(spacePath(clean)))) return null;
  await fs.move(spacePath(old), spacePath(clean));
  saveOrder(spaceOrderReplace(storedOrder(), old, clean));
  await refreshSpaces();
  return clean;
}

export async function deleteSpace(name: string) {
  await fs.remove(spacePath(name));
  saveOrder(storedOrder().filter((n) => n !== name));
  await refreshSpaces();
}

/** Files picked or dropped, with paths relative to the folder they go into. */
export type Incoming = { path: string; file: Blob };

export async function importFiles(space: string, folder: string, files: Incoming[]) {
  for (const { path, file } of files) {
    const target = spacePath(space, fs.join(folder, path));
    await fs.writeFile(target, new Uint8Array(await file.arrayBuffer()));
  }
}

/** Files of a zip archive; a single top folder is dropped, as archives of a folder have one. */
export function unzip(bytes: Uint8Array): Incoming[] {
  const entries = Object.entries(unzipSync(bytes)).filter(([path]) => !path.endsWith("/") && !path.startsWith("__MACOSX/"));
  const tops = new Set(entries.map(([path]) => path.split("/")[0]));
  const strip = tops.size === 1 && entries.every(([path]) => path.includes("/"));
  return entries.map(([path, data]) => ({
    path: strip ? path.slice(path.indexOf("/") + 1) : path,
    file: new Blob([data as Uint8Array<ArrayBuffer>]),
  }));
}

export async function zipSpace(name: string): Promise<Uint8Array> {
  const files: Record<string, Uint8Array> = {};
  for (const entry of await fs.walk(spacePath(name))) {
    if (entry.kind === "dir") continue;
    files[`${name}/${entry.path}`] = (await fs.readFile(spacePath(name, entry.path))) ?? strToU8("");
  }
  return zipSync(files);
}

export function download(name: string, data: Uint8Array | Blob, type = "application/octet-stream") {
  const blob = data instanceof Blob ? data : new Blob([data as Uint8Array<ArrayBuffer>], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}
