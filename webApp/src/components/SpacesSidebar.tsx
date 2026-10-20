import { createSignal, For, Show } from "solid-js";
import { choose, confirm, openSpace, prompt, setOverlay, workspace } from "~/lib/app";
import * as commands from "~/lib/commands";
import { pickFiles, stripTopFolder } from "~/lib/drop";
import { identity } from "~/lib/identity";
import { createSpace, deleteSpace, download, importFiles, moveSpace, spaces, unzip, zipSpace } from "~/lib/spaces";
import * as syncService from "~/lib/sync";
import { sync } from "~/lib/sync";
import { Cloud, CloudOff, Download, Layers, Link, Plus, Settings, Users } from "./icons";
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
  const synced = syncService.isSynced(folder);
  const ok = await confirm(
    `Delete “${folder}”?`,
    synced
      ? "Its files are deleted from this browser. It stops syncing here first, so your other devices and the people you invited keep their copies."
      : "Its files are deleted from this browser. Download it as a zip first if you want to keep a copy.",
    "Delete",
    true,
  );
  if (!ok) return;
  // Stopping first keeps the deletion from syncing to everyone else.
  if (synced) syncService.stopSyncing(folder);
  if (workspace()?.folder === folder) openSpace(null);
  await deleteSpace(folder);
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
  const synced = syncService.isSynced(folder);
  const id = syncService.spaceId(folder);
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
  if (synced) {
    items.push({ label: "Copy Invite Link…", action: () => void commands.copyInviteLink(folder) });
    items.push({ label: "Stop Syncing on This Device", action: () => syncService.stopSyncing(folder) });
    if (id) items.push({ label: "Remove From All Devices…", destructive: true, action: () => void removeEverywhere(id, folder) });
  } else {
    items.push({ label: "Sync to My Devices", disabled: !syncService.isRunning(), action: () => syncService.share(folder) });
    items.push({ label: "Copy Invite Link…", disabled: !syncService.isRunning(), action: () => void commands.copyInviteLink(folder) });
  }
  items.push({ separator: true }, { label: "Delete Space…", destructive: true, action: () => void removeSpace(folder) });
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

export default function SpacesSidebar() {
  const [dragging, setDragging] = createSignal<string | null>(null);
  const [over, setOver] = createSignal<number | null>(null);

  async function fetchSpace(space: syncService.AccountSpace) {
    const ok = await choose(`Download “${space.name}”?`, "Its files download from your other devices into a new space here and stay in sync.", [
      { label: "Cancel", value: "cancel", role: "cancel" },
      { label: "Download", value: "ok", role: "default" },
    ]);
    if (ok !== "ok") return;
    const folder = await syncService.join(space);
    if (folder) openSpace(folder);
  }

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
            <button
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
              onClick={() => openSpace(folder)}
              onContextMenu={(e) => showMenu(e, spaceMenu(folder))}
              title="Drag to reorder"
            >
              <Layers size={15} class="space-icon" />
              <span class="space-label">{folder}</span>
              <Show when={syncService.isShared(folder)}>
                <Users size={13} class="secondary" aria-label="Shared" />
              </Show>
              <Show when={syncService.isSynced(folder) && !syncService.isShared(folder)}>
                <Cloud size={13} class="secondary" aria-label="Synced" />
              </Show>
            </button>
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
