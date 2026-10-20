import { createSignal, For, type JSX, onCleanup, onMount, Show } from "solid-js";
import { Portal } from "solid-js/web";

export type MenuItem =
  | { label: string; action: () => void; destructive?: boolean; disabled?: boolean; shortcut?: string }
  | { separator: true };

type Open = { x: number; y: number; items: MenuItem[] };

const [menu, setMenu] = createSignal<Open | null>(null);

/** Shows a menu at the pointer, or below an element. */
export function showMenu(event: MouseEvent, items: MenuItem[]) {
  event.preventDefault();
  event.stopPropagation();
  const target = event.currentTarget as HTMLElement | null;
  if (event.type === "click" && target) {
    const rect = target.getBoundingClientRect();
    setMenu({ x: rect.left, y: rect.bottom + 4, items });
  } else {
    setMenu({ x: event.clientX, y: event.clientY, items });
  }
}

/** The one context menu of the page. */
export function MenuHost(): JSX.Element {
  let el!: HTMLDivElement;
  const close = () => setMenu(null);
  const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
  onMount(() => {
    addEventListener("keydown", onKey);
    addEventListener("blur", close);
  });
  onCleanup(() => {
    removeEventListener("keydown", onKey);
    removeEventListener("blur", close);
  });
  return (
    <Show when={menu()}>
      {(m) => (
        <Portal>
          <div class="menu-backdrop" onMouseDown={close} onContextMenu={(e) => (e.preventDefault(), close())} />
          <div
            class="menu glass"
            ref={(node) => {
              el = node;
              // Keeps the menu on screen.
              requestAnimationFrame(() => {
                const rect = el.getBoundingClientRect();
                if (rect.right > innerWidth - 8) el.style.left = `${Math.max(8, innerWidth - rect.width - 8)}px`;
                if (rect.bottom > innerHeight - 8) el.style.top = `${Math.max(8, m().y - rect.height)}px`;
              });
            }}
            style={{ left: `${m().x}px`, top: `${m().y}px` }}
            role="menu"
          >
            <For each={m().items}>
              {(item) =>
                "separator" in item ? (
                  <div class="menu-separator" />
                ) : (
                  <button
                    class="menu-item"
                    classList={{ destructive: item.destructive }}
                    disabled={item.disabled}
                    role="menuitem"
                    onClick={() => {
                      close();
                      item.action();
                    }}
                  >
                    <span>{item.label}</span>
                    <Show when={item.shortcut}>
                      <span class="menu-shortcut">{item.shortcut}</span>
                    </Show>
                  </button>
                )
              }
            </For>
          </div>
        </Portal>
      )}
    </Show>
  );
}
