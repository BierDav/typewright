import { createSignal, For, Show } from "solid-js";
import { choose, confirm, openSpace, prompt, setOverlay, showRecentlyDeleted, toast, workspace } from "~/lib/app";
import * as commands from "~/lib/commands";
import { pickFiles, stripTopFolder } from "~/lib/drop";
import { identity } from "~/lib/identity";
import { createSpace, deleteSpace, download, importFiles, moveSpace, restoreSpace, spaces, unzip, zipSpace } from "~/lib/spaces";
import * as syncService from "~/lib/sync";
import { sync } from "~/lib/sync";
import { Cloud, CloudOff, Download, Layers, Link, Plus, Settings, UserPlus, Users } from "./icons";
import { SyncBadge } from "./SyncBadge";
import { renameCurrentSpace } from "./FileSidebar";
import { type MenuItem, showMenu } from "./Menu";

export async function newSpace() {
  const name = await prompt("New Space", "", "Create", "A space is a folder for one document or project.", "Space name");
  if (name === null) return;
  openSpace(await createSpace(name || "Untitled Space"));
}

export async function importZip() {
  const [picked] = await pickFiles({ accept: ".zip,application/zip", multiple: false });
  if (!picked) return;
  const files = unzip(new Uint8Array(await picked.file.arrayBuffer()));
  const folder = await createSpace(picked.path.replace(/\.zip$/i, ""), false);
  await importFiles(folder, "", files);
  openSpace(folder);
}

export async function importFolder() {
  const picked = await pickFiles({ directory: true });
  if (!picked.length) return;
  const { name, files } = stripTopFolder(picked);
  const folder = await createSpace(name ?? "Imported Space", false);
  await importFiles(folder, "", files);
  openSpace(folder);
}

async function removeSpace(folder: string) {
  const synced = syncService.syncsAnything(folder);
  const ok = await confirm(
    `Delete “${folder}”?`,
    synced
      ? "It stops syncing here, so your other devices and the people you invited keep their copies. You can get it back from Recently Deleted, and it syncs again then."
      : "You can undo this, or get it back later from Recently Deleted.",
    "Delete",
    true,
  );
  if (!ok) return;
  // Deleting parks its shares first, so the deletion doesn't reach everyone else.
  if (workspace()?.folder === folder) openSpace(null);
  const item = await deleteSpace(folder);
  if (item) {
    toast(`Deleted “${folder}”`, [
      { label: "Undo", run: () => void restoreSpace(item).then((ok) => ok && openSpace(folder)) },
      { label: "Show Recently Deleted", run: () => showRecentlyDeleted(null) },
    ]);
  }
}

async function removeEverywhere(id: string, name: string) {
  const ok = await confirm(
    `Remove “${name}” from all devices?`,
    "Every device stops syncing it and keeps its files. People you invited keep syncing among themselves.",
    "Remove",
    true,
  );
  if (ok) syncService.removeEverywhere(id);
}

function spaceMenu(folder: string): MenuItem[] {
  const items: MenuItem[] = [
    { label: "Open", action: () => openSpace(folder) },
    {
      label: "Rename…",
      action: () => {
        openSpace(folder);
        const ws = workspace();
        if (ws) void renameCurrentSpace(ws);
      },
    },
    { label: "Download as Zip", action: async () => download(`${folder}.zip`, await zipSpace(folder), "application/zip") },
    { separator: true },
  ];
  items.push({ label: "Share…", disabled: !syncService.isRunning(), action: () => void commands.share(folder) });
  items.push(
    { separator: true },
    { label: "Show Recently Deleted", action: () => showRecentlyDeleted(folder) },
    { label: "Delete Space…", destructive: true, action: () => void removeSpace(folder) },
  );
  return items;
}

function addMenu(): MenuItem[] {
  return [
    { label: "New Space…", action: () => void newSpace() },
    { label: "Import Folder…", action: () => void importFolder() },
    { label: "Import Zip…", action: () => void importZip() },
    { separator: true },
    { label: "Join Shared Space…", action: async () => {
      const folder = await commands.joinFromLink();
      if (folder) openSpace(folder);
    } },
  ];
}

