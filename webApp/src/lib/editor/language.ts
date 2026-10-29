// Completions, hover docs, quick docs (F1) and go to definition from typst-ide in the worker; the
// browser's stand-in for the tinymist language server the Mac app runs.
import { compiler, type Completion as TypstCompletion } from "../compiler";
import { settings } from "../settings";
import { highlightCode } from "./highlight";
import { type CodeEditor, cssHex, monaco, range, select, selection, text } from "./monaco";
import { Solveng, type SolvengEdit } from "./solveng";

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

const Kind = monaco.languages.CompletionItemKind;

const KIND: Record<string, monaco.languages.CompletionItemKind> = {
  syntax: Kind.Keyword,
  func: Kind.Function,
  type: Kind.Class,
  param: Kind.Property,
  constant: Kind.Constant,
  path: Kind.File,
  package: Kind.Module,
  label: Kind.Reference,
  font: Kind.Text,
  symbol: Kind.Text,
};

let indexRequested = false;

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

/** An item before Monaco gets it: `boost` orders the list, `info` loads docs when the item is shown. */
type Item = {
  label: string;
  filter?: string;
  kind: monaco.languages.CompletionItemKind;
  detail?: string;
  insert: string;
  snippet: boolean;
  boost?: number;
  info?: () => Promise<string>;
  edits?: SolvengEdit[];
};

const escapeSnippet = (s: string) => s.replace(/[\\$}]/g, "\\$&");

/**
 * typst-ide's snippets (`${name}` and `#{name}` fields) in Monaco's syntax: named fields
 * become linked placeholders, empty ones tab stops, the last empty one where the caret ends.
 */
