import { createSignal, For, Match, onCleanup, onMount, Show, Switch } from "solid-js";
import CommandPalette from "~/components/CommandPalette";
import Dialogs from "~/components/Dialogs";
import Editor from "~/components/Editor";
import FileSidebar from "~/components/FileSidebar";
import FileViewer from "~/components/FileViewer";
import { Eye, EyeOff, Link, PanelLeft, PanelRight, Plus, Search, Upload } from "~/components/icons";
import { MenuHost } from "~/components/Menu";
import PreviewPane from "~/components/PreviewPane";
import SearchPanel from "~/components/SearchPanel";
import SettingsWindow from "~/components/Settings";
import SpacesSidebar, { importFolder, importZip, newSpace } from "~/components/SpacesSidebar";
import StatusBar from "~/components/StatusBar";
import { alert, isMac, lastSpace, openSpace, overlay, PENDING_JOIN, setOverlay, workspace } from "~/lib/app";
import * as commands from "~/lib/commands";
import { compiler } from "~/lib/compiler";
import { loadIdentity } from "~/lib/identity";
import { isEditable, isPreviewable } from "~/lib/kinds";
import { setSettings, settings } from "~/lib/settings";
import { refreshSpaces, spaces } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import * as syncService from "~/lib/sync";
import type { Workspace } from "~/lib/workspace";

function Welcome() {
  return (
    <div class="welcome">
      <img src={`${import.meta.env.BASE_URL}logo.png`} alt="" width="96" height="96" />
      <h1>Typewright</h1>
      <p class="secondary">Write Typst with a live preview. Everything stays in this browser, and syncs with your other devices and the people you invite.</p>
      <div class="welcome-actions">
        <button class="button primary" onClick={() => void newSpace()}>
          <Plus size={14} /> New Space
        </button>
        <button class="button" onClick={() => void importFolder()}>
          <Upload size={14} /> Import Folder
        </button>
        <button class="button" onClick={() => void importZip()}>
          Import Zip
        </button>
        <button
          class="button"
          onClick={async () => {
            const folder = await commands.joinFromLink();
            if (folder) openSpace(folder);
          }}
        >
          <Link size={14} /> Join Shared Space
        </button>
      </div>
      <Show when={spaces.names.length}>
        <p class="secondary">Or pick one of your spaces on the left.</p>
      </Show>
    </div>
  );
}