export async function fetchSpace(share: syncService.AccountShare) {
  if (share.kind === "space") {
    const ok = await choose(`Download “${share.name}”?`, "Its files download from your other devices into a new space here and stay in sync.", [
      { label: "Cancel", value: "cancel", role: "cancel" },
      { label: "Download", value: "ok", role: "default" },
      { label: "Link to an Existing Space…", value: "link" },
    ]);
    if (ok === "link") {
      setOverlay({ type: "palette", page: `link-share:${share.id}` });
      return;
    }
    if (ok !== "ok") return;
  }
  // Own spaces land next to the others; folders and files go where the user picks.
  const dest = share.kind === "space" ? await syncService.suggestedDestination(share) : await commands.pickDestination(share.name, share.kind === "file");
  if (!dest) return;
  const path = await syncService.join(share, dest);
  if (path) openSpace(path.split("/")[0]);
  return path;
}

export default function SpacesSidebar() {
  const [dragging, setDragging] = createSignal<string | null>(null);
  const [over, setOver] = createSignal<number | null>(null);

  return (
    <nav class="spaces-sidebar">
      <header class="pane-header">
        <span class="section-title">Spaces</span>
        <div class="spacer" />
        <button class="icon-button" title="New space" onClick={(e) => showMenu(e, addMenu())}>
          <Plus size={16} />
        </button>
      </header>
      <div class="spaces-list" onDragLeave={() => setOver(null)}>
        <For each={spaces.names}>
          {(folder, index) => (
            <div
              class="space-row"
              classList={{ selected: workspace()?.folder === folder, "drop-before": over() === index() && dragging() !== folder }}
              draggable={true}
              onDragStart={(e) => {
                setDragging(folder);
                e.dataTransfer!.effectAllowed = "move";
              }}
              onDragOver={(e) => {
                if (!dragging()) return;
                e.preventDefault();
                setOver(index());
              }}
              onDrop={(e) => {
                e.preventDefault();
                const moved = dragging();
                if (moved) moveSpace(moved, index() > spaces.names.indexOf(moved) ? index() - 1 : index());
                setDragging(null);
                setOver(null);
              }}
              onDragEnd={() => {
                setDragging(null);
                setOver(null);
              }}
              onContextMenu={(e) => showMenu(e, spaceMenu(folder))}
              title="Drag to reorder"
            >
              <button class="space-open" onClick={() => openSpace(folder)}>
                <Layers size={15} class="space-icon" />
                <span class="space-label">{folder}</span>
              </button>
              <button class="icon-button" title="Sharing…" aria-label="Sharing…" onClick={() => void commands.share(folder)}>
                <SyncBadge path={folder} />
                <Show when={!syncService.isSynced(folder) && !syncService.isShared(folder)}><UserPlus size={13} class="secondary" /></Show>
              </button>
            </div>
          )}
        </For>
        <Show when={spaces.loaded && spaces.names.length === 0}>
          <p class="secondary hint">No spaces yet.</p>
        </Show>
        <Show when={syncService.elsewhere().length > 0}>
          <div class="section-title sub">On Other Devices</div>
          <For each={syncService.elsewhere()}>
            {(space) => (
              <button
                class="space-row remote"
                onClick={() => void fetchSpace(space)}
                onContextMenu={(e) =>
                  showMenu(e, [
                    { label: "Download…", action: () => void fetchSpace(space) },
                    { separator: true },
                    { label: "Remove From All Devices…", destructive: true, action: () => void removeEverywhere(space.id, space.name) },
                  ])
                }
                title={`Download “${space.name}” from your other devices`}
              >
                <Download size={15} class="space-icon" />
                <span class="space-label">{space.name}</span>
                <Show when={space.shared}>
                  <Users size={13} class="secondary" />
                </Show>
              </button>
            )}
          </For>
        </Show>
      </div>
      <footer class="spaces-footer">
        <button class="sync-status" onClick={() => setOverlay({ type: "settings", tab: "devices" })} title="Devices and syncing">
          <Show when={identity.account} fallback={<><CloudOff size={14} /> <span>Sign in to sync</span></>}>
            <Show
              when={sync.status === "running"}
              fallback={<><CloudOff size={14} /> <span>{sync.status === "elsewhere" ? "Syncing in another tab" : sync.status === "starting" ? "Starting sync…" : "Sync off"}</span></>}
            >
              <Cloud size={14} />
              <span>
                {sync.connected.length > 0 ? `${sync.connected.length} connected` : "Synced"}
              </span>
            </Show>
          </Show>
        </button>
        <button class="icon-button" title="Join a shared space" onClick={async () => {
          const folder = await commands.joinFromLink();
          if (folder) openSpace(folder);
        }}>
          <Link size={15} />
        </button>
        <button class="icon-button" title="Settings" onClick={() => setOverlay({ type: "settings" })}>
          <Settings size={15} />
        </button>
      </footer>
    </nav>
  );
}
