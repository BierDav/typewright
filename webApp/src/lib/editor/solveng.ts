// solveng in the editor: its editor support (`solveng-ide` from the solveng repository, run in the typst worker),
// fences that close themselves and rewrites between calls, math and code, like the Mac app's context actions.
import { startCompletion } from "@codemirror/autocomplete";
import { EditorView } from "@codemirror/view";
import { compiler } from "../compiler";

export type SolvengLocation = { path?: string | null; start: number; end: number };

/** `filter`, when set, is what typing matches instead of `insert`: `Delta_R` for `Δ_R`. */
export type SolvengItem = { label: string; kind: number; detail: string; insert: string; documentation?: string; filter?: string };

/** Offsets are UTF-16; `context` comes from `Solveng.context`. */
export const Solveng = {
  /** Language tag of solveng code. */
  TAG: "solveng",
  /** Item kinds. */
  FUNCTION: 1,
  UNIT: 2,
  CONSTANT: 3,
  PARAMETER: 4,
  VALUE: 5,
  KEYWORD: 6,
  /**
   * The files around a document (paths relative to the space), the last compile's report, its path, whether it's the
   * compiled file, and the report of compiling it on its own, used when the compiled file doesn't reach it.
   */
  context: (files: { path: string; text: string }[], report: string, path: string, main: boolean, mainPath = "", fileReport = "") =>
    JSON.stringify({ files, report, path, main, mainPath: main ? path : mainPath, fileReport }),
  /** Every solveng token as flat `(start, length, kind)` triples, and `(start, end)` pairs shown plain under them. */
  highlight: (document: string, context: string) => compiler.solveng<{ tokens: number[]; plain: number[] } | null>("highlight", document, context),
  /** `items` replace `from..<(to ?? offset)`; `exclusive` ones replace typst's completions. */
  complete: (document: string, context: string, offset: number) =>
    compiler.solveng<{ from: number; to?: number; items: SolvengItem[]; exclusive: boolean } | null>("complete", document, context, offset),
  conversions: (document: string, context: string, offset: number) =>
    compiler.solveng<{ title: string; start: number; end: number; text: string }[]>("conversions", document, context, offset),
  format: (document: string, context: string) =>
    compiler.solveng<{ start: number; end: number; text: string }[]>("format", document, context),
  fixes: (document: string, context: string, offset: number) =>
    compiler.solveng<{ title: string; start: number; end: number; text: string }[]>("fixes", document, context, offset),
  hover: (document: string, context: string, offset: number) =>
    compiler.solveng<{ start: number; end: number; markdown: string } | null>("hover", document, context, offset),
  /** Where the solveng name at `offset` is defined; no `path` means the document itself. */
  definition: (document: string, context: string, offset: number) =>
    compiler.solveng<SolvengLocation | null>("definition", document, context, offset),
  /** Every use of the solveng name at `offset`, its definition included. */
  usages: (document: string, context: string, offset: number) => compiler.solveng<SolvengLocation[]>("usages", document, context, offset),
  /** Problems found while typing, like unknown units. */
  diagnostics: (document: string, context: string) =>
    compiler.solveng<{ start: number; end: number; message: string; severity?: string }[]>("diagnostics", document, context),
  /** Local files a document imports or includes, as written. */
  references: (document: string) => compiler.solveng<string[]>("references", document),
};

/** The third backtick of a fence adds a closing fence and offers the language tags. */
export const fenceClosing = EditorView.inputHandler.of((view, from, to, text) => {
  if (text !== "`" || from !== to || view.state.readOnly) return false;
  const before = view.state.sliceDoc(Math.max(0, from - 3), from);
  if (!before.endsWith("``") || before === "```" || view.state.sliceDoc(from, from + 1) === "`") return false;
  view.dispatch({ changes: { from, insert: "````" }, selection: { anchor: from + 1 }, userEvent: "input.type" });
  startCompletion(view);
  return true;
});

export type Conversion = { title: string; run: () => void };

/** solveng math ⇄ a solveng code block at the caret; `around` is the text of the files around. */
export async function conversions(view: EditorView, around: string): Promise<Conversion[]> {
  const text = view.state.doc.toString();
  const offset = view.state.selection.main.head;
  const [fixes, rewrites] = await Promise.all([Solveng.fixes(text, around, offset), Solveng.conversions(text, around, offset)]);
  return [...fixes, ...rewrites].map((c) => ({
    title: c.title,
    run: () => {
      if (view.state.doc.toString() !== text) return;
      view.dispatch({ changes: { from: c.start, to: c.end, insert: c.text }, scrollIntoView: true, userEvent: "input.refactor" });
      view.focus();
    },
  }));
}
