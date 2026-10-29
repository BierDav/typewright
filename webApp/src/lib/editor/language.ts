// Completions, hover docs, quick docs (F1) and go to definition from typst-ide in the worker; the
// browser's stand-in for the tinymist language server the Mac app runs.
import { autocompletion, type Completion, type CompletionContext, type CompletionResult, snippet } from "@codemirror/autocomplete";
import { StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, hoverTooltip, keymap, showTooltip, type Tooltip, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { compiler, type Completion as TypstCompletion } from "../compiler";
import { highlightCode } from "./highlight";
import { Solveng, type SolvengEdit } from "./solveng";
import { settings } from "../settings";
import { fenceClosing } from "./solveng";

export type LanguageContext = {
  /** The file being edited, relative to the space. */
  path: () => string;
  /** Opens a file of the space with the range selected. */
  open: (path: string, from: number, to: number) => void;
  /** Shows a short message, e.g. that a definition is in the standard library. */
  notify: (message: string) => void;
  /** The text of the files around this one that solveng settings and definitions come from. */
  solvengContext: () => Promise<string>;
  /** Lists the uses of the solveng name at `offset` to pick from. */
  showSolvengUsages: (offset: number) => void;
};

const KIND: Record<string, Completion["type"]> = {
  syntax: "keyword",
  func: "function",
  type: "type",
  param: "property",
  constant: "constant",
  path: "text",
  package: "namespace",
  label: "variable",
  font: "text",
  symbol: "text",
};

let indexRequested = false;

const KIND_NAMES: Record<string, string> = {
  function: "Function",
  method: "Method",
  variable: "Variable",
  constant: "Constant",
  keyword: "Keyword",
  property: "Parameter",
  type: "Type",
  class: "Type",
  namespace: "Package",
  text: "Value",
};

function kindLabel(completion: Completion): HTMLElement | null {
  const name = KIND_NAMES[completion.type ?? ""];
  if (!name) return null;
  const el = document.createElement("span");
  el.className = "tw-completion-kind";
  el.textContent = name;
  return el;
}

/** Named arguments of the call at the caret, for any function (`parameters.rs` in the typst bridge). */
type Parameters = {
  from: number;
  to: number;
  items: { label: string; insert: string; detail: string; documentation: string }[];
  /** Whether a positional argument fits too, so other values belong in the list. */
  values: boolean;
  /** Whether arguments follow, so accepted names get a comma. */
  comma: boolean;
};

const parameters = (document: string, context: string, offset: number) => compiler.solveng<Parameters | null>("parameters", document, context, offset);

/** Docs of the function or argument name at `offset` as the Mac's hovers show them: signature, docs, parameters. */
const typstDocs = (document: string, context: string, offset: number) => compiler.solveng<string | null>("typstHover", document, context, offset);

/** Snippets that are statements, out of place in an argument list. */
const STATEMENT = /^(let|for|while|if|import|include|set|show|break|continue|return|function call)\b/;

/** Markdown docs, rendered when the list shows them. */
function markdownInfo(markdown: string | null | undefined): Completion["info"] {
  return markdown ? () => docsElement({ kind: "text", value: markdown }) : undefined;
}

function toCompletion(item: TypstCompletion, context: () => Promise<string>): Completion {
  const apply = item.apply ?? item.label;
  // A function's whole docs, like its hover; the item only carries the first sentence.
  const name = item.label.replace(/\.(bracket|paren)$/, "");
  const info: Completion["info"] =
    item.kind === "func"
      ? async () => {
          const docs = await typstDocs(`#${name}`, await context(), 2).catch(() => null);
          return docsElement({ kind: "text", value: docs ?? item.detail ?? "" });
        }
      : markdownInfo(item.detail);
  return {
    label: item.label,
    type: KIND[item.kind] ?? "text",
    detail: item.kind === "symbol" ? apply : undefined,
    info,
    // typst-ide writes snippets as `${name}` placeholders, as CodeMirror's snippets do.
    apply: apply.includes("${") ? snippet(apply) : apply,
  };
}

/** The call's parameters first, statements out, other values only where a positional argument fits. */
function withParameters(params: Parameters, items: TypstCompletion[], context: () => Promise<string>): Completion[] {
  const own: Completion[] = params.items.map((item, i) => ({
    label: item.label,
    type: "property",
    detail: item.detail || undefined,
    info: markdownInfo(item.documentation),
    boost: 99 - i / params.items.length,
    apply: snippet(item.insert.replace("$0", "${}")),
  }));
  const known = new Set(own.map((o) => o.label));
  const rest = items.flatMap((item): Completion[] => {
    // typst-ide's own names, for calls the bridge can't resolve.
    if (item.kind === "param") return known.has(item.label) ? [] : [toCompletion({ ...item, apply: (item.apply ?? item.label) + (params.comma ? ", " : "") }, context)];
    if (own.length && !params.values) return [];
    return item.kind === "syntax" && STATEMENT.test(item.label) ? [] : [toCompletion(item, context)];
  });
  return [...own, ...rest];
}

type Apply = string | ((view: EditorView, completion: Completion, from: number, to: number) => void);

/** A completion's insert with the edits elsewhere that come with it (an import): those go in first, the insert after. */
function withEdits(apply: Apply, edits: SolvengEdit[] | undefined): Apply {
  const extra = (edits ?? []).filter((e) => !e.path);
  if (!extra.length) return apply;
  return (view, completion, from, to) => {
    const others = extra.map((e) => ({ from: e.start, to: e.end, insert: e.text }));
    if (typeof apply === "string") {
      // one step: the insert and its edits, the caret after the insert
      const changes = view.state.changes([{ from, to, insert: apply }, ...others]);
      view.dispatch({ changes, selection: { anchor: changes.mapPos(to, 1) }, userEvent: "input.complete" });
      return;
    }
    const changes = view.state.changes(others);
    view.dispatch({ changes, userEvent: "input.complete" });
    apply(view, completion, changes.mapPos(from, 1), changes.mapPos(to, 1));
  };
}

/** Inside solveng code, math and its calls the names, units and option values of the calculation; null elsewhere. */
async function solvengCompletions(ctx: CompletionContext, around: string): Promise<(CompletionResult & { exclusive: boolean }) | null> {
  const result = await Solveng.complete(ctx.state.doc.toString(), around, ctx.pos).catch(() => null);
  if (!result || result.from > ctx.pos) return null;
  const type = (kind: number) =>
    kind === Solveng.FUNCTION ? "function" : kind === Solveng.UNIT || kind === Solveng.PARAMETER ? "property" : kind === Solveng.CONSTANT || kind === Solveng.VALUE ? "constant" : kind === Solveng.KEYWORD ? "keyword" : "variable";
  const options = result.items.map((item, i): Completion => ({
    // Δ_R is found by typing Delta_R.
    label: item.filter ?? item.label,
    displayLabel: item.label,
    type: type(item.kind),
    detail: item.detail,
    info: item.documentation,
    boost: -i / result.items.length,
    // Units like kΩ are found by typing kOmega.
    apply: withEdits(item.insert.includes("$0") ? snippet(item.insert.replace("$0", "${}")) : item.insert, item.edits),
  }));
  return { from: result.from, to: result.to, options, exclusive: result.exclusive };
}

function completionSource(context: LanguageContext) {
  return async (ctx: CompletionContext): Promise<CompletionResult | null> => {
    if (!settings.language) return null;
    const around = await context.solvengContext();
    const solveng = await solvengCompletions(ctx, around);
    if (ctx.aborted) return null;
    if (solveng?.exclusive) return solveng.options.length || ctx.explicit ? solveng : null;
    const before = ctx.state.sliceDoc(Math.max(0, ctx.pos - 64), ctx.pos);
    // Package names complete from Typst Universe's index, fetched once on first use.
    if (/"@[\w/:.-]*$/.test(before) && !indexRequested) {
      indexRequested = true;
      await compiler.packageIndex().catch(() => (indexRequested = false));
    }
    const params = await parameters(ctx.state.doc.toString(), around, ctx.pos).catch(() => null);
    if (ctx.aborted) return null;
    if (!ctx.explicit && !params && !/[\w#.@"<(:/]$/.test(before)) return solveng;
    const result = await compiler.complete(context.path(), ctx.pos, ctx.explicit).catch(() => null);
    if (ctx.aborted) return null;
    const validFor = /^[\p{L}\p{N}_-]*$/u;
    if (params) {
      const options = withParameters(params, result?.from === params.from ? result.items : [], context.solvengContext);
      return options.length ? { from: params.from, to: params.to, options, validFor } : solveng;
    }
    if (!result) return solveng;
    if (solveng?.options.length && (solveng.from !== result.from || (solveng.to ?? ctx.pos) > ctx.pos)) return solveng;
    const options = result.items.map((i) => toCompletion(i, context.solvengContext));
    // In math the calculation's names come before Typst's symbols.
    if (solveng && solveng.from === result.from) {
      const named = new Set(solveng.options.map((o) => o.label));
      return { from: result.from, to: solveng.to, options: [...solveng.options.map((o) => ({ ...o, boost: 50 + (o.boost ?? 0) })), ...options.filter((o) => !named.has(o.label))] };
    }
    return { from: result.from, options, validFor };
  };
}

async function docsElement(value: { kind: "text" | "code"; value: string }): Promise<HTMLElement> {
  const dom = document.createElement("div");
  dom.className = "tw-docs";
  if (value.kind === "code") {
    const pre = document.createElement("pre");
    pre.textContent = value.value;
    dom.append(pre);
  } else {
    // Typst's docs are Markdown.
    dom.innerHTML = await compiler.markdown(value.value).catch(() => "");
    if (!dom.innerHTML) dom.textContent = value.value;
    // Signatures and examples in the editor's colours.
    const blocks = [...dom.querySelectorAll("pre > code")] as HTMLElement[];
    await Promise.all(
      blocks.map((code) => {
        const language = /language-(\w+)/.exec(code.className)?.[1] ?? "typc";
        return ["typc", "typ", "typst", "example"].includes(language) ? highlightCode(code, language === "typc") : undefined;
      }),
    );
  }
  return dom;
}

/** solveng's docs for a name or unit of a calculation, else typst's. */
async function docsAt(view: EditorView, context: LanguageContext, pos: number): Promise<{ kind: "text" | "code"; value: string } | null> {
  const around = await context.solvengContext().catch(() => "");
  const text = view.state.doc.toString();
  const solveng = await Solveng.hover(text, around, pos).catch(() => null);
  if (solveng) return { kind: "text", value: solveng.markdown };
  // Functions and argument names from the source itself; typst-ide only knows them when the last compile got there.
  const docs = await typstDocs(text, around, pos).catch(() => null);
  if (docs) return { kind: "text", value: docs };
  return compiler.tooltip(context.path(), pos).catch(() => null);
}

function hover(context: LanguageContext) {
  return hoverTooltip(
    async (view, pos): Promise<Tooltip | null> => {
      if (!settings.language) return null;
      const value = await docsAt(view, context, pos);
      if (!value) return null;
      const dom = await docsElement(value);
      return { pos, above: true, create: () => ({ dom }) };
    },
    { hoverTime: 400 },
  );
}

const setDocs = StateEffect.define<Tooltip | null>();

/** Quick docs at the caret, shown with F1 until the caret moves. */
const docsField = StateField.define<Tooltip | null>({
  create: () => null,
  update(value, tr) {
    for (const effect of tr.effects) if (effect.is(setDocs)) return effect.value;
    return tr.selection || tr.docChanged ? null : value;
  },
  provide: (field) => showTooltip.from(field),
});

export async function showDocs(view: EditorView, context: LanguageContext): Promise<boolean> {
  const pos = view.state.selection.main.head;
  const value = await docsAt(view, context, pos);
  if (!value) {
    context.notify("No documentation here.");
    return false;
  }
  const dom = await docsElement(value);
  view.dispatch({ effects: setDocs.of({ pos, above: true, create: () => ({ dom }) }) });
  return true;
}

export async function goToDefinition(view: EditorView, context: LanguageContext, pos = view.state.selection.main.head) {
  // solveng's names; on the definition itself its usages.
  const around = await context.solvengContext().catch(() => "");
  const solveng = await Solveng.definition(view.state.doc.toString(), around, pos).catch(() => null);
  if (solveng) {
    if (!solveng.path && solveng.start <= pos && pos <= solveng.end) return context.showSolvengUsages(pos);
    if (solveng.path && solveng.path !== context.path()) return context.open(solveng.path, solveng.start, solveng.end);
    view.dispatch({ selection: { anchor: solveng.start, head: solveng.end }, scrollIntoView: true });
    return view.focus();
  }
  const location = await compiler.definition(context.path(), pos).catch(() => null);
  if (!location) return context.notify("No definition found.");
  if ("std" in location) return context.notify(`${location.std ?? "This"} is part of Typst's standard library.`);
  if (location.package) return context.notify(`Defined in the package ${location.path}.`);
  if (location.path === context.path()) {
    view.dispatch({ selection: { anchor: location.from, head: location.to }, scrollIntoView: true });
    view.focus();
  } else {
    context.open(location.path, location.from, location.to);
  }
}

const setOccurrences = StateEffect.define<DecorationSet>();

/** The uses of the solveng name at the caret that belong to the same definition, marked like IntelliJ does. */
const occurrenceField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, tr) {
    value = value.map(tr.changes);
    for (const effect of tr.effects) if (effect.is(setOccurrences)) value = effect.value;
    return tr.docChanged ? Decoration.none : value;
  },
  provide: (field) => EditorView.decorations.from(field),
});

