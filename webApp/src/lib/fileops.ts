// File tree changes with undo, like the Mac app's `FileOperations`: each one commits at once with a descriptive
// message, and undo does the inverse on disk (never `jj undo`), so concurrent edits and sync survive.
import { type Accessor, createSignal, type Setter } from "solid-js";
import { alert } from "./app";
import * as jj from "./jj";
import type { DeletedItem } from "./jj";
import type { Workspace } from "./workspace";

/** Paths are relative to the space. */
export type Move = { from: string; to: string };

export type FileOp =
  | { kind: "move"; moves: Move[] }
  | { kind: "delete"; paths: string[] }
  /** Deleted items back at their own paths. */
  | { kind: "restore"; items: DeletedItem[] }
  /** Done in order, undone in reverse. */
  | { kind: "batch"; ops: FileOp[] };

type Step = { name: string; op: FileOp; message: string; inverseMessage: string };

export class FileUndo {
  private undoStack: Step[] = [];
  private redoStack: Step[] = [];
  private chain: Promise<void> = Promise.resolve();
  /** "Undo <name>" and "Redo <name>" for menus. */
  readonly names: Accessor<{ undo: string | null; redo: string | null }>;
  private readonly setNames: Setter<{ undo: string | null; redo: string | null }>;

  constructor(private readonly ws: Workspace) {
    [this.names, this.setNames] = createSignal({ undo: null as string | null, redo: null as string | null });
  }

  /** An op that already happened: commits it and remembers how to undo it. */
  record(name: string, inverse: FileOp, message: string) {
    this.push(this.undoStack, { name, op: inverse, message: `Undo ${message}`, inverseMessage: message }, true);
    this.enqueue(() => this.commit(message));
  }

  perform(op: FileOp, name: string, message: string): Promise<void> {
    return this.enqueue(async () => {
      const inverse = await this.execute(op, message);
      if (inverse) this.push(this.undoStack, { name, op: inverse, message: `Undo ${message}`, inverseMessage: message }, true);
    });
  }

  undo(): Promise<void> {
    return this.enqueue(() => this.replay(this.undoStack, this.redoStack));
  }

  redo(): Promise<void> {
    return this.enqueue(() => this.replay(this.redoStack, this.undoStack));
  }

  /** Waits for queued ops, for tests. */
  settle(): Promise<void> {
    return this.chain;
  }

  private async replay(from: Step[], to: Step[]) {
    const step = from.pop();
    this.update();
    if (!step) return;
    const inverse = await this.execute(step.op, step.message);
    if (inverse) this.push(to, { name: step.name, op: inverse, message: step.inverseMessage, inverseMessage: step.message }, false);
  }

  private push(stack: Step[], step: Step, fresh: boolean) {
    stack.push(step);
    if (stack.length > 100) stack.shift();
    // A new change ends what redo could bring back.
    if (fresh) this.redoStack = [];
    this.update();
  }

  private update() {
    this.setNames({ undo: this.undoStack.at(-1)?.name ?? null, redo: this.redoStack.at(-1)?.name ?? null });
  }

  private enqueue(work: () => Promise<void>): Promise<void> {
    this.chain = this.chain.then(work).catch((err) => console.error("file op:", err));
    return this.chain;
  }

  private async commit(message: string) {
    await this.ws.flushSaves();
    await jj.commit(message);
  }

  /** Does `op` and returns its inverse, or null (after telling the user) when it couldn't. */
  private async execute(op: FileOp, message: string): Promise<FileOp | null> {
    const ws = this.ws;
    switch (op.kind) {
      case "move": {
        const done: Move[] = [];
        for (const move of op.moves) {
          if (await ws.moveQuietly(move.from, move.to)) done.push(move);
          else await alert(`Couldn't move “${move.from.split("/").pop()}” back`, "Another item took its place, or it was moved or deleted in the meantime.");
        }
        if (!done.length) return null;
        await this.commit(message);
        return { kind: "move", moves: done.reverse().map((m) => ({ from: m.to, to: m.from })) };
      }
      case "delete": {
        const items = await ws.deleteNow(op.paths, message);
        return items ? { kind: "restore", items } : null;
      }
      case "restore": {
        const restored: string[] = [];
        for (const item of op.items) {
          const result = await jj.restoreDeleted(item, item.path);
          const name = item.path.split("/").pop();
          if (result === "restored") restored.push(ws.spacePath(item.path));
          else if (result === "exists") await alert(`“${name}” already exists`, "Something else is at its place now, so it stays deleted.");
          else await alert(`Couldn't restore “${name}”`, jj.isOpen() ? undefined : "Another tab runs the history; undo there.");
        }
        await ws.reloadTree();
        return restored.length ? { kind: "delete", paths: restored } : null;
      }
      case "batch": {
        const inverses: FileOp[] = [];
        for (const part of op.ops) {
          const inverse = await this.execute(part, message);
          if (inverse) inverses.push(inverse);
        }
        return inverses.length ? { kind: "batch", ops: inverses.reverse() } : null;
      }
    }
  }
}
