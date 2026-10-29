import { createEffect, createSignal, on, onCleanup, Show } from "solid-js";
import { desktop, type ScrollPhase } from "~/lib/desktop";
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
    let width = startWidth;
    let frame = 0;
    const move = (e: PointerEvent) => {
      width = Math.round(Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, startWidth + e.clientX - startX)));
      if (!frame) frame = requestAnimationFrame(() => { frame = 0; setSettings("sidebarWidth", width); });
    };
    const end = () => {
      cancelAnimationFrame(frame);
      setSettings("sidebarWidth", width);
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", end);
      el.removeEventListener("pointercancel", end);
      document.body.classList.remove("resizing");
      setResizing(false);
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", end, { once: true });
    el.addEventListener("pointercancel", end, { once: true });
  }
  return <div class="sidebar-resize" onPointerDown={start} onDblClick={() => setSettings("sidebarWidth", DEFAULT_WIDTH)} role="separator" aria-orientation="vertical" title="Drag to resize" />;
}

/** Rubber band past either end, like AppKit's: the further the pull, the less it moves; at most 12 %. */
function rubber(progress: number): number {
  const band = (x: number) => (1 - 1 / ((x * 0.55) / 0.12 + 1)) * 0.12;
  return progress > 1 ? 1 + band(progress - 1) : progress < 0 ? -band(-progress) : progress;
}

/** Native phases keep a resting finger from looking like a release; browsers settle after wheel silence. */
function useSpacesSwipe(sidebar: () => HTMLElement | undefined, shown: () => boolean) {
  let active = false;
  let tracking: boolean | null = null;
  let dx = 0, dy = 0, start = 0;
  let velocity = 0, lastTime = 0;
  let endTimer: ReturnType<typeof setTimeout> | undefined;

  function finish(cancelled = false) {
    if (tracking) {
      const projected = start + dx / (settings.sidebarWidth + SPACES_EXTRA) + velocity * 0.15 / (settings.sidebarWidth + SPACES_EXTRA);
      const open = cancelled ? start > 0.5 : projected > 0.5;
      if (open) setSpacesOpen(true);
      else closeSpaces();
      setSwipe(null);
    }
    active = false;
    tracking = null;
    velocity = 0;
  }

  function begin(target: Node | null): boolean {
    if (!workspace() || overlay() || !shown() || (!sidebar()?.contains(target) && !spacesOpen())) return false;
    active = true;
    tracking = null;
    dx = dy = velocity = 0;
    start = spacesOpen() ? 1 : 0;
    lastTime = performance.now();
    return true;
  }

  function move(x: number, y: number) {
    const time = performance.now(), elapsed = Math.max((time - lastTime) / 1000, 0.001);
    velocity += (x / elapsed - velocity) * (1 - Math.exp(-elapsed / 0.06));
    lastTime = time;
    dx += x;
    dy += y;
    if (tracking === null && Math.abs(dx) + Math.abs(dy) >= 6) tracking = Math.abs(dx) > Math.abs(dy) * 1.5;
    if (tracking) setSwipe(rubber(start + dx / (settings.sidebarWidth + SPACES_EXTRA)));
  }

  function nativeScroll(event: ScrollPhase) {
    if (event.momentum) return;
    if (event.phase & 1) {
      if (active) finish(true);
      if (!begin(document.elementFromPoint(event.x, event.y))) return;
    }
    if (!active) return;
    if (event.phase & (8 | 16)) {
      if (performance.now() - lastTime > 100) velocity = 0;
      finish(!!(event.phase & 16));
    } else move(event.dx, event.dy);
  }

  function onWheel(event: WheelEvent) {
    if (event.ctrlKey || event.deltaMode !== 0 || !workspace() || overlay() || !shown()) return;
    if (desktop?.scrollPhases) {
      if ((active && tracking) || Math.abs(event.deltaX) > Math.abs(event.deltaY) * 1.5 && (sidebar()?.contains(event.target as Node) || spacesOpen())) event.preventDefault();
      return;
    }
    if (!active && !begin(event.target as Node)) return;
    clearTimeout(endTimer);
    endTimer = setTimeout(() => { velocity = 0; finish(); }, 180);
    move(-event.deltaX, event.deltaY);
    if (tracking) event.preventDefault();
  }

  const subscription = desktop?.scrollPhases?.(nativeScroll);
  addEventListener("wheel", onWheel, { passive: false });
  onCleanup(() => {
    removeEventListener("wheel", onWheel);
    void subscription?.then((stop) => stop());
    clearTimeout(endTimer);
    if (active) finish(true);
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
  const hideNativeButtons = () => desktop?.hoverButtons({ x: 0, y: 0, width: 0, height: 0 });
  createEffect(() => { if (!shown()) hideNativeButtons(); });
  onCleanup(() => { clearTimeout(hideTimer); hideNativeButtons(); });
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
          <Show when={desktop?.platform === "darwin"}>
            <div class="window-controls" role="group" aria-label="Window controls" onPointerEnter={event => {
              const rect = event.currentTarget.getBoundingClientRect();
              desktop?.hoverButtons({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
            }}>
              <button class="window-control close" aria-label="Close window" onClick={() => desktop?.windowControl("close")}></button>
              <button class="window-control minimize" aria-label="Minimize window" onClick={() => desktop?.windowControl("minimize")}></button>
              <button class="window-control zoom" aria-label="Zoom window" onClick={() => desktop?.windowControl("zoom")}></button>
            </div>
          </Show>
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
