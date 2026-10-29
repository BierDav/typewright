// Typst highlighting from typst's own parser (in the worker), with code in raw blocks coloured by the
// Rust core's tokenizers, like the Mac app's `Highlighter` and `InjectedLanguages`.
import { compiler } from "../compiler";
import { codeLanguage, codeTokens, rawBlockParts } from "../core";
import { type CodeEditor, monaco } from "./monaco";
import { Solveng } from "./solveng";

/** Typst's highlighting tags as the bridge numbers them (`HlTag`). */
const TAG_CLASS: Record<number, string> = {
  1: "tw-comment",
  3: "tw-keyword",
  6: "tw-link",
  7: "tw-string",
  8: "tw-label",
  9: "tw-label",
  10: "tw-keyword tw-heading",
  11: "tw-keyword",
  13: "tw-keyword",
  14: "tw-keyword",
  15: "tw-keyword",
  16: "tw-plain",
  17: "tw-number",
  18: "tw-string",
  19: "tw-function",
  20: "tw-function",
  21: "tw-error",
  22: "tw-param",
  23: "tw-unit",
};
const RAW = 7;
const BOLD = 1;
const ITALIC = 2;
const MATH = 4;

/** `highlight::kind` from the Rust core. */
// Then solveng's: parameters, variables that stand out, and the = or -> showing a result, bold as in Mathcad.
const CODE_CLASS = ["tw-keyword", "tw-string", "tw-comment", "tw-number", "tw-function", "tw-type", "tw-param", "tw-label", "tw-keyword", "tw-unit", "tw-param tw-parameter", "tw-keyword tw-evaluate", "tw-plain", "tw-type", "tw-unit-reference", "tw-constant"];

const marks = new Map<string, monaco.editor.IModelDecorationOptions>();
function mark(cls: string): monaco.editor.IModelDecorationOptions {
  let deco = marks.get(cls);
  if (!deco) marks.set(cls, (deco = { inlineClassName: cls, stickiness: monaco.editor.TrackedRangeStickiness.NeverGrowsWhenTypingAtEdges }));
  return deco;
}

function classes(tag: number, flags: number): string {
  const parts: string[] = [];
  const color = TAG_CLASS[tag];
  if (color) parts.push(color);
  else if (flags & MATH) parts.push("tw-math");
  if (flags & BOLD) parts.push("tw-bold");
  if (flags & ITALIC) parts.push("tw-italic");
  return parts.join(" ");
}

/** The language and body range of a raw block; solveng code is coloured with the whole document. */
function injection(raw: string): { language: string; from: number; to: number } | null {
  if (!raw.startsWith("```")) return null;
  const parts = rawBlockParts(raw);
  const language = parts.length ? codeLanguage(raw.slice(parts[0], parts[1])) : null;
  return language ? { language, from: parts[2], to: parts[3] } : null;
}

/** `ranges` without the parts `cuts` (sorted, not overlapping) cover. */
function without(ranges: { from: number; to: number; cls: string }[], cuts: { from: number; to: number }[]) {
  const out: typeof ranges = [];
  for (const r of ranges) {
    let from = r.from;
    for (const c of cuts) {
      if (c.to <= from || c.from >= r.to) continue;
      if (c.from > from) out.push({ ...r, from, to: c.from });
      from = Math.max(from, c.to);
    }
    if (from < r.to) out.push({ ...r, from });
  }
  return out;
}

type SolvengHighlight = { tokens: number[]; plain: number[] } | null;

