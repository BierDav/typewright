// Several carets, the same gestures as the Mac app's editor: ⌥-drag selects a column, ⌥⇧-click toggles a caret,
// ⌃⇧↑ and ⌃⇧↓ add one above or below, and ⇧⌘8 switches column selection mode, where a plain drag and ⇧↑/⇧↓ select
// columns. The editor needs `multiCursorModifier: "ctrlCmd"`, which leaves ⌥-drag to Monaco's column selection.
import { isMac } from "../app";
import { type CodeEditor, monaco } from "./monaco";

/** `modClick` gets ⌘-clicks (Ctrl-clicks elsewhere) instead of Monaco, which would add a caret for them. */
export function carets(editor: CodeEditor, modClick: (offset: number) => void): monaco.IDisposable[] {
  const { KeyMod, KeyCode } = monaco;
  const host = editor.getContainerDomNode();

  const positionAt = (event: PointerEvent) => {
    const target = editor.getTargetAtClientPoint(event.clientX, event.clientY);
    const type = target?.type;
    const inText = type === monaco.editor.MouseTargetType.CONTENT_TEXT || type === monaco.editor.MouseTargetType.CONTENT_EMPTY;
    return inText ? target!.position : null;
  };

  const toggle = (position: monaco.IPosition) => {
    const sels = editor.getSelections() ?? [];
    const hit = sels.findIndex((s) => s.containsPosition(position));
    if (hit < 0) {
      // The new caret becomes the primary one.
      const caret = new monaco.Selection(position.lineNumber, position.column, position.lineNumber, position.column);
      editor.setSelections([caret, ...sels]);
    } else if (sels.length > 1) {
      editor.setSelections(sels.filter((_, i) => i !== hit));
    }
  };

  // Ahead of Monaco, which listens on a node inside the host.
  const onPointerDown = (event: PointerEvent) => {
    if (event.button !== 0) return;
    const mod = isMac ? event.metaKey : event.ctrlKey;
    const other = isMac ? event.ctrlKey : event.metaKey;
    const toggling = event.altKey && event.shiftKey && !mod && !other;
    const clicking = mod && !event.altKey && !event.shiftKey && !other;
    if (!toggling && !clicking) return;
    const position = positionAt(event);
    const model = editor.getModel();
    if (!position || !model) return;
    event.preventDefault();
    event.stopPropagation();
    editor.focus();
    if (toggling) return toggle(position);
    editor.setPosition(position);
    modClick(model.getOffsetAt(position));
  };
  host.addEventListener("pointerdown", onPointerDown, true);

  const trigger = (id: string) => () => editor.trigger("keyboard", id, null);
  // ⌃ is Monaco's WinCtrl on the Mac only.
  const ctrl = isMac ? KeyMod.WinCtrl : KeyMod.CtrlCmd;
  const action = (id: string, label: string, keybinding: number, run: () => void) =>
    editor.addAction({ id: `typewright.${id}`, label, keybindings: [keybinding], precondition: "editorTextFocus", run });
  return [
    { dispose: () => host.removeEventListener("pointerdown", onPointerDown, true) },
    action("addCaretAbove", "Add Caret Above", ctrl | KeyMod.Shift | KeyCode.UpArrow, trigger("editor.action.insertCursorAbove")),
    action("addCaretBelow", "Add Caret Below", ctrl | KeyMod.Shift | KeyCode.DownArrow, trigger("editor.action.insertCursorBelow")),
    action("columnSelection", "Column Selection Mode", KeyMod.CtrlCmd | KeyMod.Shift | KeyCode.Digit8, () => toggleColumnSelection(editor)),
  ];
}

/** Switches column selection mode, where a plain drag and ⇧↑/⇧↓ select a column. */
export function toggleColumnSelection(editor: CodeEditor) {
  const on = !editor.getOption(monaco.editor.EditorOption.columnSelection);
  editor.updateOptions({ columnSelection: on });
  editor.getContainerDomNode().classList.toggle("tw-column-mode", on);
}
