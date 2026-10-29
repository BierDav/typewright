// Enter, Backspace and the line commands from the Rust core, the same as the Mac app's editor: indentation, list
// items, IntelliJ's smart backspace, duplicating, deleting and moving lines.
import * as core from "../core";
import { type CodeEditor, edit, monaco, selections, text } from "./monaco";

export type Syntax = "typst" | "markdown" | "";

/** Openers each followed by its closer; empty pairs go together on Backspace. */
const PAIRS: Record<Syntax, string> = { typst: '()[]{}""$$``', markdown: '()[]{}""``', "": '()[]{}""' };

function newline(editor: CodeEditor, syntax: Syntax, below = false) {
  const model = editor.getModel();
  if (!model || editor.getOption(monaco.editor.EditorOption.readOnly)) return;
  const doc = text(editor);
  const ranges = selections(editor).map((s) => ({ from: Math.min(s.anchor, s.head), to: Math.max(s.anchor, s.head) }));
  // Each range's edit in the old text; carets shift by the edits before them.
  const edits = ranges
    .map((r) => {
      // ⇧↩ starts a new line below without splitting this one.
      const from = below ? model.getOffsetAt({ lineNumber: model.getPositionAt(r.from).lineNumber, column: Infinity }) : r.from;
      return core.newline(doc, from, below ? from : r.to, syntax);
    })
    .sort((a, b) => a.from - b.from);
  let shift = 0;
  const carets = edits.map((t) => {
    const caret = t.caret + shift;
    shift += t.insert.length - (t.to - t.from);
    return { anchor: caret, head: caret };
  });
  edit(editor, edits.map((t) => ({ from: t.from, to: t.to, insert: t.insert })), carets, "input");
  editor.revealPosition(editor.getPosition()!);
}

function backspace(editor: CodeEditor, syntax: Syntax) {
  const sels = selections(editor);
  const t = sels.length === 1 && sels[0].anchor === sels[0].head ? core.backspace(text(editor), sels[0].head, PAIRS[syntax]) : null;
  if (!t) return editor.trigger("keyboard", "deleteLeft", null);
  edit(editor, [{ from: t.from, to: t.to, insert: t.insert }], [{ anchor: t.caret, head: t.caret }], "delete.backward");
}

type LineChange = { edit: { range: { location: number; length: number }; newText: string }; selections: { anchor: number; head: number }[] };

function lineCommand(run: (selections: { anchor: number; head: number }[], text: string) => LineChange, source: string) {
  return (editor: CodeEditor) => {
    if (editor.getOption(monaco.editor.EditorOption.readOnly)) return;
    const change = run(selections(editor), text(editor));
    const { location, length } = change.edit.range;
    edit(editor, length || change.edit.newText ? [{ from: location, to: location + length, insert: change.edit.newText }] : [], change.selections, source);
    editor.revealPosition(editor.getPosition()!);
  };
}

export const duplicateLines = lineCommand((s, text) => core.duplicateSelectedLines(s, text), "input.duplicate");
export const deleteLines = lineCommand((s, text) => core.deleteSelectedLines(s, text), "delete.line");
export const moveLinesUp = lineCommand((s, text) => core.moveSelectedLines(s, true, text), "move.line");
export const moveLinesDown = lineCommand((s, text) => core.moveSelectedLines(s, false, text), "move.line");

/** The editor's keys for a file of `syntax`, ahead of Monaco's own; `syntax()` is read on each key. */
export function typing(editor: CodeEditor, syntax: () => Syntax): monaco.IDisposable[] {
  const { KeyMod, KeyCode } = monaco;
  // Enter accepts an open completion and moves through snippet fields as usual.
  const plain = "editorTextFocus && !editorReadonly && !suggestWidgetVisible && typewright.insert";
  const action = (id: string, keybindings: number[], run: (editor: CodeEditor) => void, precondition = plain) =>
    editor.addAction({ id: `typewright.${id}`, label: id, keybindings, precondition, run: () => run(editor) });
  return [
    action("newline", [KeyCode.Enter], (e) => newline(e, syntax())),
    action("newlineBelow", [KeyMod.Shift | KeyCode.Enter], (e) => newline(e, syntax(), true)),
    action("backspace", [KeyCode.Backspace], (e) => backspace(e, syntax())),
    action("duplicateLines", [KeyMod.CtrlCmd | KeyCode.KeyD], duplicateLines, "editorTextFocus && !editorReadonly"),
    action("deleteLines", [KeyMod.CtrlCmd | KeyCode.Backspace], deleteLines, "editorTextFocus && !editorReadonly"),
    action("moveLinesUp", [KeyMod.Alt | KeyMod.Shift | KeyCode.UpArrow], moveLinesUp, "editorTextFocus && !editorReadonly"),
    action("moveLinesDown", [KeyMod.Alt | KeyMod.Shift | KeyCode.DownArrow], moveLinesDown, "editorTextFocus && !editorReadonly"),
  ];
}
