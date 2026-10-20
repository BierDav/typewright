// Keeps the shown file of a synced space in a live session with the other devices editing it, like
// the Mac app's `LiveEditing`: keystrokes go out as they happen and theirs come in as edits, with
// their cursors. Remote edits skip the undo history, so undo only takes back this device's edits.
import { Annotation, ChangeSet, type Extension, StateEffect, StateField, Transaction } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from "@codemirror/view";
import { createSignal } from "solid-js";
import { TextMerge } from "../core";
import * as syncService from "../sync";

export type RemoteCursor = { device: string; name: string; from: number; to: number };

const remote = Annotation.define<boolean>();
const setCursors = StateEffect.define<RemoteCursor[]>();

const PALETTE = ["#ff2d55", "#ff9500", "#af52de", "#30b0c7", "#34c759", "#007aff", "#5856d6", "#a2845e"];

export function cursorColor(device: string): string {
  let hash = 5381;
  for (const c of device) hash = (Math.imul(hash, 33) + c.codePointAt(0)!) >>> 0;
  return PALETTE[hash % PALETTE.length];
}

class Caret extends WidgetType {
  constructor(readonly name: string, readonly color: string) {
    super();
  }
  eq(other: Caret) {
    return other.name === this.name && other.color === this.color;
  }
  toDOM() {
    const caret = document.createElement("span");
    caret.className = "tw-remote-caret";
    caret.style.setProperty("--remote", this.color);
    const label = document.createElement("span");
    label.className = "tw-remote-name";
    label.textContent = this.name;
    caret.append(label);
    return caret;
  }
}

const cursorsField = StateField.define<{ cursors: RemoteCursor[]; deco: DecorationSet }>({
  create: () => ({ cursors: [], deco: Decoration.none }),
  update(value, tr) {
    let cursors = value.cursors;
    for (const effect of tr.effects) if (effect.is(setCursors)) cursors = effect.value;
    if (cursors === value.cursors && !tr.docChanged) return value;
    if (cursors === value.cursors) {
      cursors = cursors.map((c) => ({ ...c, from: tr.changes.mapPos(c.from), to: tr.changes.mapPos(c.to) }));
    }
    const length = tr.state.doc.length;
    const ranges = cursors
      .filter((c) => c.to <= length)
      .flatMap((c) => {
        const color = cursorColor(c.device);
        const out = [Decoration.widget({ widget: new Caret(c.name, color), side: 1 }).range(c.to)];
        if (c.to > c.from) {
          out.push(Decoration.mark({ class: "tw-remote-selection", attributes: { style: `--remote: ${color}` } }).range(c.from, c.to));
        }
        return out;
      });
    return { cursors, deco: Decoration.set(ranges, true) };
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.deco),
});

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

/** Live editing of `path` in the space `folder`; inactive while the space doesn't sync. */
export function liveEditing(folder: string, path: string): Extension {
  const plugin = ViewPlugin.fromClass(
    class {
      active = false;
      unsubscribe: () => void;
      applying = false;

      constructor(readonly view: EditorView) {
        const text = view.state.doc.toString();
        if (syncService.isRunning() && syncService.isSynced(folder) && text.length <= syncService.LIVE_LIMIT) {
          syncService.liveOpen(folder, path, text);
          this.active = true;
        }
        this.unsubscribe = syncService.onLive((id, livePath) => {
          if (this.active && livePath === path && syncService.spaceId(folder) === id) queueMicrotask(() => this.sync());
        });
      }

      scheduled = false;

      update(update: ViewUpdate) {
        if (!this.active || this.applying) return;
        const local = update.transactions.some((tr) => tr.docChanged && !tr.annotation(remote));
        // Views can't dispatch while updating, so the sync runs right after.
        if ((local || update.selectionSet) && !this.scheduled) {
          this.scheduled = true;
          queueMicrotask(() => {
            this.scheduled = false;
            this.sync();
          });
        }
      }

      sync(step = 0) {
        if (!this.active) return;
        const view = this.view;
        const selection = view.state.selection.main;
        const result = syncService.liveSync(folder, path, view.state.doc.toString(), selection.from, selection.to - selection.from, step);
        if (!result) return;
        if (result.adopted) {
          // Another device's session was first; this device's edits since opening merge into it.
          const mine = view.state.doc.toString();
          const merged = TextMerge.merge3(result.adopted.base, mine, result.adopted.theirs);
          this.apply([difference(mine, merged.conflicts === 0 ? merged.text : result.adopted.theirs)]);
          this.sync();
          return;
        }
        this.apply(result.edits.map((e) => ({ from: e.location, to: e.location + e.length, insert: e.text })));
        setParticipants(result.cursors.map((c) => c.name));
        view.dispatch({
          effects: setCursors.of(result.cursors.map((c) => ({ device: c.device, name: c.name, from: c.location, to: c.location + c.length }))),
        });
      }

      /** Applies edits that each refer to the text after the previous one. */
      apply(edits: { from: number; to: number; insert: string }[]) {
        const view = this.view;
        let changes: ChangeSet | null = null;
        let length = view.state.doc.length;
        for (const edit of edits) {
          if (edit.to === edit.from && !edit.insert) continue;
          if (edit.to > length) break;
          const next = ChangeSet.of(edit, length);
          changes = changes ? changes.compose(next) : next;
          length = next.newLength;
        }
        if (!changes) return;
        this.applying = true;
        try {
          view.dispatch({ changes, annotations: [remote.of(true), Transaction.addToHistory.of(false)], userEvent: "input.remote" });
        } finally {
          this.applying = false;
        }
      }

      destroy() {
        this.unsubscribe();
        if (this.active) syncService.liveClose(folder, path);
        setParticipants([]);
      }
    },
  );
  return [cursorsField, plugin];
}

/** Whether a transaction came from another device. */
export function isRemote(tr: Transaction): boolean {
  return tr.annotation(remote) === true;
}
