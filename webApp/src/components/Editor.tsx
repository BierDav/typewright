import { acceptCompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab, selectAll } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { bracketMatching, codeFolding, foldGutter, foldKeymap, HighlightStyle, indentOnInput, StreamLanguage, syntaxHighlighting } from "@codemirror/language";
import { type Diagnostic as LintDiagnostic, lintGutter, lintKeymap, setDiagnostics } from "@codemirror/lint";
import { highlightSelectionMatches, search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorSelection, EditorState, type Extension } from "@codemirror/state";
import {
  crosshairCursor,
  drawSelection,
  dropCursor,
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  keymap,
  lineNumbers,
  placeholder,
  rectangularSelection,
} from "@codemirror/view";
import { tags } from "@lezer/highlight";
import { vim } from "@replit/codemirror-vim";
import { createEffect, on, onCleanup, onMount } from "solid-js";
import { isMac, setEditorView, shortcut } from "~/lib/app";
import * as commands from "~/lib/commands";
import { colorSwatches } from "~/lib/editor/colors";
import { typstFolding } from "~/lib/editor/folding";
import { refreshHighlights, typstHighlighting } from "~/lib/editor/highlight";
import { typstLanguage } from "~/lib/editor/language";
import { liveEditing } from "~/lib/editor/live";
import { typing } from "~/lib/editor/typing";
import { download as downloadFont, googleFont, loadCatalog } from "~/lib/fonts";
import { isEditable, isMarkdown } from "~/lib/kinds";
import { settings } from "~/lib/settings";
import { extension } from "~/lib/storage";
import type { Workspace } from "~/lib/workspace";
import { ArrowUpRight, BookOpen, ClipboardPaste, Copy, Pencil, Replace, Scissors, Search, SquareFunction, TextSelect, Variable, WandSparkles } from "./icons";
import { type MenuItem, showMenu } from "./Menu";

/** Typst for CodeMirror's commands: comments, brackets and indentation; colours come from typst itself. */
const typstSyntax = StreamLanguage.define({
  token(stream) {
    stream.skipToEnd();
    return null;
  },
  languageData: {
    commentTokens: { line: "//", block: { open: "/*", close: "*/" } },
    closeBrackets: { brackets: ["(", "[", "{", '"', "$"] },
    indentOnInput: /^\s*[\]})]$/,
  },
});

const markdownStyle = HighlightStyle.define([
  { tag: tags.heading, class: "tw-keyword tw-bold" },
  { tag: tags.emphasis, class: "tw-italic" },
  { tag: tags.strong, class: "tw-bold" },
  { tag: [tags.link, tags.url], class: "tw-link" },
  { tag: [tags.monospace, tags.string], class: "tw-string" },
  { tag: [tags.processingInstruction, tags.list, tags.quote], class: "tw-keyword" },
  { tag: tags.comment, class: "tw-comment" },
]);

function languageFor(path: string): Extension {
  const ext = extension(path);
  if (ext === "typ" || ext === "typc") {
    return [typing("typst"), typstSyntax, typstFolding, typstHighlighting(ext === "typc", commands.languageContext().solvengContext), typstLanguage(commands.languageContext()), colorSwatches];
  }
  if (isMarkdown(path)) return [typing("markdown"), markdown(), syntaxHighlighting(markdownStyle)];
  return [typing("")];
}

/** A chevron like the file tree's, shown while the gutter is hovered or the range is folded. */
function foldMarker(open: boolean): HTMLElement {
  const el = document.createElement("span");
  el.className = open ? "tw-fold open" : "tw-fold";
  el.innerHTML = `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>`;
  return el;
}

