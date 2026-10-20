import { createSignal, For, onMount, Show } from "solid-js";
import { copyText, type Dialog, dialogs, toasts } from "~/lib/app";
import { Copy } from "./icons";

function DialogView(props: { dialog: Dialog }) {
  const d = props.dialog;
  const [value, setValue] = createSignal(d.input ?? "");
  let field: HTMLInputElement | undefined;
  let box!: HTMLDivElement;
  const cancel = d.buttons.find((b) => b.role === "cancel");
  const primary = d.buttons.find((b) => b.role === "default" || b.role === "destructive") ?? d.buttons.at(-1)!;

  onMount(() => {
    if (field) {
      field.focus();
      // The name without its extension, ready to be typed over.
      const dot = field.value.lastIndexOf(".");
      field.setSelectionRange(0, dot > 0 ? dot : field.value.length);
    } else {
      box.querySelector<HTMLButtonElement>(".button.primary")?.focus();
    }
  });

  function onKey(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      d.resolve(cancel ? { button: cancel.value, input: value() } : null);
    } else if (event.key === "Enter" && !event.isComposing && (field || document.activeElement?.tagName !== "BUTTON")) {
      event.preventDefault();
      d.resolve({ button: primary.value, input: value() });
    }
  }

  return (
    <div class="overlay-backdrop dialog-backdrop" onKeyDown={onKey}>
      <div class="dialog glass" role="alertdialog" aria-labelledby={`dialog-${d.id}`} ref={box}>
        <img class="dialog-icon" src={`${import.meta.env.BASE_URL}logo.png`} alt="" />
        <h2 id={`dialog-${d.id}`}>{d.title}</h2>
        <Show when={d.message}>
          <p>{d.message}</p>
        </Show>
        <Show when={d.input !== undefined}>
          <input ref={field} class="text-field" value={value()} placeholder={d.placeholder} onInput={(e) => setValue(e.currentTarget.value)} spellcheck={false} />
        </Show>
        <For each={d.copy}>
          {(text) => (
            <div class="copy-field">
              <input class="text-field mono" readOnly value={text} onFocus={(e) => e.currentTarget.select()} />
              <button class="icon-button" title="Copy" onClick={() => void copyText(text)}>
                <Copy size={14} />
              </button>
            </div>
          )}
        </For>
        <div class="dialog-buttons" classList={{ stacked: d.buttons.length > 3 }}>
          <For each={d.buttons}>
            {(button) => (
              <button
                class="button"
                classList={{ primary: button.role === "default", destructive: button.role === "destructive" }}
                onClick={() => d.resolve({ button: button.value, input: value() })}
              >
                {button.label}
              </button>
            )}
          </For>
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
        <For each={toasts}>{(toast) => <div class="toast glass">{toast.text}</div>}</For>
      </div>
    </>
  );
}
