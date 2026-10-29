// Monaco with only the features the editor uses, its worker, the typst and Markdown languages, and themes
// built from the app's CSS variables so the editor follows the light and dark appearance.
import * as monaco from "monaco-editor/editor/editor.api";
import EditorWorker from "monaco-editor/editor/editor.worker?worker";
import "monaco-editor/features/codicon/register";
import "monaco-editor/features/bracketMatching/register";
import "monaco-editor/features/clipboard/register";
import "monaco-editor/features/codeAction/register";
import "monaco-editor/features/colorPicker/register";
import "monaco-editor/features/comment/register";
import "monaco-editor/features/cursorUndo/register";
import "monaco-editor/features/dnd/register";
import "monaco-editor/features/find/register";
import "monaco-editor/features/folding/register";
import "monaco-editor/features/gotoError/register";
import "monaco-editor/features/hover/register";
import "monaco-editor/features/indentation/register";
import "monaco-editor/features/linesOperations/register";
import "monaco-editor/features/multicursor/register";
import "monaco-editor/features/placeholderText/register";
import "monaco-editor/features/smartSelect/register";
import "monaco-editor/features/snippet/register";
// The suggest feature's entry only brings inline suggestions; the list is the controller's.
import "monaco-editor/editor/contrib/suggest/browser/suggestController";
import "monaco-editor/features/wordHighlighter/register";
import "monaco-editor/features/wordOperations/register";
import "monaco-editor/features/wordPartOperations/register";
import "monaco-editor/languages/definitions/markdown/register";

export { monaco };
export type CodeEditor = monaco.editor.IStandaloneCodeEditor;
export type Change = { from: number; to: number; insert: string };

self.MonacoEnvironment = { getWorker: () => new EditorWorker() };

// Typst for Monaco's own commands: comments, brackets and indentation; colours come from typst itself.
monaco.languages.register({ id: "typst", extensions: [".typ", ".typc"] });
monaco.languages.setLanguageConfiguration("typst", {
  comments: { lineComment: "//", blockComment: ["/*", "*/"] },
  brackets: [
    ["(", ")"],
    ["[", "]"],
    ["{", "}"],
  ],
  autoClosingPairs: [
    { open: "(", close: ")" },
    { open: "[", close: "]" },
    { open: "{", close: "}" },
    { open: '"', close: '"' },
    { open: "$", close: "$" },
  ],
  surroundingPairs: [
    { open: "(", close: ")" },
    { open: "[", close: "]" },
    { open: "{", close: "}" },
    { open: '"', close: '"' },
    { open: "$", close: "$" },
    { open: "*", close: "*" },
    { open: "_", close: "_" },
  ],
  wordPattern: /[\p{L}\p{N}_][\p{L}\p{N}_-]*/u,
});

const probe = typeof document === "undefined" ? null : document.createElement("canvas").getContext("2d", { willReadFrequently: true });

/** Any CSS colour (variables and `color-mix` included) as Monaco's `#rrggbbaa`. */
export function cssHex(css: string): string {
  if (!probe) return "#00000000";
  probe.clearRect(0, 0, 1, 1);
  probe.fillStyle = "#000";
  probe.fillStyle = css;
  probe.fillRect(0, 0, 1, 1);
  const [r, g, b, a] = probe.getImageData(0, 0, 1, 1).data;
  // Canvas pixels are premultiplied, so translucent colours need their alpha divided out.
  const un = (v: number) => (a ? Math.round((v * 255) / a) : 0);
  return `#${[un(r), un(g), un(b), a].map((v) => Math.min(v, 255).toString(16).padStart(2, "0")).join("")}`;
}