/** Cut, copy and paste plus the language's commands, at the pointer. */
function contextMenu(event: MouseEvent, view: EditorView, path: string) {
  // A click outside the selection moves the caret there first, as native editors do.
  const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
  const main = view.state.selection.main;
  if (pos !== null && (pos < main.from || pos > main.to)) view.dispatch({ selection: { anchor: pos } });
  const selected = !view.state.selection.main.empty;
  const readOnly = view.state.readOnly;
  const typst = extension(path) === "typ";
  const copy = async (cut: boolean) => {
    const { from, to } = view.state.selection.main;
    await navigator.clipboard.writeText(view.state.sliceDoc(from, to)).catch(() => undefined);
    if (cut) view.dispatch({ changes: { from, to }, userEvent: "delete.cut" });
    view.focus();
  };
  const items: MenuItem[] = [
    { label: "Cut", icon: Scissors, shortcut: shortcut("⌘X"), disabled: !selected || readOnly, action: () => void copy(true) },
    { label: "Copy", icon: Copy, shortcut: shortcut("⌘C"), disabled: !selected, action: () => void copy(false) },
    {
      label: "Paste",
      icon: ClipboardPaste,
      shortcut: shortcut("⌘V"),
      disabled: readOnly,
      action: async () => {
        const text = await navigator.clipboard.readText().catch(() => null);
        if (text) view.dispatch(view.state.replaceSelection(text), { userEvent: "input.paste", scrollIntoView: true });
        view.focus();
      },
    },
    { label: "Select All", icon: TextSelect, shortcut: shortcut("⌘A"), action: () => (selectAll(view), view.focus()) },
    { separator: true },
  ];
  if (typst) {
    items.push(
      { label: "Go to Definition", icon: ArrowUpRight, shortcut: "F12", action: () => commands.definition() },
      { label: "Show Documentation", icon: BookOpen, shortcut: "F1", action: () => commands.quickDocs() },
      { separator: true },
      { label: "Rename Symbol…", icon: Pencil, shortcut: "F2", disabled: readOnly, action: () => commands.rename() },
      { label: "Extract Variable", icon: Variable, shortcut: shortcut("⌘⌥V"), disabled: readOnly, action: () => void commands.extractVariable() },
      { label: "Extract Function", icon: SquareFunction, shortcut: shortcut("⌘⌥M"), disabled: readOnly, action: () => void commands.extractFunction() },
      { label: "Format Document", icon: WandSparkles, shortcut: shortcut("⌘⌥L"), disabled: readOnly, action: () => void commands.formatDocument() },
      { separator: true },
    );
  }
  items.push(
    { label: "Find…", icon: Search, shortcut: shortcut("⌘F"), action: () => commands.find() },
    { label: "Find and Replace…", icon: Replace, shortcut: shortcut("⌘⌥F"), disabled: readOnly, action: () => commands.find(true) },
  );
  showMenu(event, items);
}

function theme(): Extension {
  return EditorView.theme({
    "&": { fontSize: `${settings.fontSize}px` },
  });
}

function wrapping(): Extension {
  if (!settings.wrapGuide) return [];
  // Lines wrap at the guide, or at the edge when the editor is narrower.
  return [EditorView.lineWrapping, EditorView.theme({ ".cm-content": { maxWidth: `${settings.wrapColumn}ch` } }), EditorView.editorAttributes.of({ class: "tw-wrap-guide" })];
}

/** Images on a paste or drop; text on the clipboard wins over a picture, except for copied image files. */
function images(data: DataTransfer | null): File[] {
  if (!data) return [];
  const files = [...data.files].filter((f) => f.type.startsWith("image/"));
  const text = data.getData("text/plain");
  return files.filter((f) => !text || (f.name && f.name !== "image.png"));
}

/** A diagnostic's line and column (from 1, UTF-16) as a range over the token there. */
function diagnosticRange(state: EditorState, line: number, column: number, length?: number | null): { from: number; to: number } {
  const l = state.doc.line(Math.min(Math.max(line, 1), state.doc.lines));
  const from = Math.min(l.from + Math.max(column - 1, 0), l.to);
  const rest = state.sliceDoc(from, l.to);
  const word = /^[\p{L}\p{N}_-]+/u.exec(rest)?.[0].length ?? 1;
  return { from, to: Math.min(from + Math.max(length ?? word, 0), l.to) };
}

