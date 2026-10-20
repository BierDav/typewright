// Files from drops and file pickers, with paths relative to what was dropped or picked.
import type { Incoming } from "./spaces";

function readEntry(entry: FileSystemEntry, prefix: string): Promise<Incoming[]> {
  const path = prefix ? `${prefix}/${entry.name}` : entry.name;
  if (entry.isFile) {
    return new Promise((resolve) => (entry as FileSystemFileEntry).file((file) => resolve([{ path, file }]), () => resolve([])));
  }
  const reader = (entry as FileSystemDirectoryEntry).createReader();
  return new Promise((resolve) => {
    const all: FileSystemEntry[] = [];
    // Directory readers return their entries in batches.
    const next = () =>
      reader.readEntries(async (batch) => {
        if (batch.length) {
          all.push(...batch);
          next();
        } else {
          resolve((await Promise.all(all.map((e) => readEntry(e, path)))).flat());
        }
      }, () => resolve([]));
    next();
  });
}

/** Files of a drop, folders included; hidden system files like `.DS_Store` stay out. */
export async function readDrop(data: DataTransfer): Promise<Incoming[]> {
  const entries = [...data.items].map((item) => item.webkitGetAsEntry?.()).filter((e): e is FileSystemEntry => !!e);
  const files = entries.length ? (await Promise.all(entries.map((e) => readEntry(e, "")))).flat() : [...data.files].map((file) => ({ path: file.name, file }));
  return files.filter((f) => !f.path.split("/").some((p) => p === ".DS_Store" || p === "__MACOSX"));
}

/** Opens the file picker; `directory` picks a whole folder. */
export function pickFiles(options: { directory?: boolean; accept?: string; multiple?: boolean } = {}): Promise<Incoming[]> {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.multiple = options.multiple ?? true;
    if (options.accept) input.accept = options.accept;
    if (options.directory) input.webkitdirectory = true;
    input.addEventListener("change", () => {
      const files = [...(input.files ?? [])].map((file) => ({ path: file.webkitRelativePath || file.name, file }));
      resolve(files.filter((f) => !f.path.split("/").some((p) => p === ".DS_Store")));
    });
    input.addEventListener("cancel", () => resolve([]));
    input.click();
  });
}

/** Drops paths below the single folder that was picked, as folder pickers include it. */
export function stripTopFolder(files: Incoming[]): { name: string | null; files: Incoming[] } {
  const tops = new Set(files.map((f) => f.path.split("/")[0]));
  if (tops.size !== 1 || !files.every((f) => f.path.includes("/"))) return { name: null, files };
  const name = [...tops][0];
  return { name, files: files.map((f) => ({ ...f, path: f.path.slice(name.length + 1) })) };
}
