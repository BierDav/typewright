import { initVimMode } from "monaco-vim";
import { createEffect, on, onCleanup, onMount } from "solid-js";
import { isMac, setEditorView, shortcut } from "~/lib/app";
import * as commands from "~/lib/commands";
import { registerColors } from "~/lib/editor/colors";
import { registerFolding } from "~/lib/editor/folding";
import { typstHighlighting } from "~/lib/editor/highlight";
import { registerTypst, typstEditor } from "~/lib/editor/language";
import { liveEditing } from "~/lib/editor/live";
import { applyTheme, type CodeEditor, edit, monaco, range, select, selection } from "~/lib/editor/monaco";
import { fenceClosing } from "~/lib/editor/solveng";
import { type Syntax, typing } from "~/lib/editor/typing";
import { download as downloadFont, googleFont, loadCatalog } from "~/lib/fonts";
import { isEditable, isMarkdown } from "~/lib/kinds";
import { isDark, settings } from "~/lib/settings";
import { extension } from "~/lib/storage";
import type { Workspace } from "~/lib/workspace";
import { ArrowUpRight, BookOpen, ClipboardPaste, Copy, Pencil, Replace, Scissors, Search, SquareFunction, TextSelect, Variable, WandSparkles } from "./icons";
import { type MenuItem, showMenu } from "./Menu";

function languageOf(path: string): string {
  const ext = extension(path);
  if (ext === "typ" || ext === "typc") return "typst";
  return isMarkdown(path) ? "markdown" : "plaintext";
}

function syntaxOf(path: string | null): Syntax {
  if (!path) return "";
  const language = languageOf(path);
  return language === "typst" ? "typst" : language === "markdown" ? "markdown" : "";
}

