// solveng in the editor: its editor support (`solveng-ide` from the solveng repository, run in the typst worker),
// fences that close themselves and rewrites between calls, math and code, like the Mac app's context actions.
import { compiler } from "../compiler";
import { type CodeEditor, edit, monaco, selection, text } from "./monaco";

export type SolvengLocation = { path?: string | null; start: number; end: number };

/** Replace `start..<end` with `text`, in the document (no `path`) or one of the files around. */
export type SolvengEdit = { path?: string | null; start: number; end: number; text: string };

/**
 * `filter`, when set, is what typing matches instead of `insert`: `Delta_R` for `Δ_R`. `edits` come with it, like the
 * `#import units: km` a shorthand needs.
 */
export type SolvengItem = { label: string; kind: number; detail: string; insert: string; documentation?: string; filter?: string; edits?: SolvengEdit[] };

type SolvengConversion = { title: string; start: number; end: number; text: string; edits?: SolvengEdit[] };

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
  format: (document: string, context: string) =>
    compiler.solveng<{ start: number; end: number; text: string }[]>("format", document, context),
  fixes: (document: string, context: string, offset: number) =>
    compiler.solveng<SolvengConversion[]>("fixes", document, context, offset),
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
export function fenceClosing(editor: CodeEditor): monaco.IDisposable {
  return editor.onDidChangeModelContent((event) => {
    const [change] = event.changes;
    if (event.isUndoing || event.isRedoing || event.isFlush || event.changes.length !== 1 || change.text !== "`" || change.rangeLength) return;
    const model = editor.getModel();
    if (!model || model.getLanguageId() !== "typst" || editor.getOption(monaco.editor.EditorOption.readOnly)) return;
    const at = change.rangeOffset;
    const doc = model.getValue();
    const before = doc.slice(Math.max(0, at - 3), at);
    if (!before.endsWith("``") || before === "```" || doc[at + 1] === "`") return;
    // Edits can't run inside the change event.
    queueMicrotask(() => {
      if (model.getValue() !== doc || selection(editor).head !== at + 1) return;
      edit(editor, [{ from: at + 1, to: at + 1, insert: "```" }], [{ anchor: at + 1, head: at + 1 }], "input.type");
      editor.trigger("fence", "editor.action.triggerSuggest", {});
    });
  });
}

export type Conversion = { title: string; run: () => void };

/** Calculation fixes at the caret. */
export async function conversions(view: CodeEditor, around: string): Promise<Conversion[]> {
  const doc = text(view);
  const offset = selection(view).head;
  const fixes = await Solveng.fixes(doc, around, offset);
  return fixes.map((c) => ({
    title: c.title,
    run: () => {
      if (text(view) !== doc) return;
      const extra = (c.edits ?? []).filter((e) => !e.path).map((e) => ({ from: e.start, to: e.end, insert: e.text }));
      edit(view, [{ from: c.start, to: c.end, insert: c.text }, ...extra], undefined, "input.refactor");
      view.focus();
    },
  }));
}
