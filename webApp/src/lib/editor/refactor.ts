// Extract variable or function, inline variable and rename in the file, on typst's syntax tree (the
// bridge's `refactor` module), like the Mac app's `Refactor`.
import { compiler } from "../compiler";
import { type CodeEditor, edit, select, selection, text } from "./monaco";

type Edit = { start: number; length: number; text: string };
type Response = { error?: string; candidates?: Edit[]; edits?: Edit[]; names?: [number, number][]; count?: number; kind?: string };

function request(op: string, view: CodeEditor, extra: Record<string, unknown> = {}): Promise<Response> {
  const { from, to } = selection(view);
  return compiler.refactor({ op, text: text(view), start: from, length: to - from, ...extra });
}

/** Applies edits in the old text and selects the new name everywhere, ready to be typed over. */
function apply(view: CodeEditor, response: Response): string | null {
  if (response.error) return response.error;
  const edits = response.edits ?? [];
  if (!edits.length) return "Nothing to change here.";
  const names = response.names ?? [];
  edit(view, edits.map((e) => ({ from: e.start, to: e.start + e.length, insert: e.text })), undefined, "input.refactor");
  // Names are where they are after the edits.
  if (names.length) select(view, names.map(([s, l]) => ({ anchor: s, head: s + l })));
  view.focus();
  return null;
}

/** The name at the caret and whether it's a "variable" or "function". */
export async function symbolAt(view: CodeEditor): Promise<{ name: string; kind: string } | null> {
  const response = await request("symbol", view, { length: 0 });
  const name = response.candidates?.[0]?.text;
  return name && response.kind ? { name, kind: response.kind } : null;
}

/** Expressions to extract: the selected one, or those around the caret, inner to outer. */
export async function extractCandidates(view: CodeEditor): Promise<Edit[]> {
  return (await request("candidates", view)).candidates ?? [];
}

export async function extractVariable(view: CodeEditor, range: { start: number; length: number }, all: boolean): Promise<string | null> {
  return apply(view, await compiler.refactor({ op: "extract", text: text(view), start: range.start, length: range.length, all }));
}

/** Blocks the function can go into, inner to outer; each candidate's text is its label. */
export async function functionScopes(view: CodeEditor): Promise<Edit[]> {
  return (await request("scopes", view)).candidates ?? [];
}

export async function extractFunction(view: CodeEditor, scope?: number): Promise<string | null> {
  return apply(view, await request("function", view, scope === undefined ? {} : { scope }));
}

export async function inlineVariable(view: CodeEditor): Promise<string | null> {
  return apply(view, await request("inline", view, { length: 0 }));
}

/** Selects the name's binding and its uses in this file, so typing renames them all at once. */
export async function renameSymbol(view: CodeEditor, path: string): Promise<string | null> {
  const head = selection(view).head;
  const doc = text(view);
  // Uses are found from the binding, wherever the caret is.
  const definition = await compiler.definition(path, head).catch(() => null);
  const binding = definition && "path" in definition && definition.path === path && !definition.package ? definition : null;
  const start = binding ? binding.from : head;
  const response = await compiler.refactor({ op: "usages", text: doc, start });
  const ranges = ((response.candidates ?? []) as Edit[]).map((r) => ({ from: r.start, to: r.start + r.length }));
  if (binding && binding.to > binding.from) ranges.push({ from: binding.from, to: binding.to });
  if (!ranges.length) return "Put the caret on a variable or function defined in this file to rename it.";
  ranges.sort((a, b) => a.from - b.from);
  const main = Math.max(0, ranges.findIndex((r) => head >= r.from && head <= r.to));
  select(view, ranges.map((r) => ({ anchor: r.from, head: r.to })), main);
  view.focus();
  return null;
}
