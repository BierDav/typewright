// Fonts every space can use, kept in origin storage: Google Fonts (through Fontsource, which serves
// static TrueType files to browsers) under `fonts/google/<family>/` and uploads under `fonts/uploads/`.
import { createStore } from "solid-js/store";
import * as fs from "./storage";

export type GoogleFont = { id: string; family: string; category?: string; subsets: string[]; defSubset?: string };

const GOOGLE = "fonts/google";
const UPLOADS = "fonts/uploads";
const CATALOG = "fonts/catalog.json";
const API = "https://api.fontsource.org/v1/fonts";

export const [fonts, setFonts] = createStore({
  catalog: [] as GoogleFont[],
  installed: [] as string[],
  uploads: [] as string[],
  downloads: {} as Record<string, number>,
  error: null as string | null,
  revision: 0,
});

let loadingCatalog = false;

export async function refreshInstalled() {
  const google = (await fs.list(GOOGLE)).filter((e) => e.kind === "dir").map((e) => fs.basename(e.path));
  const uploads = (await fs.list(UPLOADS)).filter((e) => e.kind === "file").map((e) => fs.basename(e.path));
  setFonts({
    installed: google.sort((a, b) => a.localeCompare(b)),
    uploads: uploads.sort((a, b) => a.localeCompare(b)),
    revision: fonts.revision + 1,
  });
}

/** Loads the family list, from a cache younger than a week if there is one. */
export async function loadCatalog() {
  if (fonts.catalog.length || loadingCatalog) return;
  loadingCatalog = true;
  try {
    const cached = await fs.stat(CATALOG);
    if (cached && Date.now() - cached.modified < 7 * 24 * 3600 * 1000) {
      const text = await fs.readText(CATALOG);
      if (text) {
        setFonts("catalog", JSON.parse(text));
        return;
      }
    }
    const response = await fetch(`${API}?type=google`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const list = (await response.json()) as GoogleFont[];
    const catalog = list.map(({ id, family, category, subsets, defSubset }) => ({ id, family, category, subsets, defSubset }));
    setFonts({ catalog, error: null });
    await fs.writeFile(CATALOG, JSON.stringify(catalog), true);
  } catch (err) {
    setFonts("error", `Couldn't load Google Fonts: ${(err as Error).message}`);
  } finally {
    loadingCatalog = false;
  }
}

/** The catalog entry for a family name in any case, as typst reports them lowercased. */
export function googleFont(name: string): GoogleFont | undefined {
  const wanted = name.toLowerCase();
  return fonts.catalog.find((f) => f.family.toLowerCase() === wanted);
}

type Variants = Record<string, Record<string, Record<string, { url: { ttf?: string } }>>>;

/** Downloads every weight and style of a family into `folder` (inside a space), or the shared Google folder. */
export async function download(family: string, folder?: string) {
  if (fonts.downloads[family] !== undefined) return;
  await loadCatalog();
  const font = googleFont(family);
  if (!font) {
    setFonts("error", `“${family}” isn't on Google Fonts`);
    return;
  }
  setFonts("downloads", family, 0);
  try {
    const response = await fetch(`${API}/${font.id}`);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const details = (await response.json()) as { variants: Variants; subsets: string[]; defSubset: string };
    // Each file covers one script; the default one and Latin Extended cover most documents.
    const subsets = [...new Set([details.defSubset, "latin-ext"])].filter((s) => details.subsets.includes(s));
    const files: { name: string; url: string }[] = [];
    for (const [weight, styles] of Object.entries(details.variants)) {
      for (const [style, bySubset] of Object.entries(styles)) {
        for (const subset of subsets) {
          const url = bySubset[subset]?.url.ttf;
          if (url) files.push({ name: `${font.id}-${subset}-${weight}-${style}.ttf`, url });
        }
      }
    }
    if (files.length === 0) throw new Error("no TrueType files");
    const target = folder ?? fs.join(GOOGLE, font.family);
    let done = 0;
    await Promise.all(
      files.map(async (file) => {
        const res = await fetch(file.url);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        await fs.writeFile(fs.join(target, file.name), new Uint8Array(await res.arrayBuffer()), !folder);
        setFonts("downloads", family, ++done / files.length);
      }),
    );
    setFonts("error", null);
  } catch (err) {
    setFonts("error", `Couldn't download ${family}: ${(err as Error).message}`);
  } finally {
    setFonts("downloads", family, undefined!);
    await refreshInstalled();
  }
}

export async function remove(family: string) {
  await fs.remove(fs.join(GOOGLE, family), true);
  await refreshInstalled();
}

export async function upload(files: File[]) {
  for (const file of files) await fs.writeFile(fs.join(UPLOADS, file.name), new Uint8Array(await file.arrayBuffer()), true);
  await refreshInstalled();
}

export async function removeUpload(name: string) {
  await fs.remove(fs.join(UPLOADS, name), true);
  await refreshInstalled();
}

/** Font files of every space: Google Fonts and uploads. */
export async function sharedFontFiles(): Promise<Uint8Array[]> {
  const out: Uint8Array[] = [];
  for (const dir of [GOOGLE, UPLOADS]) {
    for (const entry of await fs.walk(dir)) {
      if (entry.kind !== "file" || !/\.(ttf|otf|ttc|otc)$/i.test(entry.path)) continue;
      const bytes = await fs.readFile(fs.join(dir, entry.path));
      if (bytes) out.push(bytes);
    }
  }
  return out;
}

if (typeof window !== "undefined") void refreshInstalled();
