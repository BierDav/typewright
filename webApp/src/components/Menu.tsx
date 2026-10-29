import { type Component, createSignal, For, type JSX, onCleanup, onMount, Show } from "solid-js";
import { Portal } from "solid-js/web";
import { Check } from "./icons";

type Icon = Component<{ size?: number; class?: string }>;

export type MenuItem =
  | { label: string; action: () => void; destructive?: boolean; disabled?: boolean; shortcut?: string; checked?: boolean; icon?: Icon }
  | { separator: true }
  | { header: string };

type Action = Extract<MenuItem, { action: () => void }>;
type Open = { x: number; y: number; items: MenuItem[]; id: number; origin?: string };

const [menu, setMenu] = createSignal<Open | null>(null);
/** A menu fading out, kept on screen until its animation ends. */
const [leaving, setLeaving] = createSignal<Open | null>(null);
let menuId = 0;
/** Where focus goes back to once the menu closes, like the editor. */
let returnFocus: HTMLElement | null = null;

/** Whether a menu is open, so floating panels that opened it stay put. */
export const menuOpen = () => menu() !== null;

/** Shows a menu at the pointer, or below an element. */
export function showMenu(event: MouseEvent, items: MenuItem[]) {
  event.preventDefault();
  event.stopPropagation();
  const target = event.currentTarget as HTMLElement | null;
  const at = event.type === "click" && target ? (() => {
    const rect = target.getBoundingClientRect();
    return { x: rect.left, y: rect.bottom + 4 };
  })() : { x: event.clientX, y: event.clientY };
  setLeaving(null);
  if (!menu()) returnFocus = document.activeElement as HTMLElement | null;
  setMenu({ ...at, items: tidy(items), id: ++menuId });
}

export function closeMenu() {
  const open = menu();
  if (!open) return;
  setMenu(null);
  setLeaving(open);
  if (returnFocus?.isConnected && (!document.activeElement || document.activeElement === document.body || document.activeElement.closest(".menu"))) returnFocus.focus({ preventScroll: true });
  returnFocus = null;
  setTimeout(() => setLeaving((m) => (m === open ? null : m)), 140);
}

/** No separators at the ends or twice in a row, as menus built from conditions tend to have. */
function tidy(items: MenuItem[]): MenuItem[] {
  const out: MenuItem[] = [];
  for (const item of items) {
    if ("separator" in item && (!out.length || "separator" in out[out.length - 1])) continue;
    out.push(item);
  }
  while (out.length && "separator" in out[out.length - 1]) out.pop();
  return out;
}

function MenuView(props: { menu: Open; leaving?: boolean }): JSX.Element {
  let el!: HTMLDivElement;
  const m = props.menu;
  const [active, setActive] = createSignal(-1);
  const [origin, setOrigin] = createSignal(m.origin ?? "top left");
  const checks = m.items.some((i) => "checked" in i);
  const icons = m.items.some((i) => "icon" in i && i.icon);
  const enabled = (i: number) => {
    const item = m.items[i];
    return item && "action" in item && !item.disabled;
  };
  let typed = "";
  let typedTimer: ReturnType<typeof setTimeout> | undefined;

  function run(item: Action) {
    closeMenu();
    item.action();
  }

  function move(step: number) {
    const count = m.items.length;
    let i = active();
    for (let n = 0; n < count; n++) {
      i = (i + step + count) % count;
      if (enabled(i)) return setActive(i);
    }
  }

  function onKey(event: KeyboardEvent) {
    if (props.leaving) return;
    const key = event.key;
    if (key === "ArrowDown" || key === "ArrowUp") move(key === "ArrowDown" ? 1 : -1);
    else if (key === "Home") (setActive(-1), move(1));
    else if (key === "End") (setActive(m.items.length), move(-1));
    else if (key === "Enter" || key === " ") {
      const item = m.items[active()];
      if (item && "action" in item && !item.disabled) run(item);
    } else if (key === "Escape" || key === "Tab") closeMenu();
    else if (key.length === 1 && !event.metaKey && !event.ctrlKey) {
      // Typing jumps to the first item starting with what was typed.
      clearTimeout(typedTimer);
      typed += key.toLowerCase();
      typedTimer = setTimeout(() => (typed = ""), 700);
      const found = m.items.findIndex((item, i) => enabled(i) && "label" in item && item.label.toLowerCase().startsWith(typed));
      if (found >= 0) setActive(found);
    } else return;
    event.preventDefault();
    event.stopPropagation();
  }

  onMount(() => {
    if (props.leaving) return;
    // Keeps the menu on screen; it then grows from the corner nearest the pointer.
    const rect = el.getBoundingClientRect();
    let x = m.x;
    let y = m.y;
    let vertical = "top";
    let horizontal = "left";
    if (rect.right > innerWidth - 8) {
      x = Math.max(8, m.x - rect.width);
      horizontal = "right";
    }
    if (rect.bottom > innerHeight - 8) {
      y = Math.max(8, Math.min(m.y, innerHeight - 8) - rect.height);
      vertical = "bottom";
    }
    // The fading copy reuses the corrected place.
    m.x = x;
    m.y = y;
    m.origin = `${vertical} ${horizontal}`;
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    setOrigin(m.origin);
    el.focus({ preventScroll: true });
  });

  onCleanup(() => clearTimeout(typedTimer));

  return (
    <div
      class="menu"
      classList={{ leaving: props.leaving, "with-icons": icons }}
      ref={el}
      style={{ left: `${m.x}px`, top: `${m.y}px`, "transform-origin": origin() }}
      role="menu"
      tabIndex={-1}
      onKeyDown={onKey}
      onPointerLeave={() => setActive(-1)}
      onContextMenu={(e) => e.preventDefault()}
    >
      <For each={m.items}>
        {(item, index) =>
          "separator" in item ? (
            <div class="menu-separator" role="separator" />
          ) : "header" in item ? (
            <div class="menu-header">{item.header}</div>
          ) : (
            <button
              class="menu-item"
              classList={{ destructive: item.destructive, active: active() === index() }}
              disabled={item.disabled}
              role="menuitem"
              tabIndex={-1}
              onPointerMove={() => !item.disabled && setActive(index())}
              onClick={() => run(item)}
            >
              <Show when={checks}>
                <span class="menu-check">
                  <Show when={item.checked}>
                    <Check size={13} />
                  </Show>
                </span>
              </Show>
              <Show when={icons}>
                <span class="menu-icon">{item.icon ? <item.icon size={14} /> : null}</span>
              </Show>
              <span class="menu-label">{item.label}</span>
              <Show when={item.shortcut}>
                <span class="menu-shortcut">{item.shortcut}</span>
              </Show>
            </button>
          )
        }
      </For>
    </div>
  );
}

/** The one context menu of the page. */
export function MenuHost(): JSX.Element {
  const onKey = (e: KeyboardEvent) => e.key === "Escape" && closeMenu();
  onMount(() => {
    addEventListener("keydown", onKey);
    addEventListener("blur", closeMenu);
    addEventListener("resize", closeMenu);
  });
  onCleanup(() => {
    removeEventListener("keydown", onKey);
    removeEventListener("blur", closeMenu);
    removeEventListener("resize", closeMenu);
  });
  return (
    <Portal>
      <Show when={leaving()} keyed>
        {(m) => <MenuView menu={m} leaving />}
      </Show>
      <Show when={menu()} keyed>
        {(m) => (
          <>
            <div class="menu-backdrop" onMouseDown={closeMenu} onContextMenu={(e) => (e.preventDefault(), closeMenu())} />
            <MenuView menu={m} />
          </>
        )}
      </Show>
    </Portal>
  );
}