export default function Editor(props: { workspace: Workspace }) {
  let host!: HTMLDivElement;
  let view: EditorView | undefined;
  const ws = props.workspace;
  const states = new Map<string, EditorState>();
  const language = new Compartment();
  const live = new Compartment();
  const themeSlot = new Compartment();
  const vimSlot = new Compartment();
  const wrapSlot = new Compartment();
  let current: string | null = null;
  let applyingExternal = false;
  let saveTimer: ReturnType<typeof setTimeout> | undefined;

  function extensions(path: string): Extension[] {
    return [
      vimSlot.of(settings.vim ? vim() : []),
      lineNumbers(),
      codeFolding({ placeholderText: "…" }),
      foldGutter({ markerDOM: foldMarker }),
      highlightActiveLineGutter(),
      highlightSpecialChars(),
      history(),
      drawSelection(),
      dropCursor(),
      EditorState.allowMultipleSelections.of(true),
      indentOnInput(),
      bracketMatching(),
      closeBrackets(),
      rectangularSelection(),
      crosshairCursor(),
      highlightActiveLine(),
      highlightSelectionMatches(),
      search({ top: true }),
      lintGutter(),
      placeholder(isMarkdown(path) ? "Start writing…" : extension(path) === "typ" ? `Start writing, or press ${isMac ? "⌃Space" : "Ctrl+Space"} for completions…` : ""),
      keymap.of([
        // Tab takes the highlighted completion; without a list it indents.
        { key: "Tab", run: acceptCompletion },
        { key: "Mod-Alt-l", run: () => (void commands.formatDocument(), true) },
        { key: "Shift-F6", run: () => (commands.rename(), true) },
        { key: "F2", run: () => (commands.rename(), true) },
        { key: "Mod-Alt-v", run: () => (void commands.extractVariable(), true) },
        { key: "Mod-Alt-m", run: () => (void commands.extractFunction(), true) },
        { key: "Mod-Alt-Shift-m", run: () => (void commands.extractFunction(true), true) },
        { key: "Mod-Alt-n", run: () => (commands.inlineVariable(), true) },
        { key: "Alt-Enter", run: () => (void commands.contextActions(), true) },
        { key: "Mod-Alt-f", run: () => (commands.find(true), true) },
        ...closeBracketsKeymap,
        ...defaultKeymap,
        ...searchKeymap,
        ...historyKeymap,
        ...completionKeymap,
        ...lintKeymap,
        ...foldKeymap,
        indentWithTab,
      ]),
      language.of(languageFor(path)),
      live.of(liveEditing(ws.folder, path)),
      themeSlot.of(theme()),
      wrapSlot.of(wrapping()),
      EditorView.updateListener.of((update) => {
        if (current !== path) return;
        if (update.docChanged && !applyingExternal) {
          const immediate = update.transactions.some((tr) => tr.isUserEvent("input.color"));
          ws.textDidChange(update.state.doc.toString(), immediate);
          // Undoing a pasted image's reference takes the image away too; redo brings it back.
          const undo = update.transactions.some((tr) => tr.isUserEvent("undo"));
          const redo = update.transactions.some((tr) => tr.isUserEvent("redo"));
          if (undo || redo) ws.editorDidUndo(redo, update.state.doc.toString());
        }
        if (update.selectionSet || update.docChanged) {
          const main = update.state.selection.main;
          ws.setSelection(main.from, main.to);
        }
        if (update.selectionSet || update.geometryChanged) rememberState();
      }),
      EditorView.domEventHandlers({
        scroll: () => rememberState(),
        contextmenu: (event, view) => {
          // ⇧ right-click keeps the browser's own menu, for spelling suggestions and the like.
          if (event.shiftKey) return false;
          contextMenu(event, view, path);
          return true;
        },
        paste: (event, view) => {
          const files = images(event.clipboardData);
          if (!files.length) return false;
          event.preventDefault();
          const { from, to } = view.state.selection.main;
          void insertImages(view, path, files, from, to);
          return true;
        },
        drop: (event, view) => {
          const files = images(event.dataTransfer);
          if (!files.length) return false;
          event.preventDefault();
          const at = view.posAtCoords({ x: event.clientX, y: event.clientY }) ?? view.state.selection.main.head;
          void insertImages(view, path, files, at, at);
          return true;
        },
      }),
    ];
  }

  /** Saves the images next to the file and puts their reference in as one undo step. */
  async function insertImages(view: EditorView, path: string, files: File[], from: number, to: number) {
    if (!isMarkdown(path) && extension(path) !== "typ") return;
    const reference = await ws.saveImages(files, path);
    if (!reference || current !== path) return;
    // A `#` typed just before keeps the call from getting two.
    const text = from > 0 && view.state.sliceDoc(from - 1, from) === "#" && reference.startsWith("#") ? reference.slice(1) : reference;
    view.dispatch({ changes: { from, to, insert: text }, selection: { anchor: from + text.length }, userEvent: "input.paste" });
    view.focus();
  }

  function rememberState() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      if (!view || !current) return;
      const main = view.state.selection.main;
      ws.saveEditorState(current, { anchor: main.anchor, head: main.head, scroll: view.scrollDOM.scrollTop });
    }, 300);
  }

  function show(path: string | null, text: string) {
    if (!view) return;
    if (current) states.set(current, view.state);
    // Other kinds show elsewhere; the editor keeps its states for when a text file returns.
    current = path && isEditable(ws.state.selectedKind) ? path : null;
    if (!path || !current) return;
    let state = states.get(path);
    if (!state || state.doc.toString() !== text) {
      // A file changed elsewhere since it was shown starts a fresh history.
      state = EditorState.create({ doc: text, extensions: extensions(path) });
      const saved = ws.editorState(path);
      if (saved && saved.head <= text.length && saved.anchor <= text.length) {
        state = state.update({ selection: EditorSelection.single(saved.anchor, saved.head) }).state;
      }
    }
    view.setState(state);
    const saved = ws.editorState(path);
    requestAnimationFrame(() => {
      if (view && saved && current === path) view.scrollDOM.scrollTop = saved.scroll;
    });
  }

  onMount(() => {
    view = new EditorView({ parent: host });
    setEditorView(view);
    ws.currentText = () => (view && current === ws.state.selected ? view.state.doc.toString() : ws.state.text);
    show(ws.state.selected, ws.state.text);
    view.focus();
  });

  onCleanup(() => {
    clearTimeout(saveTimer);
    if (view && current) {
      const main = view.state.selection.main;
      ws.saveEditorState(current, { anchor: main.anchor, head: main.head, scroll: view.scrollDOM.scrollTop });
    }
    setEditorView(null);
    view?.destroy();
  });

  createEffect(on(() => ws.state.selected, (path) => show(path, ws.state.text), { defer: true }));
  createEffect(on(() => [ws.state.solvengReport, ws.state.solvengFileReport], () => view?.dispatch({ effects: refreshHighlights.of(null) }), { defer: true }));

  // The file changed outside the editor: sync, another tab or a refactoring elsewhere.
  createEffect(
    on(
      ws.external,
      () => {
        if (!view || current !== ws.state.selected) return;
        const text = ws.state.text;
        const old = view.state.doc.toString();
        if (old === text) return;
        let from = 0;
        while (from < old.length && from < text.length && old[from] === text[from]) from++;
        let end = 0;
        while (end < old.length - from && end < text.length - from && old[old.length - 1 - end] === text[text.length - 1 - end]) end++;
        applyingExternal = true;
        view.dispatch({ changes: { from, to: old.length - end, insert: text.slice(from, text.length - end) }, userEvent: "external" });
        applyingExternal = false;
      },
      { defer: true },
    ),
  );

  createEffect(() => view?.dispatch({ effects: themeSlot.reconfigure(theme()) }));
  createEffect(() => view?.dispatch({ effects: vimSlot.reconfigure(settings.vim ? vim() : []) }));
  createEffect(() => view?.dispatch({ effects: wrapSlot.reconfigure(wrapping()) }));

  // Diagnostics of the shown file, with fixes for missing fonts.
  createEffect(() => {
    const diagnostics = ws.state.diagnostics.filter((d) => d.path === ws.state.selected);
    if (!view) return;
    const state = view.state;
    const items: LintDiagnostic[] = diagnostics.map((d) => {
      const { from, to } = diagnosticRange(state, d.line, d.column, d.length);
      const font = /^unknown font family: (.+)$/.exec(d.message)?.[1]?.trim();
      const actions: NonNullable<LintDiagnostic["actions"]>[number][] = [];
      if (font) {
        void loadCatalog();
        if (googleFont(font)) actions.push({ name: `Install “${googleFont(font)!.family}” from Google Fonts`, apply: () => void downloadFont(googleFont(font)!.family).then(() => ws.updateFonts()) });
      }
      return { from, to, severity: d.severity, message: d.message, actions };
    });
    // The compile reports solveng's problems too once it's caught up; the same message on a line counts once.
    const seen = new Set(items.map((d) => `${state.doc.lineAt(d.from).number}:${d.message}`));
    for (const d of ws.state.solvengDiagnostics) {
      if (d.to > state.doc.length || seen.has(`${state.doc.lineAt(d.from).number}:${d.message}`)) continue;
      items.push({ from: d.from, to: d.to, severity: d.severity, message: d.message });
    }
    view.dispatch(setDiagnostics(state, items));
  });

  // Reveals from diagnostics, search results and definitions.
  createEffect(() => {
    const reveal = ws.state.reveal;
    if (!view || !reveal || reveal.path !== current) return;
    const state = view.state;
    let from = Math.min(reveal.from, state.doc.length);
    let to = Math.min(reveal.to ?? from, state.doc.length);
    if (reveal.line) {
      const l = state.doc.line(Math.min(Math.max(reveal.line, 1), state.doc.lines));
      from = Math.min(l.from + Math.max((reveal.column ?? 1) - 1, 0), l.to);
      to = reveal.to ?? from;
    }
    view.dispatch({ selection: EditorSelection.single(from, to), effects: EditorView.scrollIntoView(from, { y: "center" }) });
    view.focus();
  });

  return <div class="editor" ref={host} />;
}