function build(model: monaco.editor.ITextModel, text: string, runs: Uint32Array, solveng: SolvengHighlight): monaco.editor.IModelDeltaDecoration[] {
  let ranges: { from: number; to: number; cls: string }[] = [];
  for (let i = 0; i + 2 < runs.length; i += 3) {
    const from = runs[i];
    const to = from + runs[i + 1];
    const tag = runs[i + 2] & 0xff;
    const cls = classes(tag, runs[i + 2] >> 8);
    const inject = tag === RAW ? injection(text.slice(from, to)) : null;
    if (inject) {
      const tokens = codeTokens(inject.language, text.slice(from + inject.from, from + inject.to));
      if (tokens.length) {
        // The fence keeps the raw colour; the body gets the language's.
        ranges.push({ from, to: from + inject.from, cls });
        ranges.push({ from: from + inject.to, to, cls });
        for (let t = 0; t + 2 < tokens.length; t += 3) {
          const start = from + inject.from + tokens[t];
          ranges.push({ from: start, to: start + tokens[t + 1], cls: CODE_CLASS[tokens[t + 2]] ?? "" });
        }
        continue;
      }
    }
    if (cls) ranges.push({ from, to, cls });
  }
  // What solveng calculates is coloured like its code: its code and call strings plain under the tokens, math
  // over typst's math colours.
  if (solveng) {
    const plain: { from: number; to: number }[] = [];
    for (let p = 0; p + 1 < solveng.plain.length; p += 2) plain.push({ from: solveng.plain[p], to: solveng.plain[p + 1] });
    const tokens: typeof ranges = [];
    for (let t = 0; t + 2 < solveng.tokens.length; t += 3) {
      const from = solveng.tokens[t];
      tokens.push({ from, to: from + solveng.tokens[t + 1], cls: CODE_CLASS[solveng.tokens[t + 2]] ?? "" });
    }
    const cuts = [...plain, ...tokens].sort((a, b) => a.from - b.from);
    ranges = [...without(ranges, cuts), ...tokens];
  }
  ranges.sort((a, b) => a.from - b.from || a.to - b.to);
  return ranges
    .filter((r) => r.to > r.from && r.to <= text.length && r.cls)
    .map((r) => {
      const a = model.getPositionAt(r.from);
      const b = model.getPositionAt(r.to);
      return { range: new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column), options: mark(r.cls) };
    });
}

/**
 * Typst highlighting as decorations; `code` treats the whole file as code, as for `.typc`. `solvengContext` gives the
 * text of the files around, where solveng's settings may be. `refresh` highlights again, e.g. once a compile tells
 * whether solveng reads math.
 */
export function typstHighlighting(editor: CodeEditor, code = false, solvengContext: () => Promise<string> = async () => "") {
  const model = editor.getModel()!;
  const decorations = editor.createDecorationsCollection();
  let version = 0;
  const request = () => {
    const current = ++version;
    const text = model.getValue();
    const solveng = code ? Promise.resolve(null) : solvengContext().then((around) => Solveng.highlight(text, around)).catch(() => null);
    Promise.all([compiler.highlight(text, code), solveng])
      .then(([runs, calculated]) => {
        // Results for older text would land in the wrong places.
        if (current !== version || model.isDisposed() || editor.getModel() !== model || model.getValueLength() !== text.length) return;
        decorations.set(build(model, text, runs, calculated));
      })
      .catch(() => {});
  };
  const listener = model.onDidChangeContent(request);
  request();
  return {
    refresh: request,
    dispose: () => {
      version++;
      listener.dispose();
      decorations.clear();
    },
  };
}

/** Colours a docs code block like the editor: `typc` and signatures as code, `typ` as markup. */
export async function highlightCode(element: HTMLElement, code: boolean): Promise<void> {
  const text = element.textContent ?? "";
  const runs = await compiler.highlight(text, code).catch(() => null);
  if (!runs) return;
  const parts: Node[] = [];
  let at = 0;
  for (let i = 0; i + 2 < runs.length; i += 3) {
    const from = runs[i];
    const to = from + runs[i + 1];
    const cls = classes(runs[i + 2] & 0xff, runs[i + 2] >> 8);
    if (from < at || !cls) continue;
    if (from > at) parts.push(document.createTextNode(text.slice(at, from)));
    const span = document.createElement("span");
    span.className = cls;
    span.textContent = text.slice(from, to);
    parts.push(span);
    at = to;
  }
  parts.push(document.createTextNode(text.slice(at)));
  element.replaceChildren(...parts);
}