/** A theme from the CSS variables currently in effect on the page. */
export function applyTheme(dark: boolean) {
  const style = getComputedStyle(document.documentElement);
  const v = (name: string) => style.getPropertyValue(name).trim();
  const color = (css: string) => cssHex(css.replace(/var\((--[\w-]+)\)/g, (_, n) => v(n)));
  const token = (name: string) => color(`var(${name})`).slice(1, 7);
  monaco.editor.defineTheme("typewright", {
    base: dark ? "vs-dark" : "vs",
    inherit: true,
    // Markdown's tokens, as the app's highlighting colours them.
    rules: [
      { token: "", foreground: token("--text") },
      { token: "keyword", foreground: token("--hl-keyword"), fontStyle: "bold" },
      { token: "strong", fontStyle: "bold" },
      { token: "emphasis", fontStyle: "italic" },
      { token: "string", foreground: token("--hl-string") },
      { token: "string.link", foreground: token("--hl-link"), fontStyle: "underline" },
      { token: "variable", foreground: token("--hl-string") },
      { token: "variable.source", foreground: token("--hl-string") },
      { token: "comment", foreground: token("--hl-comment"), fontStyle: "italic" },
      { token: "tag", foreground: token("--hl-keyword") },
    ],
    colors: {
      "editor.background": color("var(--surface)"),
      "editor.foreground": color("var(--text)"),
      "editorGutter.background": color("var(--surface)"),
      "editorLineNumber.foreground": color("var(--tertiary)"),
      "editorLineNumber.activeForeground": color("var(--text)"),
      "editorCursor.foreground": "#ffffffff",
      "editorMultiCursor.primary.foreground": "#ffffffff",
      "editorMultiCursor.secondary.foreground": "#ffffffff",
      "editor.lineHighlightBackground": color("color-mix(in srgb, var(--accent) 5%, transparent)"),
      "editor.lineHighlightBorder": "#00000000",
      "editor.selectionBackground": "#80808066",
      "editor.inactiveSelectionBackground": "#80808055",
      "editor.selectionHighlightBackground": color("color-mix(in srgb, var(--orange) 22%, transparent)"),
      "editor.findMatchBackground": "#ffd60aff",
      "editor.findMatchHighlightBackground": "#ffd60a73",
      "editorBracketMatch.background": color("color-mix(in srgb, var(--accent) 18%, transparent)"),
      "editorBracketMatch.border": "#00000000",
      "editorRuler.foreground": color("var(--separator)"),
      "editorIndentGuide.background1": "#00000000",
      "editorIndentGuide.activeBackground1": "#00000000",
      "editorWhitespace.foreground": color("var(--tertiary)"),
      "editorError.foreground": color("var(--red)"),
      "editorWarning.foreground": color("var(--orange)"),
      "editorWidget.background": color("var(--popover)"),
      "editorWidget.foreground": color("var(--text)"),
      "editorWidget.border": color("var(--popover-border)"),
      "editorHoverWidget.background": color("var(--popover)"),
      "editorHoverWidget.border": color("var(--popover-border)"),
      "editorSuggestWidget.background": color("var(--popover)"),
      "editorSuggestWidget.border": color("var(--popover-border)"),
      "editorSuggestWidget.foreground": color("var(--text)"),
      "editorSuggestWidget.selectedBackground": color("var(--accent)"),
      "editorSuggestWidget.selectedForeground": "#ffffffff",
      "editorSuggestWidget.selectedIconForeground": "#ffffffff",
      "editorSuggestWidget.highlightForeground": color("var(--accent)"),
      "editorSuggestWidget.focusHighlightForeground": "#ffffffff",
      "list.hoverBackground": color("var(--hover)"),
      "input.background": color("var(--surface)"),
      "input.border": color("var(--separator)"),
      "focusBorder": color("var(--accent)"),
      "scrollbarSlider.background": color("color-mix(in srgb, var(--text) 18%, transparent)"),
      "scrollbarSlider.hoverBackground": color("color-mix(in srgb, var(--text) 28%, transparent)"),
      "scrollbarSlider.activeBackground": color("color-mix(in srgb, var(--text) 36%, transparent)"),
      "editorOverviewRuler.border": "#00000000",
      "editor.foldBackground": "#00000000",
      "editorStickyScroll.background": color("var(--surface)"),
    },
  });
  monaco.editor.setTheme("typewright");
}

/** The model's text. */
export function text(editor: CodeEditor): string {
  return editor.getModel()?.getValue() ?? "";
}

/** The main selection as UTF-16 offsets. */
export function selection(editor: CodeEditor): { anchor: number; head: number; from: number; to: number; empty: boolean } {
  const { anchor, head } = selections(editor)[0] ?? { anchor: 0, head: 0 };
  return { anchor, head, from: Math.min(anchor, head), to: Math.max(anchor, head), empty: anchor === head };
}

/** Every selection as anchor and head offsets, the main one first. */
export function selections(editor: CodeEditor): { anchor: number; head: number }[] {
  const model = editor.getModel();
  if (!model) return [];
  return (editor.getSelections() ?? []).map((s) => ({
    anchor: model.getOffsetAt(s.getSelectionStart()),
    head: model.getOffsetAt(s.getPosition()),
  }));
}

export function range(model: monaco.editor.ITextModel, from: number, to = from): monaco.Range {
  const a = model.getPositionAt(from);
  const b = model.getPositionAt(to);
  return new monaco.Range(a.lineNumber, a.column, b.lineNumber, b.column);
}

export function toSelection(model: monaco.editor.ITextModel, anchor: number, head = anchor): monaco.Selection {
  const a = model.getPositionAt(anchor);
  const h = model.getPositionAt(head);
  return new monaco.Selection(a.lineNumber, a.column, h.lineNumber, h.column);
}

/**
 * Applies changes given in the current text as one undo step; `select` are anchor and head pairs in the new text.
 * `source` tells listeners what made the edit.
 */
export function edit(editor: CodeEditor, changes: Change[], select?: { anchor: number; head: number }[], source = "typewright") {
  const model = editor.getModel();
  if (!model) return;
  const ops = changes.map((c) => ({ range: range(model, c.from, c.to), text: c.insert, forceMoveMarkers: true }));
  editor.pushUndoStop();
  if (!select) {
    editor.executeEdits(source, ops);
  } else {
    editor.executeEdits(source, ops, () => select.map((s) => toSelection(model, s.anchor, s.head)));
  }
  editor.pushUndoStop();
}

/** Selects ranges (anchor and head) and scrolls the main one into view. */
export function select(editor: CodeEditor, ranges: { anchor: number; head: number }[], main = 0) {
  const model = editor.getModel();
  if (!model || !ranges.length) return;
  const sels = ranges.map((r) => toSelection(model, r.anchor, r.head));
  // Monaco's primary selection is the first.
  const [primary] = sels.splice(Math.min(main, sels.length - 1), 1);
  editor.setSelections([primary, ...sels]);
  editor.revealRangeInCenterIfOutsideViewport(primary);
}

/** Where `offset` is on screen, in page coordinates. */
export function coordsAt(editor: CodeEditor, offset: number): { left: number; top: number; bottom: number } | null {
  const model = editor.getModel();
  const visible = model && editor.getScrolledVisiblePosition(model.getPositionAt(offset));
  if (!visible) return null;
  const box = editor.getDomNode()!.getBoundingClientRect();
  return { left: box.left + visible.left, top: box.top + visible.top, bottom: box.top + visible.top + visible.height };
}