const occurrenceMark = Decoration.mark({ class: "tw-occurrence" });

function occurrences(context: LanguageContext) {
  return ViewPlugin.fromClass(
    class {
      timer: ReturnType<typeof setTimeout> | undefined;
      update(update: ViewUpdate) {
        if (!update.selectionSet && !update.docChanged) return;
        clearTimeout(this.timer);
        const view = update.view;
        const { head, empty } = view.state.selection.main;
        if (!empty) return;
        this.timer = setTimeout(async () => {
          const text = view.state.doc.toString();
          const around = await context.solvengContext().catch(() => "");
          const found = await Solveng.usages(text, around, head).catch(() => []);
          if (view.state.doc.toString() !== text || view.state.selection.main.head !== head) return;
          const here = found.filter((u) => !u.path && u.end <= text.length).sort((a, b) => a.start - b.start);
          // A lone use is just the word under the caret.
          const marks = here.length > 1 ? Decoration.set(here.map((u) => occurrenceMark.range(u.start, u.end))) : Decoration.none;
          view.dispatch({ effects: setOccurrences.of(marks) });
        }, 200);
      }
      destroy() {
        clearTimeout(this.timer);
      }
    },
  );
}

export function typstLanguage(context: LanguageContext) {
  return [
    occurrenceField,
    occurrences(context),
    autocompletion({
      override: [completionSource(context)],
      activateOnTypingDelay: 60,
      icons: true,
      maxRenderedOptions: 80,
      tooltipClass: () => "tw-completions",
      // The kind's name under the icon, read by screen readers and shown as a tooltip.
      addToOptions: [{ render: (completion) => kindLabel(completion), position: 90 }],
    }),
    fenceClosing,
    hover(context),
    docsField,
    keymap.of([
      { key: "F1", run: (view) => (void showDocs(view, context), true) },
      { key: "F12", run: (view) => (void goToDefinition(view, context), true) },
      { key: "Escape", run: (view) => (view.state.field(docsField) ? (view.dispatch({ effects: setDocs.of(null) }), true) : false) },
    ]),
    // ⌘-click (Ctrl-click elsewhere) opens the definition.
    EditorView.domEventHandlers({
      mousedown(event, view) {
        if (!(event.metaKey || event.ctrlKey) || event.button !== 0) return false;
        const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
        if (pos === null) return false;
        event.preventDefault();
        void goToDefinition(view, context, pos);
        return true;
      },
    }),
  ];
}
