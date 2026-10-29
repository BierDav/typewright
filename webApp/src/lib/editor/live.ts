// Keeps the shown file of a synced space in a live session with the other devices editing it, like
// the Mac app's `LiveEditing`: keystrokes go out as they happen and theirs come in as edits, with
// their cursors.
import { createSignal } from "solid-js";
import { merge3 } from "../core";
import * as syncService from "../sync";
import { type CodeEditor, monaco, range, selection } from "./monaco";

export type RemoteCursor = { device: string; name: string; from: number; to: number };

/** Each device's colour, one of the `.tw-remote-0` to `-7` classes in app.css. */
function colorIndex(device: string): number {
  let hash = 5381;
  for (const c of device) hash = (Math.imul(hash, 33) + c.codePointAt(0)!) >>> 0;
  return hash % 8;
}

/** Names of the other devices with the shown file open. */
const [participants, setParticipants] = createSignal<string[]>([]);
export { participants };

/** One edit for the single changed span between two texts. */
function difference(old: string, next: string) {
  let prefix = 0;
  const max = Math.min(old.length, next.length);
  while (prefix < max && old.charCodeAt(prefix) === next.charCodeAt(prefix)) prefix++;
  // Never split a surrogate pair.
  if (prefix > 0 && prefix < old.length && (old.charCodeAt(prefix) & 0xfc00) === 0xdc00) prefix--;
  let suffix = 0;
  while (suffix < max - prefix && old.charCodeAt(old.length - 1 - suffix) === next.charCodeAt(next.length - 1 - suffix)) suffix++;
  return { from: prefix, to: old.length - suffix, insert: next.slice(prefix, next.length - suffix) };
}

/** A device's caret with its name, at the end of its selection. */
class Caret implements monaco.editor.IContentWidget {
  readonly dom = document.createElement("span");
  readonly label = document.createElement("span");
  position: monaco.IPosition = { lineNumber: 1, column: 1 };
  constructor(readonly device: string, readonly editor: CodeEditor) {
    this.dom.className = `tw-remote-caret tw-remote-${colorIndex(device)}`;
    this.dom.style.height = `${editor.getOption(monaco.editor.EditorOption.lineHeight)}px`;
    this.label.className = "tw-remote-name";
    this.dom.append(this.label);
  }
  getId() {
    return `typewright.remote.${this.device}`;
  }
  getDomNode() {
    return this.dom;
  }
  getPosition(): monaco.editor.IContentWidgetPosition {
    return { position: this.position, preference: [monaco.editor.ContentWidgetPositionPreference.EXACT] };
  }
}

/** Live editing of `path` in the space `folder` in `editor`'s current model; inactive while no share holds the file. */
export function liveEditing(editor: CodeEditor, folder: string, path: string): monaco.IDisposable {
  const model = editor.getModel()!;
  let active = false;
  let applying = false;
  let scheduled = false;
  const carets = new Map<string, Caret>();
  const selections = editor.createDecorationsCollection();

  const showCursors = (cursors: RemoteCursor[]) => {
    const length = model.getValueLength();
    const shown = cursors.filter((c) => c.to <= length);
    for (const [device, caret] of carets) {
      if (shown.some((c) => c.device === device)) continue;
      editor.removeContentWidget(caret);
      carets.delete(device);
    }
    for (const c of shown) {
      let caret = carets.get(c.device);
      const isNew = !caret;
      caret ??= new Caret(c.device, editor);
      carets.set(c.device, caret);
      caret.label.textContent = c.name;
      caret.position = model.getPositionAt(c.to);
      if (isNew) editor.addContentWidget(caret);
      else editor.layoutContentWidget(caret);
    }
    selections.set(
      shown
        .filter((c) => c.to > c.from)
        .map((c) => ({ range: range(model, c.from, c.to), options: { className: `tw-remote-selection tw-remote-${colorIndex(c.device)}` } })),
    );
  };

  /** Applies edits that each refer to the text after the previous one. */
  const apply = (edits: { from: number; to: number; insert: string }[]) => {
    applying = true;
    try {
      for (const e of edits) {
        if (e.to === e.from && !e.insert) continue;
        if (e.to > model.getValueLength()) break;
        // Its own undo step, so undo never lands on shifted text; it may take back another device's edit.
        model.pushStackElement();
        model.pushEditOperations(editor.getSelections(), [{ range: range(model, e.from, e.to), text: e.insert, forceMoveMarkers: false }], () => null);
        model.pushStackElement();
      }
    } finally {
      applying = false;
    }
  };

  const sync = () => {
    if (!active || model.isDisposed() || editor.getModel() !== model) return;
    const { from, to } = selection(editor);
    const result = syncService.liveSync(folder, path, model.getValue(), from, to - from, 0);
    if (!result) return;
    if (result.adopted) {
      // Another device's session was first; this device's edits since opening merge into it.
      const mine = model.getValue();
      const merged = merge3(result.adopted.base, mine, result.adopted.theirs);
      apply([difference(mine, merged.conflicts === 0 ? merged.text : result.adopted.theirs)]);
      sync();
      return;
    }
    apply(result.edits.map((e) => ({ from: e.location, to: e.location + e.length, insert: e.text })));
    setParticipants(result.cursors.map((c) => c.name));
    showCursors(result.cursors.map((c) => ({ device: c.device, name: c.name, from: c.location, to: c.location + c.length })));
  };

  const schedule = () => {
    if (!active || applying || scheduled) return;
    scheduled = true;
    queueMicrotask(() => {
      scheduled = false;
      sync();
    });
  };

  const text = model.getValue();
  if (syncService.canEditLive(folder, path) && text.length <= syncService.LIVE_LIMIT) {
    syncService.liveOpen(folder, path, text);
    active = true;
  }
  const unsubscribe = syncService.onLive((liveFolder, livePath) => {
    if (active && livePath === path && liveFolder === folder) queueMicrotask(sync);
  });
  const listeners = [model.onDidChangeContent(schedule), editor.onDidChangeCursorSelection(schedule)];

  return {
    dispose() {
      unsubscribe();
      listeners.forEach((l) => l.dispose());
      for (const caret of carets.values()) editor.removeContentWidget(caret);
      selections.clear();
      if (active) syncService.liveClose(folder, path);
      active = false;
      setParticipants([]);
    },
  };
}
