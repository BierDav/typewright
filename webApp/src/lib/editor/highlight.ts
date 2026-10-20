// Typst highlighting from typst's own parser (in the worker), with code in raw blocks coloured by the
// Kotlin core's tokenizers, like the Mac app's `Highlighter` and `InjectedLanguages`.
import { RangeSetBuilder, StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { compiler } from "../compiler";
import { CodeHighlight, Solveng } from "../core";

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

/** The language and body range of a raw element; `plain` makes untagged raw solveng (its `plain-code: true`). */
function injection(raw: string, plain: boolean): { language: string; from: number; to: number } | null {
  if (raw.startsWith("```")) {
    const parts = CodeHighlight.rawBlock(raw);
    const language = parts.length ? CodeHighlight.language(raw.slice(parts[0], parts[1])) : null;
    if (language) return { language, from: parts[2], to: parts[3] };
    if (parts.length) return null;
  }
  const body = plain ? Solveng.body(raw, true) : new Int32Array();
  return body.length ? { language: Solveng.TAG, from: body[0], to: body[1] } : null;
}

function build(text: string, runs: Uint32Array, plain: boolean): DecorationSet {
  const ranges: { from: number; to: number; cls: string }[] = [];
  for (let i = 0; i + 2 < runs.length; i += 3) {
    const from = runs[i];
    const to = from + runs[i + 1];
    const tag = runs[i + 2] & 0xff;
    const cls = classes(tag, runs[i + 2] >> 8);
    const inject = tag === RAW ? injection(text.slice(from, to), plain) : null;
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
  ranges.sort((a, b) => a.from - b.from || a.to - b.to);
  const builder = new RangeSetBuilder<Decoration>();
  for (const r of ranges) if (r.to > r.from && r.to <= text.length && r.cls) builder.add(r.from, r.to, mark(r.cls));
  return builder.finish();
}

const setHighlights = StateEffect.define<DecorationSet>();

const highlights = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(deco, tr) {
    deco = deco.map(tr.changes);
    for (const effect of tr.effects) if (effect.is(setHighlights)) deco = effect.value;
    return deco;
  },
  provide: (field) => EditorView.decorations.from(field),
});

/** Typst highlighting; `code` treats the whole file as code, as for `.typc`. */
export function typstHighlighting(code = false) {
  const plugin = ViewPlugin.fromClass(
    class {
      version = 0;
      constructor(view: EditorView) {
        this.request(view);
      }
      update(update: ViewUpdate) {
        if (update.docChanged) this.request(update.view);
      }
      request(view: EditorView) {
        const version = ++this.version;
        const text = view.state.doc.toString();
        compiler
          .highlight(text, code)
          .then((runs) => {
            // Results for older text would land in the wrong places.
            if (version !== this.version || view.state.doc.length !== text.length) return;
            view.dispatch({ effects: setHighlights.of(build(text, runs, !code && Solveng.plainCode(text))) });
          })
          .catch(() => {});
      }
    },
  );
  return [highlights, plugin];
}
