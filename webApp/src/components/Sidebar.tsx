import { createEffect, createSignal, on, onCleanup, Show } from "solid-js";
import { desktop } from "~/lib/desktop";
import { closeSpaces, dialogs, SPACES_EXTRA, floatingSidebar, isMac, overlay, setFloatingSidebar, setSpacesOpen, setSwipe, spacesOpen, spacesProgress, swipe, toggleSidebar, workspace } from "~/lib/app";
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

/** Rubber band past either end, like AppKit's: the further the pull, the less it moves; at most 12 %. */
function rubber(progress: number): number {
  const band = (x: number) => (1 - 1 / ((x * 0.55) / 0.12 + 1)) * 0.12;
  return progress > 1 ? 1 + band(progress - 1) : progress < 0 ? -band(-progress) : progress;
}

/**
 * Horizontal two-finger swipes, like the Mac app's: right over the sidebar reveals the spaces list, left returns to
 * the space, and the list follows the fingers both ways. Browsers report no gesture phases, so a swipe ends once its
 * events (momentum included) pause, and then settles on the nearer side.
 */
function useSpacesSwipe(sidebar: () => HTMLElement | undefined, shown: () => boolean) {
  let active = false;
  /** null until the gesture's direction is known. */
  let tracking: boolean | null = null;
  let dx = 0;
  let dy = 0;
  let start = 0;
  let endTimer: ReturnType<typeof setTimeout> | undefined;

  function settle() {
    if (tracking) {
      const progress = swipe() ?? start;
      if (progress > 0.5) setSpacesOpen(true);
      else closeSpaces();
      setSwipe(null);
    }
    active = false;
    tracking = null;
  }

  function onWheel(event: WheelEvent) {
    // Pinch zoom arrives as wheel events with Ctrl held; mouse wheels scroll by lines.
    if (!workspace() || overlay() || !shown() || event.ctrlKey || event.deltaMode !== 0) return;
    if (!active) {
      // Over the document, only an open list follows a swipe.
      if (!sidebar()?.contains(event.target as Node) && !spacesOpen()) return;
      active = true;
      tracking = null;
      dx = dy = 0;
      start = spacesOpen() ? 1 : 0;
    }
    clearTimeout(endTimer);
    endTimer = setTimeout(settle, 120);
    // Fingers moving right give a positive distance, with natural scrolling.
    dx -= event.deltaX;
    dy += event.deltaY;
    if (tracking === null) {
      if (Math.abs(dx) + Math.abs(dy) < 6) return;
      tracking = Math.abs(dx) > Math.abs(dy) * 1.5;
    }
    if (!tracking) return;
    event.preventDefault();
    setSwipe(rubber(start + dx / (settings.sidebarWidth + SPACES_EXTRA)));
  }

  addEventListener("wheel", onWheel, { passive: false });
  onCleanup(() => {
    removeEventListener("wheel", onWheel);
    clearTimeout(endTimer);
  });
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
  const held = () => menuOpen() || dialogs.length > 0 || spacesOpen() || swipe() !== null || hovering() || dragging() || resizing();

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
  let aside: HTMLElement | undefined;
  useSpacesSwipe(() => aside, shown);
  // Without a space the list always shows.
  const progress = () => (workspace() ? spacesProgress() : 1);
  const open = () => Math.min(1, Math.max(0, progress()));
  // Pulled past the files, they move along a little.
  const filesStyle = () => ({
    transform: `translateX(${Math.min(0, progress()) * settings.sidebarWidth}px) scale(${1 - 0.08 * open()})`,
    opacity: 1 - open(),
  });
  createEffect(() => document.body.classList.toggle("swiping", swipe() !== null));

  return (
    <>
      <div
        class="sidebar-dock"
        classList={{ collapsed: !pinned() }}
        style={{ "--sidebar-width": `${settings.sidebarWidth}px`, "--spaces-extra": `${SPACES_EXTRA}px`, "--spaces-open": `${Math.max(0, progress())}` }}
      >
        <aside
          ref={aside}
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
          {/* Both stay mounted, so the list slides in over the files and back out. */}
          <Show when={workspace()} keyed>
            {(ws) => (
              <div class="sidebar-layer files" style={filesStyle()} inert={open() === 1} aria-hidden={open() === 1}>
                <FileSidebar workspace={ws} />
              </div>
            )}
          </Show>
          <div class="sidebar-layer spaces" style={{ transform: `translateX(${(open() - 1) * 100}%)` }} inert={open() === 0} aria-hidden={open() === 0}>
            <SpacesSidebar />
          </div>
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