function snippet(source: string): string {
  const fields = [...source.matchAll(/[$#]\{([^}]*)\}/g)];
  const names = new Map<string, number>();
  let next = 1;
  const empty = fields.filter((f) => !f[1]).length;
  let seenEmpty = 0;
  let out = "";
  let at = 0;
  for (const f of fields) {
    out += escapeSnippet(source.slice(at, f.index));
    at = f.index! + f[0].length;
    const name = f[1];
    if (!name) {
      seenEmpty++;
      out += seenEmpty === empty && fields.length > 1 ? "$0" : `\${${next++}}`;
      continue;
    }
    if (!names.has(name)) names.set(name, next++);
    out += `\${${names.get(name)}:${escapeSnippet(name)}}`;
  }
  return out + escapeSnippet(source.slice(at));
}

/** Markdown docs, rendered when the list shows them. */
const markdownInfo = (markdown: string | null | undefined) => (markdown ? () => docsHtml({ kind: "text", value: markdown }) : undefined);

function toItem(item: TypstCompletion, context: () => Promise<string>): Item {
  const apply = item.apply ?? item.label;
  // A function's whole docs, like its hover; the item only carries the first sentence.
  const name = item.label.replace(/\.(bracket|paren)$/, "");
  const info =
    item.kind === "func"
      ? async () => {
          const docs = await typstDocs(`#${name}`, await context(), 2).catch(() => null);
          return docsHtml({ kind: "text", value: docs ?? item.detail ?? "" });
        }
      : markdownInfo(item.detail);
  const fields = /[$#]\{/.test(apply);
  return {
    label: item.label,
    kind: KIND[item.kind] ?? Kind.Text,
    detail: item.kind === "symbol" ? apply : undefined,
    info,
    insert: fields ? snippet(apply) : apply,
    snippet: fields,
  };
}

/** The call's parameters first, statements out, other values only where a positional argument fits. */
function withParameters(params: Parameters, items: TypstCompletion[], context: () => Promise<string>): Item[] {
  const own: Item[] = params.items.map((item, i) => ({
    label: item.label,
    kind: Kind.Property,
    detail: item.detail || undefined,
    info: markdownInfo(item.documentation),
    boost: 99 - i / params.items.length,
    insert: escapeSnippet(item.insert).replace("\\$0", "$0"),
    snippet: true,
  }));
  const known = new Set(own.map((o) => o.label));
  const rest = items.flatMap((item): Item[] => {
    // typst-ide's own names, for calls the bridge can't resolve.
    if (item.kind === "param") return known.has(item.label) ? [] : [toItem({ ...item, apply: (item.apply ?? item.label) + (params.comma ? ", " : "") }, context)];
    if (own.length && !params.values) return [];
    return item.kind === "syntax" && STATEMENT.test(item.label) ? [] : [toItem(item, context)];
  });
  return [...own, ...rest];
}

type Result = { from: number; to?: number; items: Item[]; exclusive?: boolean };

/** Inside solveng code, math and its calls the names, units and option values of the calculation; null elsewhere. */
async function solvengCompletions(doc: string, around: string, pos: number): Promise<Result | null> {
  const result = await Solveng.complete(doc, around, pos).catch(() => null);
  if (!result || result.from > pos) return null;
  const kind = (k: number) =>
    k === Solveng.FUNCTION ? Kind.Function : k === Solveng.UNIT ? Kind.Unit : k === Solveng.PARAMETER ? Kind.Property : k === Solveng.CONSTANT || k === Solveng.VALUE ? Kind.Constant : k === Solveng.KEYWORD ? Kind.Keyword : Kind.Variable;
  const items = result.items.map(
    (item, i): Item => ({
      label: item.label,
      // Δ_R is found by typing Delta_R, units like kΩ by typing kOmega.
      filter: item.filter,
      kind: kind(item.kind),
      detail: item.detail,
      info: item.documentation ? async () => docsHtml({ kind: "text", value: item.documentation! }) : undefined,
      boost: -i / result.items.length,
      insert: item.insert.includes("$0") ? escapeSnippet(item.insert).replace("\\$0", "$0") : item.insert,
      snippet: item.insert.includes("$0"),
      edits: item.edits,
    }),
  );
  return { from: result.from, to: result.to, items, exclusive: result.exclusive };
}

async function complete(context: LanguageContext, doc: string, pos: number, explicit: boolean, cancelled: () => boolean): Promise<Result | null> {
  if (!settings.language) return null;
  const around = await context.solvengContext();
  const solveng = await solvengCompletions(doc, around, pos);
  if (cancelled()) return null;
  if (solveng?.exclusive) return solveng.items.length || explicit ? solveng : null;
  const before = doc.slice(Math.max(0, pos - 64), pos);
  // Package names complete from Typst Universe's index, fetched once on first use.
  if (/"@[\w/:.-]*$/.test(before) && !indexRequested) {
    indexRequested = true;
    await compiler.packageIndex().catch(() => (indexRequested = false));
  }
  const params = await parameters(doc, around, pos).catch(() => null);
  if (cancelled()) return null;
  if (!explicit && !params && !/[\w#.@"<(:/]$/.test(before)) return solveng;
  const result = await compiler.complete(context.path(), pos, explicit).catch(() => null);
  if (cancelled()) return null;
  if (params) {
    const items = withParameters(params, result?.from === params.from ? result.items : [], context.solvengContext);
    return items.length ? { from: params.from, to: params.to, items } : solveng;
  }
  if (!result) return solveng;
  if (solveng?.items.length && (solveng.from !== result.from || (solveng.to ?? pos) > pos)) return solveng;
  const items = result.items.map((i) => toItem(i, context.solvengContext));
  // In math the calculation's names come before Typst's symbols.
  if (solveng && solveng.from === result.from) {
    const named = new Set(solveng.items.map((o) => o.label));
    return { from: result.from, to: solveng.to, items: [...solveng.items.map((o) => ({ ...o, boost: 50 + (o.boost ?? 0) })), ...items.filter((o) => !named.has(o.label))] };
  }
  return { from: result.from, items };
}

const infos = new WeakMap<monaco.languages.CompletionItem, () => Promise<string>>();

function completionProvider(context: LanguageContext): monaco.languages.CompletionItemProvider {
  return {
    triggerCharacters: ["#", ".", "@", '"', "<", "(", ":", "/", ",", " ", "$", "_", "`", "="],
    async provideCompletionItems(model, position, ctx, token) {
      const pos = model.getOffsetAt(position);
      const explicit = ctx.triggerKind === monaco.languages.CompletionTriggerKind.Invoke;
      const result = await complete(context, model.getValue(), pos, explicit, () => token.isCancellationRequested || model.isDisposed());
      if (!result || model.isDisposed() || result.from > pos) return null;
      const insert = range(model, result.from, pos);
      // Monaco only replaces within the caret's line.
      if (insert.startLineNumber !== position.lineNumber) return null;
      const to = Math.max(pos, Math.min(result.to ?? pos, model.getOffsetAt({ lineNumber: position.lineNumber, column: Infinity })));
      const replace = range(model, result.from, to);
      // Stable order by boost, then Monaco's own matching on what's typed.
      const ordered = result.items.map((item, i) => ({ item, i })).sort((a, b) => (b.item.boost ?? 0) - (a.item.boost ?? 0) || a.i - b.i);
      const suggestions = ordered.map(({ item }, i): monaco.languages.CompletionItem => {
        const extra = (item.edits ?? []).filter((e) => !e.path);
        const suggestion: monaco.languages.CompletionItem = {
          label: item.label,
          filterText: item.filter,
          kind: item.kind,
          detail: item.detail,
          sortText: String(i).padStart(5, "0"),
          insertText: item.insert,
          insertTextRules: item.snippet ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet : undefined,
          range: { insert, replace },
          additionalTextEdits: extra.length ? extra.map((e) => ({ range: range(model, e.start, e.end), text: e.text })) : undefined,
        };
        if (item.info) infos.set(suggestion, item.info);
        return suggestion;
      });
      return { suggestions };
    },
    async resolveCompletionItem(item) {
      const info = infos.get(item);
      if (!info) return item;
      const html = await info().catch(() => "");
      return html ? { ...item, documentation: { value: html, supportHtml: true } } : item;
    },
  };
}

async function docsElement(value: { kind: "text" | "code"; value: string }): Promise<HTMLElement> {
  const dom = document.createElement("div");
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

/**
 * Docs as HTML for Monaco's Markdown widgets, which keep inline colours but drop classes: highlighting is
 * resolved to colours, and code keeps its lines as `<br>`s, since a blank line would end the HTML.
 */
async function docsHtml(value: { kind: "text" | "code"; value: string }): Promise<string> {
  const dom = await docsElement(value);
  dom.className = "tw-docs";
  dom.style.cssText = "position:fixed;visibility:hidden;pointer-events:none";
  document.body.append(dom);
  for (const span of dom.querySelectorAll<HTMLElement>("span[class]")) {
    span.setAttribute("style", `color:${cssHex(getComputedStyle(span).color).slice(0, 7)};`);
    span.removeAttribute("class");
  }
  dom.remove();
  for (const pre of dom.querySelectorAll("pre")) pre.innerHTML = pre.innerHTML.replace(/\n/g, "<br>");
  return dom.innerHTML.replace(/\n+/g, " ");
}

/** solveng's docs for a name or unit of a calculation, else typst's. */
async function docsAt(model: monaco.editor.ITextModel, context: LanguageContext, pos: number): Promise<{ kind: "text" | "code"; value: string } | null> {
  const around = await context.solvengContext().catch(() => "");
  const doc = model.getValue();
  const solveng = await Solveng.hover(doc, around, pos).catch(() => null);
  if (solveng) return { kind: "text", value: solveng.markdown };
  // Functions and argument names from the source itself; typst-ide only knows them when the last compile got there.
  const docs = await typstDocs(doc, around, pos).catch(() => null);
  if (docs) return { kind: "text", value: docs };
  return compiler.tooltip(context.path(), pos).catch(() => null);
}

function hoverProvider(context: LanguageContext): monaco.languages.HoverProvider {
  return {
    async provideHover(model, position) {
      if (!settings.language) return null;
      const value = await docsAt(model, context, model.getOffsetAt(position));
      if (!value || model.isDisposed()) return null;
      return { contents: [{ value: await docsHtml(value), supportHtml: true }] };
    },
  };
}

/** Quick docs at the caret, in Monaco's hover until the caret moves. */
export async function showDocs(editor: CodeEditor, context: LanguageContext): Promise<boolean> {
  const model = editor.getModel();
  if (!model) return false;
  const value = await docsAt(model, context, selection(editor).head);
  if (!value) {
    context.notify("No documentation here.");
    return false;
  }
  editor.trigger("keyboard", "editor.action.showHover", { focus: false });
  return true;
}

export async function goToDefinition(editor: CodeEditor, context: LanguageContext, pos = selection(editor).head) {
  // solveng's names; on the definition itself its usages.
  const around = await context.solvengContext().catch(() => "");
  const solveng = await Solveng.definition(text(editor), around, pos).catch(() => null);
  if (solveng) {
    if (!solveng.path && solveng.start <= pos && pos <= solveng.end) return context.showSolvengUsages(pos);
    if (solveng.path && solveng.path !== context.path()) return context.open(solveng.path, solveng.start, solveng.end);
    select(editor, [{ anchor: solveng.start, head: solveng.end }]);
    return editor.focus();
  }
  const location = await compiler.definition(context.path(), pos).catch(() => null);
  if (!location) return context.notify("No definition found.");
  if ("std" in location) return context.notify(`${location.std ?? "This"} is part of Typst's standard library.`);
  if (location.package) return context.notify(`Defined in the package ${location.path}.`);
  if (location.path === context.path()) {
    select(editor, [{ anchor: location.from, head: location.to }]);
    editor.focus();
  } else {
    context.open(location.path, location.from, location.to);
  }
}

/** The uses of the solveng name at the caret that belong to the same definition, marked like IntelliJ does. */
function occurrences(editor: CodeEditor, context: LanguageContext): monaco.IDisposable {
  const marks = editor.createDecorationsCollection();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const update = () => {
    clearTimeout(timer);
    marks.clear();
    const { head, empty } = selection(editor);
    const model = editor.getModel();
    if (!empty || !model) return;
    timer = setTimeout(async () => {
      const doc = model.getValue();
      const around = await context.solvengContext().catch(() => "");
      const found = await Solveng.usages(doc, around, head).catch(() => []);
      if (editor.getModel() !== model || model.getValue() !== doc || selection(editor).head !== head) return;
      const here = found.filter((u) => !u.path && u.end <= doc.length).sort((a, b) => a.start - b.start);
      // A lone use is just the word under the caret.
      if (here.length > 1) marks.set(here.map((u) => ({ range: range(model, u.start, u.end), options: { inlineClassName: "tw-occurrence" } })));
    }, 200);
  };
  const listeners = [editor.onDidChangeCursorPosition(update), editor.onDidChangeModelContent(update)];
  return {
    dispose() {
      clearTimeout(timer);
      listeners.forEach((l) => l.dispose());
      marks.clear();
    },
  };
}

/** Providers for typst files, shared by every editor. */
export function registerTypst(context: LanguageContext): monaco.IDisposable[] {
  return [monaco.languages.registerCompletionItemProvider("typst", completionProvider(context)), monaco.languages.registerHoverProvider("typst", hoverProvider(context))];
}

/** Keys for typst in `editor`; ⌘-click goes to definitions through `carets`. */
export function typstEditor(editor: CodeEditor, context: LanguageContext): monaco.IDisposable[] {
  const { KeyCode } = monaco;
  const when = "editorTextFocus && typewright.typst";
  return [
    occurrences(editor, context),
    editor.addAction({ id: "typewright.docs", label: "Show Documentation", keybindings: [KeyCode.F1], precondition: when, run: () => void showDocs(editor, context) }),
    editor.addAction({ id: "typewright.definition", label: "Go to Definition", keybindings: [KeyCode.F12], precondition: when, run: () => void goToDefinition(editor, context) }),
  ];
}
