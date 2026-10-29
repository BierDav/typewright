import { createMemo, createSignal, For, type JSX, onMount, Show } from "solid-js";
import { copyText, type Dialog, dialogs, dismissToast, toasts } from "~/lib/app";
import { Check, ChevronRight, Copy, CornerDownLeft } from "./icons";

type DialogRow = { id: string; title: string; icon: () => JSX.Element; destructive?: boolean; run: () => void };

/** A question or message in the command palette's look, like the Mac app's `PaletteDialog`. */
function DialogView(props: { dialog: Dialog }) {
  const d = props.dialog;
  const input = d.input !== undefined;
  const [value, setValue] = createSignal(d.input ?? "");
  const [query, setQuery] = createSignal("");
  const [selection, setSelection] = createSignal(0);
  let field!: HTMLInputElement;
  const cancel = d.buttons.find((b) => b.role === "cancel");
  const primary = d.buttons.find((b) => b.role === "default" || b.role === "destructive") ?? d.buttons.at(-1)!;
  const answer = (button: string) => d.resolve({ button, input: value() });
  const dismiss = () => d.resolve(cancel ? { button: cancel.value, input: value() } : null);

  // Cancel is Esc; the other buttons, and texts to copy, are the rows.
  const rows: DialogRow[] = [
    ...(d.copy ?? []).map((text, i) => ({ id: `copy-${i}`, title: text, icon: () => <Copy size={15} />, run: () => void copyText(text) })),
    ...d.buttons
      .filter((b) => b !== cancel || d.buttons.length === 1)
      .map((b) => ({ id: b.value, title: b.label, destructive: b.role === "destructive", icon: () => (b === primary ? <Check size={15} /> : <ChevronRight size={15} />), run: () => answer(b.value) })),
  ];
  const visible = createMemo(() => {
    const q = query().trim().toLowerCase();
    return q ? rows.filter((r) => r.title.toLowerCase().includes(q)) : rows;
  });
  // The primary button starts selected, so Return does what a default button would.
  setSelection(Math.max(0, rows.findIndex((r) => r.id === primary.value)));

  onMount(() => {
    field.focus();
    if (!input) return;
    // The name without its extension, ready to be typed over.
    const dot = field.value.lastIndexOf(".");
    field.setSelectionRange(0, dot > 0 ? dot : field.value.length);
  });

  function onKey(event: KeyboardEvent) {
    const count = visible().length;
    if (event.key === "Escape") dismiss();
    else if (event.key === "ArrowDown" && !input && count) setSelection((i) => (i + 1) % count);
    else if (event.key === "ArrowUp" && !input && count) setSelection((i) => (i - 1 + count) % count);
    else if (event.key === "Enter" && !event.isComposing) {
      if (input) answer(primary.value);
      else visible()[selection()]?.run();
    } else return;
    event.preventDefault();
    event.stopPropagation();
  }

  return (
    <div class="overlay-backdrop dialog-backdrop" onKeyDown={onKey} onMouseDown={(e) => e.target === e.currentTarget && dismiss()}>
      <div class="palette palette-dialog glass" role="alertdialog" aria-labelledby={`dialog-${d.id}`}>
        <div class="palette-field">
          <span class="palette-page" id={`dialog-${d.id}`}>
            {d.title}
          </span>
          <Show
            when={input}
            fallback={<input ref={field} placeholder={d.title} value={query()} onInput={(e) => (setQuery(e.currentTarget.value), setSelection(0))} spellcheck={false} />}
          >
            <input ref={field} placeholder={d.placeholder ?? d.title} value={value()} onInput={(e) => setValue(e.currentTarget.value)} spellcheck={false} />
          </Show>
        </div>
        <Show when={d.message}>
          <p class="palette-detail secondary">{d.message}</p>
        </Show>
        <Show when={!input}>
          <div class="palette-list">
            <For each={visible()} fallback={<p class="palette-empty secondary">No results</p>}>
              {(row, index) => (
                <button
                  class="palette-row"
                  classList={{ selected: index() === selection(), destructive: row.destructive }}
                  onPointerMove={() => setSelection(index())}
                  onClick={() => row.run()}
                >
                  <span class="palette-icon">{row.icon()}</span>
                  <span class="palette-title" classList={{ mono: row.id.startsWith("copy-") }}>
                    {row.title}
                  </span>
                </button>
              )}
            </For>
          </div>
        </Show>
        <div class="palette-hints secondary">
          <Show when={!input && visible().length > 1}>
            <span>↑↓ Select</span>
          </Show>
          <span>
            <CornerDownLeft size={11} /> {input ? primary.label : visible()[selection()]?.id.startsWith("copy-") ? "Copy" : primary.label}
          </span>
          <span>esc {cancel ? cancel.label : "Close"}</span>
        </div>
      </div>
    </div>
  );
}

export default function Dialogs() {
  return (
    <>
      <For each={dialogs}>{(dialog) => <DialogView dialog={dialog} />}</For>
      <div class="toasts" aria-live="polite">
        <For each={toasts}>
          {(toast) => (
            <div class="toast glass" classList={{ actionable: toast.actions.length > 0 }}>
              <span>{toast.text}</span>
              <For each={toast.actions}>
                {(action) => (
                  <button
                    class="toast-action"
                    onClick={() => {
                      dismissToast(toast.id);
                      action.run();
                    }}
                  >
                    {action.label}
                  </button>
                )}
              </For>
            </div>
          )}
        </For>
      </div>
    </>
  );
}
