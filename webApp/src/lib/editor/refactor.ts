// Extract variable or function, inline variable and rename in the file, on typst's syntax tree (the
// bridge's `refactor` module), like the Mac app's `Refactor`.
import { EditorSelection } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";
import { compiler } from "../compiler";

type Edit = { start: number; length: number; text: string };
type Response = { error?: string; candidates?: Edit[]; edits?: Edit[]; names?: [number, number][]; count?: number; kind?: string };

function request(op: string, view: EditorView, extra: Record<string, unknown> = {}): Promise<Response> {
  const { from, to } = view.state.selection.main;
  return compiler.refactor({ op, text: view.state.doc.toString(), start: from, length: to - from, ...extra });
}

/** Applies edits in the old text and selects the new name everywhere, ready to be typed over. */
function apply(view: EditorView, response: Response): string | null {
  if (response.error) return response.error;
  const edits = response.edits ?? [];
  if (!edits.length) return "Nothing to change here.";
  const names = response.names ?? [];
  view.dispatch({
    changes: edits.map((e) => ({ from: e.start, to: e.start + e.length, insert: e.text })),
    selection: names.length ? EditorSelection.create(names.map(([s, l]) => EditorSelection.range(s, s + l))) : undefined,
    scrollIntoView: true,
    userEvent: "input.refactor",
  });
  view.focus();
  return null;
}

/** The name at the caret and whether it's a "variable" or "function". */
export async function symbolAt(view: EditorView): Promise<{ name: string; kind: string } | null> {
  const response = await request("symbol", view, { length: 0 });
  const name = response.candidates?.[0]?.text;
  return name && response.kind ? { name, kind: response.kind } : null;
}

/** Expressions to extract: the selected one, or those around the caret, inner to outer. */
export async function extractCandidates(view: EditorView): Promise<Edit[]> {
  return (await request("candidates", view)).candidates ?? [];
}

export async function extractVariable(view: EditorView, range: { start: number; length: number }, all: boolean): Promise<string | null> {
  return apply(view, await compiler.refactor({ op: "extract", text: view.state.doc.toString(), start: range.start, length: range.length, all }));
}

/** Blocks the function can go into, inner to outer; each candidate's text is its label. */
export async function functionScopes(view: EditorView): Promise<Edit[]> {
  return (await request("scopes", view)).candidates ?? [];
}

export async function extractFunction(view: EditorView, scope?: number): Promise<string | null> {
  return apply(view, await request("function", view, scope === undefined ? {} : { scope }));
}

export async function inlineVariable(view: EditorView): Promise<string | null> {
  return apply(view, await request("inline", view, { length: 0 }));
}

/** Selects the name's binding and its uses in this file, so typing renames them all at once. */
export async function renameSymbol(view: EditorView, path: string): Promise<string | null> {
  const head = view.state.selection.main.head;
  const text = view.state.doc.toString();
  // Uses are found from the binding, wherever the caret is.
  const definition = await compiler.definition(path, head).catch(() => null);
  const binding = definition && "path" in definition && definition.path === path && !definition.package ? definition : null;
  const start = binding ? binding.from : head;
  const response = await compiler.refactor({ op: "usages", text, start });
  const ranges = ((response.candidates ?? []) as Edit[]).map((r) => ({ from: r.start, to: r.start + r.length }));
  if (binding && binding.to > binding.from) ranges.push({ from: binding.from, to: binding.to });
  if (!ranges.length) return "Put the caret on a variable or function defined in this file to rename it.";
  ranges.sort((a, b) => a.from - b.from);
  const main = Math.max(0, ranges.findIndex((r) => head >= r.from && head <= r.to));
  view.dispatch({ selection: EditorSelection.create(ranges.map((r) => EditorSelection.range(r.from, r.to)), main), scrollIntoView: true });
  view.focus();
  return null;
}
