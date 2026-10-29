import { createEffect, createSignal, on, onCleanup, Show } from "solid-js";
import { desktop } from "~/lib/desktop";
import { dialogs, floatingSidebar, isMac, overlay, setFloatingSidebar, spacesOpen, toggleSidebar, workspace } from "~/lib/app";
import { setSettings, settings } from "~/lib/settings";
import FileSidebar from "./FileSidebar";
import { PanelLeftClose, Pin } from "./icons";
import { menuOpen } from "./Menu";
import SpacesSidebar from "./SpacesSidebar";

const MIN_WIDTH = 200;
const MAX_WIDTH = 440;
const DEFAULT_WIDTH = 264;
/** A width drag in progress, which keeps the floating sidebar out. */
const [resizing, setResizing] = createSignal(false);

/** Pins the floating sidebar, or hides the pinned one. */
export function SidebarToggle() {
  const label = () => (settings.sidebarVisible ? "Hide Sidebar" : "Keep Sidebar Open");
  return (
    <Show when={workspace()}>
      <button class="round-button" title={`${label()} (${isMac ? "⌘S" : "Ctrl+S"})`} aria-label={label()} onClick={() => toggleSidebar()}>
        <Show when={settings.sidebarVisible} fallback={<Pin size={15} />}>
          <PanelLeftClose size={15} />
        </Show>
      </button>
    </Show>
  );
}

function ResizeHandle() {
  function start(event: PointerEvent) {
    event.preventDefault();
    const el = event.currentTarget as HTMLElement;
    el.setPointerCapture(event.pointerId);
    document.body.classList.add("resizing");
    setResizing(true);
    const startX = event.clientX;
    const startWidth = settings.sidebarWidth;
    const move = (e: PointerEvent) => setSettings("sidebarWidth", Math.round(Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, startWidth + e.clientX - startX))));
    const end = () => {
      el.removeEventListener("pointermove", move);
      document.body.classList.remove("resizing");
      setResizing(false);
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", end, { once: true });
  }
  return <div class="sidebar-resize" onPointerDown={start} onDblClick={() => setSettings("sidebarWidth", DEFAULT_WIDTH)} role="separator" aria-orientation="vertical" title="Drag to resize" />;
}

/** The one sidebar, floating over the window like the Mac app's: the space's files, or the list of spaces. */
export default function Sidebar() {
  const pinned = () => settings.sidebarVisible || !workspace();
  const shown = () => pinned() || (floatingSidebar() && !overlay());
  const [hovering, setHovering] = createSignal(false);
  const [dragging, setDragging] = createSignal(false);
  let hideTimer: ReturnType<typeof setTimeout> | undefined;
  // Drag events enter and leave every row; the count says whether the drag is still inside.
  let dragDepth = 0;

  // Menus, questions and the spaces list it opened keep it out.
  const held = () => menuOpen() || dialogs.length > 0 || spacesOpen() || hovering() || dragging() || resizing();

  function show() {
    clearTimeout(hideTimer);
    hideTimer = undefined;
    if (!pinned()) setFloatingSidebar(true);
  }

  /** A short grace period, so brushing past its edge doesn't close it. */
  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (!held()) setFloatingSidebar(false);
    }, 350);
  }

  createEffect(on(held, (now) => (now ? show() : floatingSidebar() && scheduleHide()), { defer: true }));
  createEffect(on(pinned, (now) => now && setHovering(false), { defer: true }));
  // The window buttons live in the sidebar's corner, so they come and go with it.
  createEffect(() => desktop?.setTrafficLights(shown()));
  onCleanup(() => clearTimeout(hideTimer));

  return (
    <>
      <div class="sidebar-dock" classList={{ collapsed: !pinned() }} style={{ "--sidebar-width": `${settings.sidebarWidth}px` }}>
        <aside
          class="sidebar"
          classList={{ floating: !pinned(), shown: shown() }}
          aria-hidden={!shown()}
          onPointerEnter={() => !pinned() && setHovering(true)}
          onPointerLeave={() => setHovering(false)}
          onDragEnter={() => !pinned() && dragDepth++ === 0 && setDragging(true)}
          onDragLeave={() => dragDepth > 0 && --dragDepth === 0 && setDragging(false)}
          onDrop={() => ((dragDepth = 0), setDragging(false))}
          onKeyDown={(e) => {
            if (e.key === "Escape" && !pinned() && !held()) setFloatingSidebar(false);
          }}
        >
          <Show when={workspace() && !spacesOpen()} fallback={<SpacesSidebar />}>
            <FileSidebar workspace={workspace()!} />
          </Show>
          <ResizeHandle />
        </aside>
      </div>
      <Show when={!pinned() && !overlay()}>
        {/* The strip that summons it; thin, so the editor's edge stays clickable. */}
        <div class="sidebar-edge" onPointerEnter={show} onDragEnter={show} onPointerLeave={scheduleHide} onDragLeave={scheduleHide} />
      </Show>
    </>
  );
}
