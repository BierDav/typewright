// What the file history window shows (mirrors macApp's `FileHistoryModel`): versions by day and folded line diffs.
import type { DiffHunk, DiffKind } from "~/wasm/core/core.js";
import type { FileVersion } from "./jj";

export type DiffLine = { type: "line"; id: number; kind: DiffKind; text: string; old: number | null; new: number | null };
export type DiffFold = { type: "fold"; id: number; hunk: number; count: number };
export type DiffRow = DiffLine | DiffFold;

/** Rows of a line diff; unchanged runs keep `context` lines around changes, the rest fold unless in `expanded`. */
export function diffRows(hunks: DiffHunk[], expanded: ReadonlySet<number> = new Set(), context = 3): DiffRow[] {
  const rows: DiffRow[] = [];
  let [old, now, id] = [1, 1, 0];
  const add = (kind: DiffKind, text: string) => {
    rows.push({ type: "line", id: id++, kind, text, old: kind === "added" ? null : old, new: kind === "removed" ? null : now });
    if (kind !== "added") old++;
    if (kind !== "removed") now++;
  };
  hunks.forEach((hunk, index) => {
    if (hunk.kind !== "same") return hunk.lines.forEach((l) => add(hunk.kind, l));
    // No context is needed before the first change or after the last one.
    const head = index === 0 ? 0 : context;
    const tail = index === hunks.length - 1 ? 0 : context;
    const hidden = hunk.lines.length - head - tail;
    // Folding a line or two saves nothing.
    if (hidden <= 1 || expanded.has(index)) return hunk.lines.forEach((l) => add("same", l));
    hunk.lines.slice(0, head).forEach((l) => add("same", l));
    rows.push({ type: "fold", id: id, hunk: index, count: hidden });
    id += hidden;
    old += hidden;
    now += hidden;
    hunk.lines.slice(hunk.lines.length - tail).forEach((l) => add("same", l));
  });
  return rows;
}

export type VersionDay = { day: number; title: string; versions: FileVersion[] };

/** Versions (newest first) grouped by local day. */
export function groupByDay(versions: FileVersion[], now = new Date()): VersionDay[] {
  const days: VersionDay[] = [];
  for (const version of versions) {
    const date = new Date(version.time);
    const day = new Date(date.getFullYear(), date.getMonth(), date.getDate()).getTime();
    const last = days.at(-1);
    if (last?.day === day) last.versions.push(version);
    else days.push({ day, title: dayTitle(day, now), versions: [version] });
  }
  return days;
}

export function dayTitle(day: number, now = new Date()): string {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1).getTime();
  if (day === today) return "Today";
  if (day === yesterday) return "Yesterday";
  const sameYear = new Date(day).getFullYear() === now.getFullYear();
  return new Date(day).toLocaleDateString(undefined, sameYear ? { weekday: "long", day: "numeric", month: "long" } : { day: "numeric", month: "long", year: "numeric" });
}

/** The repository path the file had in each version (newest first), following renames back from `current`. */
export function versionPaths(versions: FileVersion[], current: string): string[] {
  let path = current;
  return versions.map((version) => {
    const at = path;
    if (version.kind === "renamed" && version.from) path = version.from;
    return at;
  });
}

/** One line under a version's time: what happened to the file. */
export function versionSubtitle(version: FileVersion, path: string, current: string): string {
  const base = (p: string) => p.split("/").pop() ?? p;
  switch (version.kind) {
    case "added":
      return "Created";
    case "deleted":
      return "Deleted";
    case "renamed":
      return `Renamed from ${version.from ? base(version.from) : "another name"}`;
    default: {
      if (path !== current) return `As ${base(path)}`;
      const text = version.description.trim();
      return !text || text === "Edit" ? "Edited" : text;
    }
  }
}