/** Cut, copy and paste plus the language's commands, at the pointer. */
function contextMenu(event: MouseEvent, editor: CodeEditor, path: string) {
  const model = editor.getModel();
  if (!model) return;
  // A click outside the selection moves the caret there first, as native editors do.
  const target = editor.getTargetAtClientPoint(event.clientX, event.clientY)?.position;
  const main = selection(editor);
  const pos = target ? model.getOffsetAt(target) : null;
  if (pos !== null && (pos < main.from || pos > main.to)) select(editor, [{ anchor: pos, head: pos }]);
  const { from, to, empty } = selection(editor);
  const readOnly = editor.getOption(monaco.editor.EditorOption.readOnly);
  const typst = extension(path) === "typ";
  const copy = async (cut: boolean) => {
    await navigator.clipboard.writeText(model.getValueInRange(range(model, from, to))).catch(() => undefined);
    if (cut) edit(editor, [{ from, to, insert: "" }], [{ anchor: from, head: from }], "delete.cut");
    editor.focus();
  };
  const items: MenuItem[] = [
    { label: "Cut", icon: Scissors, shortcut: shortcut("⌘X"), disabled: empty || readOnly, action: () => void copy(true) },
    { label: "Copy", icon: Copy, shortcut: shortcut("⌘C"), disabled: empty, action: () => void copy(false) },
    {
      label: "Paste",
      icon: ClipboardPaste,
      shortcut: shortcut("⌘V"),
      disabled: readOnly,
      action: async () => {
        const text = await navigator.clipboard.readText().catch(() => null);
        if (text) editor.executeEdits("input.paste", (editor.getSelections() ?? []).map((s) => ({ range: s, text, forceMoveMarkers: true })));
        editor.focus();
      },
    },
    { label: "Select All", icon: TextSelect, shortcut: shortcut("⌘A"), action: () => (editor.setSelection(model.getFullModelRange()), editor.focus()) },
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

/** Images on a paste or drop; text on the clipboard wins over a picture, except for copied image files. */
function images(data: DataTransfer | null): File[] {
  if (!data) return [];
  const files = [...data.files].filter((f) => f.type.startsWith("image/"));
  const text = data.getData("text/plain");
  return files.filter((f) => !text || (f.name && f.name !== "image.png"));
}

/** A diagnostic's line and column (from 1, UTF-16) as a range over the token there. */
function diagnosticRange(model: monaco.editor.ITextModel, line: number, column: number, length?: number | null): monaco.IRange {
  const lineNumber = Math.min(Math.max(line, 1), model.getLineCount());
  const content = model.getLineContent(lineNumber);
  const start = Math.min(Math.max(column - 1, 0), content.length);
  const word = /^[\p{L}\p{N}_-]+/u.exec(content.slice(start))?.[0].length ?? 1;
  const end = Math.min(start + Math.max(length ?? word, 0), content.length);
  return { startLineNumber: lineNumber, startColumn: start + 1, endLineNumber: lineNumber, endColumn: end + 1 };
}

let modelCount = 0;

export default function Editor(props: { workspace: Workspace }) {
  let host!: HTMLDivElement;
  let vimStatus!: HTMLDivElement;
  let editor: CodeEditor | undefined;
  const ws = props.workspace;
  const id = ++modelCount;
  /** Each file's model (with its undo history) and view state, for when it's shown again. */
  const models = new Map<string, { model: monaco.editor.ITextModel; view: monaco.editor.ICodeEditorViewState | null }>();
  let current: string | null = null;
  let applyingExternal = false;
  let saveTimer: ReturnType<typeof setTimeout> | undefined;
  let highlighter: ReturnType<typeof typstHighlighting> | null = null;
  let perModel: monaco.IDisposable[] = [];
  const disposables: monaco.IDisposable[] = [];
  let vim: ReturnType<typeof initVimMode> | null = null;
  let typstKey: monaco.editor.IContextKey<boolean> | undefined;
  let insertKey: monaco.editor.IContextKey<boolean> | undefined;

  function rememberState() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(saveState, 300);
  }

  function saveState() {
    if (!editor || !current || !editor.getModel()) return;
    const { anchor, head } = selection(editor);
    ws.saveEditorState(current, { anchor, head, scroll: editor.getScrollTop() });
  }

  function placeholder(path: string): string {
    if (isMarkdown(path)) return "Start writing…";
    return extension(path) === "typ" ? `Start writing, or press ${isMac ? "⌃Space" : "Ctrl+Space"} for completions…` : "";
  }

  function show(path: string | null, text: string) {
    if (!editor) return;
    if (current && models.has(current)) models.get(current)!.view = editor.saveViewState();
    // Other kinds show elsewhere; the editor keeps its models for when a text file returns.
    current = path && isEditable(ws.state.selectedKind) ? path : null;
    if (!path || !current) return;
    let entry = models.get(path);
    if (entry && entry.model.getValue() !== text) {
      // A file changed elsewhere since it was shown starts a fresh history.
      entry.model.dispose();
      entry = undefined;
    }
    const saved = ws.editorState(path);
    perModel.forEach((d) => d.dispose());
    perModel = [];
    highlighter = null;
    if (entry) {
      editor.setModel(entry.model);
      if (entry.view) editor.restoreViewState(entry.view);
    } else {
      const uri = monaco.Uri.from({ scheme: "typewright", path: `/${id}/${path}` });
      monaco.editor.getModel(uri)?.dispose();
      const model = monaco.editor.createModel(text, languageOf(path), uri);
      models.set(path, (entry = { model, view: null }));
      editor.setModel(model);
      if (saved && saved.head <= text.length && saved.anchor <= text.length) {
        select(editor, [{ anchor: saved.anchor, head: saved.head }]);
        requestAnimationFrame(() => {
          if (editor && current === path) editor.setScrollTop(saved.scroll);
        });
      }
    }
    editor.updateOptions({ placeholder: placeholder(path) });
    typstKey?.set(languageOf(path) === "typst");
    const ext = extension(path);
    if (ext === "typ" || ext === "typc") {
      highlighter = typstHighlighting(editor, ext === "typc", commands.languageContext().solvengContext);
      perModel.push(highlighter);
    }
    perModel.push(liveEditing(editor, ws.folder, path));
    const { from, to } = selection(editor);
    ws.setSelection(from, to);
  }

  /** Saves the images next to the file and puts their reference in as one undo step. */
  async function insertImages(path: string, files: File[], from: number, to: number) {
    if (!editor || (!isMarkdown(path) && extension(path) !== "typ")) return;
    const reference = await ws.saveImages(files, path);
    const model = editor.getModel();
    if (!reference || current !== path || !model) return;
    // A `#` typed just before keeps the call from getting two.
    const before = from > 0 ? model.getValue().slice(from - 1, from) : "";
    const text = before === "#" && reference.startsWith("#") ? reference.slice(1) : reference;
    edit(editor, [{ from, to, insert: text }], [{ anchor: from + text.length, head: from + text.length }], "input.paste");
    editor.focus();
  }

  function setVim(on: boolean) {
    if (!editor) return;
    if (on && !vim) {
      vim = initVimMode(editor, vimStatus);
      insertKey?.set(false);
      // Enter and Backspace are vim's own outside insert mode.
      vim.on("vim-mode-change", (event: { mode: string }) => insertKey?.set(event.mode === "insert" || event.mode === "replace"));
    } else if (!on && vim) {
      vim.dispose();
      vim = null;
      insertKey?.set(true);
    }
    vimStatus.hidden = !on;
  }

  function wrapOptions(): monaco.editor.IEditorOptions {
    // Lines wrap at the guide, or at the edge when the editor is narrower.
    return settings.wrapGuide
      ? { wordWrap: "bounded", wordWrapColumn: settings.wrapColumn, rulers: [settings.wrapColumn] }
      : { wordWrap: "off", rulers: [] };
  }

  // Popups live outside the window's transformed panes, where fixed positions are the page's.
  const overflow = document.createElement("div");
  overflow.className = "monaco-editor tw-overflow";

  onMount(() => {
    applyTheme(isDark());
    document.body.append(overflow);
    const mono = getComputedStyle(document.documentElement).getPropertyValue("--mono").trim();
    editor = monaco.editor.create(host, {
      model: null,
      automaticLayout: true,
      fontFamily: mono,
      fontSize: settings.fontSize,
      lineHeight: 1.55,
      padding: { top: 12 },
      minimap: { enabled: false },
      scrollBeyondLastLine: true,
      renderLineHighlight: "line",
      showFoldingControls: "mouseover",
      foldingHighlight: false,
      lineNumbersMinChars: 3,
      lineDecorationsWidth: 12,
      glyphMargin: false,
      contextmenu: false,
      fixedOverflowWidgets: true,
      overflowWidgetsDomNode: overflow,
      occurrencesHighlight: "off",
      selectionHighlight: true,
      wordBasedSuggestions: "off",
      quickSuggestions: { other: true, comments: false, strings: true },
      quickSuggestionsDelay: 60,
      suggest: { showWords: false, preview: false, showStatusBar: false, selectionMode: "always" },
      hover: { delay: 400, above: true },
      colorDecorators: true,
      defaultColorDecorators: "never",
      colorDecoratorsActivatedOn: "click",
      guides: { indentation: false },
      stickyScroll: { enabled: false },
      bracketPairColorization: { enabled: false },
      matchBrackets: "always",
      cursorSmoothCaretAnimation: "on",
      cursorBlinking: "smooth",
      overviewRulerBorder: false,
      hideCursorInOverviewRuler: true,
      scrollbar: { useShadows: false, verticalScrollbarSize: 10, horizontalScrollbarSize: 10 },
      tabSize: 2,
      links: false,
      ...wrapOptions(),
    });
    typstKey = editor.createContextKey("typewright.typst", false);
    insertKey = editor.createContextKey("typewright.insert", true);
    setEditorView(editor);
    const context = commands.languageContext();
    const { KeyMod, KeyCode } = monaco;
    const action = (id: string, keybindings: number[], run: () => void, precondition = "editorTextFocus") =>
      editor!.addAction({ id: `typewright.${id}`, label: id, keybindings, precondition, run });
    disposables.push(
      ...registerTypst(context),
      registerColors(),
      registerFolding(),
      ...typing(editor, () => syntaxOf(current)),
      ...typstEditor(editor, context, () => languageOf(current ?? "") === "typst"),
      fenceClosing(editor),
      action("format", [KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.KeyL], () => void commands.formatDocument()),
      action("rename", [KeyMod.Shift | KeyCode.F6, KeyCode.F2], () => commands.rename(), "editorTextFocus && typewright.typst"),
      action("extractVariable", [KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.KeyV], () => void commands.extractVariable()),
      action("extractFunction", [KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.KeyM], () => void commands.extractFunction()),
      action("extractFunctionTo", [KeyMod.CtrlCmd | KeyMod.Alt | KeyMod.Shift | KeyCode.KeyM], () => void commands.extractFunction(true)),
      action("inlineVariable", [KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.KeyN], () => commands.inlineVariable()),
      action("contextActions", [KeyMod.Alt | KeyCode.Enter], () => void commands.contextActions(), "editorTextFocus && !findWidgetVisible"),
      action("replace", [KeyMod.CtrlCmd | KeyMod.Alt | KeyCode.KeyF], () => commands.find(true)),
      // Fixes for missing fonts, offered on their diagnostics.
      monaco.editor.registerCommand("typewright.installFont", (_, family: string) => void downloadFont(family).then(() => ws.updateFonts())),
      monaco.languages.registerCodeActionProvider("typst", {
        provideCodeActions(_model, _range, ctx) {
          const actions = ctx.markers.flatMap((marker) => {
            const font = /^unknown font family: (.+)$/.exec(marker.message)?.[1]?.trim();
            const family = font ? googleFont(font)?.family : undefined;
            return family ? [{ title: `Install “${family}” from Google Fonts`, kind: "quickfix", diagnostics: [marker], isPreferred: true, command: { id: "typewright.installFont", title: "Install", arguments: [family] } }] : [];
          });
          return { actions, dispose() {} };
        },
      }),
      editor.onDidChangeModelContent((event) => {
        if (!editor || !current || applyingExternal) return;
        const text = editor.getModel()!.getValue();
        // The colour picker's edits show at once, so the preview follows the drag.
        ws.textDidChange(text, !!host.querySelector(".colorpicker-widget"));
        // Undoing a pasted image's reference takes the image away too; redo brings it back.
        if (event.isUndoing || event.isRedoing) ws.editorDidUndo(event.isRedoing, text);
      }),
      editor.onDidChangeCursorSelection(() => {
        if (!editor || !current) return;
        const { from, to } = selection(editor);
        ws.setSelection(from, to);
        rememberState();
      }),
      editor.onDidScrollChange(() => rememberState()),
    );

    host.addEventListener(
      "contextmenu",
      (event) => {
        // ⇧ right-click keeps the browser's own menu, for spelling suggestions and the like.
        if (event.shiftKey || !editor || !current) return;
        event.preventDefault();
        event.stopPropagation();
        contextMenu(event, editor, current);
      },
      true,
    );
    host.addEventListener(
      "paste",
      (event) => {
        const files = images(event.clipboardData);
        if (!files.length || !editor || !current) return;
        event.preventDefault();
        event.stopPropagation();
        const { from, to } = selection(editor);
        void insertImages(current, files, from, to);
      },
      true,
    );
    host.addEventListener("dragover", (event) => {
      if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
    });
    host.addEventListener(
      "drop",
      (event) => {
        const files = images(event.dataTransfer);
        if (!files.length || !editor || !current) return;
        event.preventDefault();
        event.stopPropagation();
        const model = editor.getModel()!;
        const target = editor.getTargetAtClientPoint(event.clientX, event.clientY)?.position;
        const at = target ? model.getOffsetAt(target) : selection(editor).head;
        void insertImages(current, files, at, at);
      },
      true,
    );

    ws.currentText = () => (editor?.getModel() && current === ws.state.selected ? editor.getModel()!.getValue() : ws.state.text);
    show(ws.state.selected, ws.state.text);
    editor.focus();
  });

  onCleanup(() => {
    clearTimeout(saveTimer);
    saveState();
    setEditorView(null);
    perModel.forEach((d) => d.dispose());
    disposables.forEach((d) => d.dispose());
    vim?.dispose();
    editor?.dispose();
    overflow.remove();
    for (const { model } of models.values()) model.dispose();
  });

  createEffect(on(() => ws.state.selected, (path) => show(path, ws.state.text), { defer: true }));
  createEffect(on(() => [ws.state.solvengReport, ws.state.solvengFileReport], () => highlighter?.refresh(), { defer: true }));

  // The file changed outside the editor: sync, another tab or a refactoring elsewhere.
  createEffect(
    on(
      ws.external,
      () => {
        const model = editor?.getModel();
        if (!editor || !model || current !== ws.state.selected) return;
        const text = ws.state.text;
        const old = model.getValue();
        if (old === text) return;
        let from = 0;
        while (from < old.length && from < text.length && old[from] === text[from]) from++;
        let end = 0;
        while (end < old.length - from && end < text.length - from && old[old.length - 1 - end] === text[text.length - 1 - end]) end++;
        applyingExternal = true;
        try {
          editor.executeEdits("external", [{ range: range(model, from, old.length - end), text: text.slice(from, text.length - end) }]);
        } finally {
          applyingExternal = false;
        }
      },
      { defer: true },
    ),
  );

  createEffect(() => editor?.updateOptions({ fontSize: settings.fontSize }));
  createEffect(() => editor?.updateOptions(wrapOptions()));
  createEffect(() => setVim(settings.vim));

  // The page's colours change with the theme setting and, while it follows the system, with the system's.
  createEffect(() => {
    void settings.theme;
    requestAnimationFrame(() => applyTheme(isDark()));
  });
  onMount(() => {
    const media = matchMedia("(prefers-color-scheme: dark)");
    const listener = () => applyTheme(isDark());
    media.addEventListener("change", listener);
    onCleanup(() => media.removeEventListener("change", listener));
  });

  // Diagnostics of the shown file, with fixes for missing fonts.
  createEffect(() => {
    const diagnostics = ws.state.diagnostics.filter((d) => d.path === ws.state.selected);
    const solveng = ws.state.solvengDiagnostics;
    const model = editor?.getModel();
    if (!model) return;
    const severity = (s: string) => (s === "error" ? monaco.MarkerSeverity.Error : monaco.MarkerSeverity.Warning);
    const markers: monaco.editor.IMarkerData[] = diagnostics.map((d) => {
      if (/^unknown font family: /.test(d.message)) void loadCatalog();
      return { ...diagnosticRange(model, d.line, d.column, d.length), severity: severity(d.severity), message: d.message };
    });
    // The compile reports solveng's problems too once it's caught up; the same message on a line counts once.
    const seen = new Set(markers.map((m) => `${m.startLineNumber}:${m.message}`));
    for (const d of solveng) {
      if (d.to > model.getValueLength()) continue;
      const r = range(model, d.from, d.to);
      if (seen.has(`${r.startLineNumber}:${d.message}`)) continue;
      markers.push({ ...r, severity: severity(d.severity), message: d.message });
    }
    monaco.editor.setModelMarkers(model, "typewright", markers);
  });

  // Reveals from diagnostics, search results and definitions.
  createEffect(() => {
    const reveal = ws.state.reveal;
    const model = editor?.getModel();
    if (!editor || !model || !reveal || reveal.path !== current) return;
    const length = model.getValueLength();
    let from = Math.min(reveal.from, length);
    let to = Math.min(reveal.to ?? from, length);
    if (reveal.line) {
      const r = diagnosticRange(model, reveal.line, reveal.column ?? 1, 0);
      from = model.getOffsetAt({ lineNumber: r.startLineNumber, column: r.startColumn });
      to = reveal.to ?? from;
    }
    editor.setSelection(range(model, from, to));
    editor.revealRangeInCenter(range(model, from, to));
    editor.focus();
  });

  return (
    <div class="editor">
      <div class="editor-monaco" ref={host} />
      <div class="vim-status" ref={vimStatus} hidden />
    </div>
  );
}
