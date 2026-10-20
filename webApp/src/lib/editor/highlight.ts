// Typst highlighting from typst's own parser (in the worker), with code in raw blocks coloured by the
// Kotlin core's tokenizers, like the Mac app's `Highlighter` and `InjectedLanguages`.
import { RangeSetBuilder, StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { compiler } from "../compiler";
import { CodeHighlight } from "../core";
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

/** `CodeTokenKind` from the Kotlin core. */
const CODE_CLASS = ["tw-keyword", "tw-string", "tw-comment", "tw-number", "tw-function", "tw-type", "tw-param", "tw-label", "tw-keyword", "tw-unit"];

const marks = new Map<string, Decoration>();
function mark(cls: string): Decoration {
  let deco = marks.get(cls);
  if (!deco) marks.set(cls, (deco = Decoration.mark({ class: cls })));
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
  const parts = CodeHighlight.rawBlock(raw);
  const language = parts.length ? CodeHighlight.language(raw.slice(parts[0], parts[1])) : null;
  return language && language !== Solveng.TAG ? { language, from: parts[2], to: parts[3] } : null;
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

function build(text: string, runs: Uint32Array, solveng: SolvengHighlight): DecorationSet {
  let ranges: { from: number; to: number; cls: string }[] = [];
  for (let i = 0; i + 2 < runs.length; i += 3) {
    const from = runs[i];
    const to = from + runs[i + 1];
    const tag = runs[i + 2] & 0xff;
    const cls = classes(tag, runs[i + 2] >> 8);
    const inject = tag === RAW ? injection(text.slice(from, to)) : null;
    if (inject) {
      const tokens = CodeHighlight.tokens(inject.language, text.slice(from + inject.from, from + inject.to));
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
  const builder = new RangeSetBuilder<Decoration>();
  for (const r of ranges) if (r.to > r.from && r.to <= text.length && r.cls) builder.add(r.from, r.to, mark(r.cls));
  return builder.finish();
}

const setHighlights = StateEffect.define<DecorationSet>();
/** Highlights again, e.g. once a compile tells whether solveng reads math. */
export const refreshHighlights = StateEffect.define<null>();

const highlights = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(deco, tr) {
    deco = deco.map(tr.changes);
    for (const effect of tr.effects) if (effect.is(setHighlights)) deco = effect.value;
    return deco;
  },
  provide: (field) => EditorView.decorations.from(field),
});

/**
 * Typst highlighting; `code` treats the whole file as code, as for `.typc`. `solvengContext` gives the text of the
 * files around, where solveng's settings may be.
 */
export function typstHighlighting(code = false, solvengContext: () => Promise<string> = async () => "") {
  const plugin = ViewPlugin.fromClass(
    class {
      version = 0;
      constructor(view: EditorView) {
        this.request(view);
      }
      update(update: ViewUpdate) {
        if (update.docChanged || update.transactions.some((t) => t.effects.some((e) => e.is(refreshHighlights)))) this.request(update.view);
      }
      request(view: EditorView) {
        const version = ++this.version;
        const text = view.state.doc.toString();
        const solveng = code ? Promise.resolve(null) : solvengContext().then((around) => Solveng.highlight(text, around)).catch(() => null);
        Promise.all([compiler.highlight(text, code), solveng])
          .then(([runs, calculated]) => {
            // Results for older text would land in the wrong places.
            if (version !== this.version || view.state.doc.length !== text.length) return;
            view.dispatch({ effects: setHighlights.of(build(text, runs, calculated)) });
          })
          .catch(() => {});
      }
    },
  );
  return [highlights, plugin];
}