function Divider(props: { container: () => HTMLElement | undefined }) {
  function start(event: PointerEvent) {
    event.preventDefault();
    const el = event.currentTarget as HTMLElement;
    el.setPointerCapture(event.pointerId);
    document.body.classList.add("resizing");
    const move = (e: PointerEvent) => {
      const rect = props.container()?.getBoundingClientRect();
      if (!rect) return;
      setSettings("split", Math.min(0.8, Math.max(0.2, (rect.right - e.clientX) / rect.width)));
    };
    const end = () => {
      el.removeEventListener("pointermove", move);
      document.body.classList.remove("resizing");
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", end, { once: true });
  }
  return <div class="divider" onPointerDown={start} onDblClick={() => setSettings("split", 0.5)} role="separator" aria-orientation="vertical" />;
}

function Space(props: { workspace: Workspace }) {
  const ws = props.workspace;
  let split: HTMLDivElement | undefined;
  const editable = () => isEditable(ws.state.selectedKind);
  const selected = () => ws.state.selected;

  return (
    <div class="space">
      <Show when={settings.sidebarVisible}>
        <FileSidebar workspace={ws} />
      </Show>
      <div class="content">
        <div class="split" ref={split}>
          <section class="editor-pane">
            <header class="pane-header">
              <Show when={!settings.sidebarVisible || !settings.spacesVisible}>
                <button class="icon-button" title="Show sidebar" onClick={() => setSettings({ sidebarVisible: true, spacesVisible: true })}>
                  <PanelLeft size={15} />
                </button>
              </Show>
              <div class="breadcrumb">
                <Show when={selected()} fallback={<span class="secondary">No file selected</span>}>
                  <For each={selected()!.split("/")}>
                    {(part, i) => (
                      <>
                        <Show when={i() > 0}>
                          <span class="secondary">/</span>
                        </Show>
                        <span classList={{ current: i() === selected()!.split("/").length - 1 }}>{part}</span>
                      </>
                    )}
                  </For>
                </Show>
              </div>
              <div class="spacer" />
              <Show when={selected() && isPreviewable(selected()!)}>
                <button
                  class="icon-button"
                  classList={{ active: ws.state.preview === selected() }}
                  title={ws.state.preview === selected() ? "Hide preview" : "Preview this file"}
                  onClick={() => {
                    ws.togglePreview(selected()!);
                    if (settings.split === 0) setSettings("split", 0.5);
                  }}
                >
                  {ws.state.preview === selected() ? <EyeOff size={15} /> : <Eye size={15} />}
                </button>
              </Show>
              <button class="icon-button" title={`Find in ${ws.name}`} onClick={() => setOverlay({ type: "search", allSpaces: false })}>
                <Search size={15} />
              </button>
              <Show when={settings.split === 0}>
                <button class="icon-button" title="Show preview" onClick={() => setSettings("split", 0.5)}>
                  <PanelRight size={15} />
                </button>
              </Show>
            </header>
            <div class="editor-body">
              <div class="editor-host" classList={{ hidden: !editable() }}>
                <Editor workspace={ws} />
              </div>
              <Switch>
                <Match when={selected() && !editable() && ws.state.selectedKind}>
                  <FileViewer workspace={ws} path={selected()!} />
                </Match>
                <Match when={!selected() && ws.state.loaded}>
                  <div class="empty-state">
                    <p class="title">No file selected</p>
                    <p class="secondary">Pick a file in the sidebar, or press {isMac ? "⌘K" : "Ctrl+K"} to search.</p>
                  </div>
                </Match>
              </Switch>
            </div>
          </section>
          <Show when={settings.split > 0}>
            <Divider container={() => split} />
            <div class="preview-pane" style={{ width: `${settings.split * 100}%` }}>
              <PreviewPane workspace={ws} />
            </div>
          </Show>
        </div>
        <StatusBar workspace={ws} />
      </div>
    </div>
  );
}

export default function Home() {
  const [ready, setReady] = createSignal(false);

  function onKey(event: KeyboardEvent) {
    const mod = isMac ? event.metaKey : event.ctrlKey;
    if (!mod) return;
    const key = event.code;
    let handled = true;
    if (key === "KeyK" && !event.altKey && !event.shiftKey) setOverlay(overlay()?.type === "palette" ? null : { type: "palette" });
    else if (key === "KeyP" && !event.altKey && !event.shiftKey) setOverlay({ type: "palette" });
    else if (key === "Comma") setOverlay({ type: "settings" });
    else if (key === "KeyF" && event.shiftKey && !event.altKey) setOverlay({ type: "search", allSpaces: false });
    else if (key === "KeyS" && event.altKey) setSettings("spacesVisible", (v) => !v);
    // Edits save on their own, so ⌘S toggles the sidebar like in the Mac app.
    else if (key === "KeyS" && !event.shiftKey) setSettings("sidebarVisible", (v) => !v);
    else if (key === "KeyI" && event.altKey && workspace()?.state.selected) setOverlay({ type: "palette", page: `move:${workspace()!.state.selected}` });
    else if (key === "KeyW" && (isMac ? event.ctrlKey : event.shiftKey)) openSpace(null);
    else handled = false;
    if (handled) {
      event.preventDefault();
      event.stopPropagation();
    }
  }

  onMount(async () => {
    addEventListener("keydown", onKey, true);
    compiler.warmUp();
    try {
      await Promise.all([loadIdentity(), refreshSpaces()]);
      void syncService.restart();
      void fs.persist();
      const last = lastSpace();
      if (last && spaces.names.includes(last)) openSpace(last);
      else if (spaces.names.length) openSpace(spaces.names[0]);
    } catch (err) {
      void alert("Typewright couldn't start", String((err as Error)?.message ?? err));
    } finally {
      setReady(true);
    }
    // A web invite link opened the page.
    const pending = sessionStorage.getItem(PENDING_JOIN);
    if (pending) {
      sessionStorage.removeItem(PENDING_JOIN);
      const folder = await commands.joinFromLink(pending);
      if (folder) openSpace(folder);
    }
    // Another tab created, renamed or deleted a space.
    const unwatch = fs.onChange(({ paths }) => {
      if (paths.some((p) => fs.split(p).length <= 2 && fs.split(p)[0] === "spaces")) void refreshSpaces();
    });
    onCleanup(unwatch);
  });

  onCleanup(() => {
    removeEventListener("keydown", onKey, true);
    workspace()?.dispose();
  });

  return (
    <div class="app" classList={{ ready: ready() }}>
      <Show when={settings.spacesVisible}>
        <SpacesSidebar />
      </Show>
      <main class="main">
        <Show when={workspace()} keyed fallback={<Show when={ready()}><Welcome /></Show>}>
          {(ws) => <Space workspace={ws} />}
        </Show>
      </main>
      <Switch>
        <Match when={overlay()?.type === "palette"}>
          <CommandPalette page={(overlay() as { page?: string }).page} />
        </Match>
        <Match when={overlay()?.type === "search"}>
          <SearchPanel allSpaces={(overlay() as { allSpaces: boolean }).allSpaces} />
        </Match>
        <Match when={overlay()?.type === "settings"}>
          <SettingsWindow />
        </Match>
      </Switch>
      <Dialogs />
      <MenuHost />
    </div>
  );
}
