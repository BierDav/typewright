import { fileKindForExtension } from "./core";
import { extension } from "./storage";

export type Kind = "folder" | "typst" | "text" | "pdf" | "font" | "document" | "image" | "binary";

/** The kind by extension, or null for unknown ones, which the caller sniffs. */
export function kindOf(path: string): Kind | null {
  const ext = extension(path);
  if (!ext) return null;
  const kind = fileKindForExtension(ext) as Kind | undefined;
  return kind ?? (isMarkdown(path) ? "text" : null);
}

/** Kind of a file whose contents are known: unknown extensions are text if they decode as text. */
export function kindWithContents(path: string, isText: boolean): Kind {
  return kindOf(path) ?? (isText ? "text" : "binary");
}

export function isEditable(kind: Kind | null): boolean {
  return kind === "typst" || kind === "text";
}

export function isMarkdown(path: string): boolean {
  return ["md", "markdown", "mdown", "mkd"].includes(extension(path));
}

export function isPreviewable(path: string): boolean {
  return extension(path) === "typ" || isMarkdown(path);
}

export function isFont(path: string): boolean {
  return ["ttf", "otf", "ttc", "otc"].includes(extension(path));
}

/** Text-ish kinds merge line by line when synced; the rest replace whole. */
export function isTextKind(kind: Kind | null): boolean {
  return kind === null || kind === "typst" || kind === "text";
}

export const mimeTypes: Record<string, string> = {
  pdf: "application/pdf",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  svg: "image/svg+xml",
  bmp: "image/bmp",
  ico: "image/x-icon",
  tif: "image/tiff",
  tiff: "image/tiff",
  heic: "image/heic",
  ttf: "font/ttf",
  otf: "font/otf",
  woff: "font/woff",
  woff2: "font/woff2",
  html: "text/html",
};

export function mimeType(path: string): string {
  return mimeTypes[extension(path)] ?? "application/octet-stream";
}
