// Completions, hover docs, quick docs (F1) and go to definition from typst-ide in the worker; the
// browser's stand-in for the tinymist language server the Mac app runs.
import { autocompletion, type Completion, type CompletionContext, type CompletionResult, snippet } from "@codemirror/autocomplete";
import { StateEffect, StateField } from "@codemirror/state";
import { EditorView, hoverTooltip, keymap, showTooltip, type Tooltip } from "@codemirror/view";
import { compiler, type Completion as TypstCompletion } from "../compiler";
import { settings } from "../settings";

export type LanguageContext = {
  /** The file being edited, relative to the space. */
  path: () => string;
  /** Opens a file of the space with the range selected. */
  open: (path: string, from: number, to: number) => void;
  /** Shows a short message, e.g. that a definition is in the standard library. */
  notify: (message: string) => void;
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

function toCompletion(item: TypstCompletion): Completion {
  const apply = item.apply ?? item.label;
  return {
    label: item.label,
    type: KIND[item.kind] ?? "text",
    detail: item.kind === "symbol" ? apply : undefined,
    info: item.detail ?? undefined,
    // typst-ide writes snippets as `${name}` placeholders, as CodeMirror's snippets do.
    apply: apply.includes("${") ? snippet(apply) : apply,
  };
}

function completionSource(context: LanguageContext) {
  return async (ctx: CompletionContext): Promise<CompletionResult | null> => {
    if (!settings.language) return null;
    const before = ctx.state.sliceDoc(Math.max(0, ctx.pos - 64), ctx.pos);
    // Package names complete from Typst Universe's index, fetched once on first use.
    if (/"@[\w/:.-]*$/.test(before) && !indexRequested) {
      indexRequested = true;
      await compiler.packageIndex().catch(() => (indexRequested = false));
    }
    if (!ctx.explicit && !/[\w#.@"<(:/]$/.test(before)) return null;
    const result = await compiler.complete(context.path(), ctx.pos, ctx.explicit).catch(() => null);
    if (!result || ctx.aborted) return null;
    return { from: result.from, options: result.items.map(toCompletion), validFor: /^[\p{L}\p{N}_-]*$/u };
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
  }
  return dom;
}

function hover(context: LanguageContext) {
  return hoverTooltip(
    async (_view, pos): Promise<Tooltip | null> => {
      if (!settings.language) return null;
      const value = await compiler.tooltip(context.path(), pos).catch(() => null);
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
  const value = await compiler.tooltip(context.path(), pos).catch(() => null);
  if (!value) {
    context.notify("No documentation here.");
    return false;
  }
  const dom = await docsElement(value);
  view.dispatch({ effects: setDocs.of({ pos, above: true, create: () => ({ dom }) }) });
  return true;
}

export async function goToDefinition(view: EditorView, context: LanguageContext, pos = view.state.selection.main.head) {
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

export function typstLanguage(context: LanguageContext) {
  return [
    autocompletion({ override: [completionSource(context)], activateOnTypingDelay: 60, icons: true }),
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
