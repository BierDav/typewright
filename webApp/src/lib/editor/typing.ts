// Enter, Backspace and the line commands from the Rust core, the same as the Mac app's editor: indentation, list
// items, IntelliJ's smart backspace, duplicating, deleting and moving lines.
import { completionStatus } from "@codemirror/autocomplete";
import { EditorSelection, Prec } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import * as core from "../core";

type Syntax = "typst" | "markdown" | "";

/** Openers each followed by its closer; empty pairs go together on Backspace. */
const PAIRS: Record<Syntax, string> = { typst: '()[]{}""$$``', markdown: '()[]{}""``', "": '()[]{}""' };

function newline(view: EditorView, syntax: Syntax, below = false): boolean {
  const state = view.state;
  // Enter accepts an open completion.
  if (completionStatus(state) === "active") return false;
  const text = state.doc.toString();
  const change = state.changeByRange((range) => {
    // ⇧↩ starts a new line below without splitting this one.
    const from = below ? state.doc.lineAt(range.head).to : range.from;
    const to = below ? from : range.to;
    const t = core.newline(text, from, to, syntax);
    return { changes: { from: t.from, to: t.to, insert: t.insert }, range: EditorSelection.cursor(t.caret) };
  });
  view.dispatch(state.update(change, { scrollIntoView: true, userEvent: "input" }));
  return true;
}

function backspace(view: EditorView, syntax: Syntax): boolean {
  const state = view.state;
  if (state.selection.ranges.length > 1 || !state.selection.main.empty) return false;
  const t = core.backspace(state.doc.toString(), state.selection.main.head, PAIRS[syntax]);
  if (!t) return false;
  view.dispatch({ changes: { from: t.from, to: t.to, insert: t.insert }, selection: { anchor: t.caret }, scrollIntoView: true, userEvent: "delete.backward" });
  return true;
}

type LineChange = { edit: { range: { location: number; length: number }; newText: string }; selections: { anchor: number; head: number }[] };

function lineCommand(run: (selections: { anchor: number; head: number }[], text: string) => LineChange, userEvent: string) {
  return (view: EditorView): boolean => {
    const state = view.state;
    const selections = state.selection.ranges.map((r) => ({ anchor: r.anchor, head: r.head }));
    const change = run(selections, state.doc.toString());
    const { location, length } = change.edit.range;
    view.dispatch({
      changes: length || change.edit.newText ? { from: location, to: location + length, insert: change.edit.newText } : undefined,
      selection: EditorSelection.create(change.selections.map((s) => EditorSelection.range(s.anchor, s.head)), Math.min(state.selection.mainIndex, change.selections.length - 1)),
      scrollIntoView: true,
      userEvent,
    });
    return true;
  };
}

export const duplicateLines = lineCommand((s, text) => core.duplicateSelectedLines(s, text), "input.duplicate");
export const deleteLines = lineCommand((s, text) => core.deleteSelectedLines(s, text), "delete.line");
export const moveLinesUp = lineCommand((s, text) => core.moveSelectedLines(s, true, text), "move.line");
export const moveLinesDown = lineCommand((s, text) => core.moveSelectedLines(s, false, text), "move.line");

/** The editor's keys for a file of `syntax`, ahead of CodeMirror's own. */
export function typing(syntax: Syntax) {
  return Prec.high(
    keymap.of([
      { key: "Enter", run: (view) => newline(view, syntax) },
      { key: "Shift-Enter", run: (view) => newline(view, syntax, true) },
      { key: "Backspace", run: (view) => backspace(view, syntax) },
      { key: "Mod-d", run: duplicateLines },
      { key: "Mod-Backspace", run: deleteLines },
      { key: "Alt-Shift-ArrowUp", run: moveLinesUp },
      { key: "Alt-Shift-ArrowDown", run: moveLinesDown },
    ]),
  );
}
