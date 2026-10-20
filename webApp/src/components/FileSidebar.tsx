import { createSignal, For, type JSX, Match, Show, Switch } from "solid-js";
import { alert, confirm, copyText, openSpace, prompt, setOverlay } from "~/lib/app";
import * as commands from "~/lib/commands";
import { pickFiles, readDrop } from "~/lib/drop";
import { isPreviewable, mimeType } from "~/lib/kinds";
import { cleanName, download, renameSpace, spacePath, zipSpace } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import * as syncService from "~/lib/sync";
import { type FileNode, Workspace } from "~/lib/workspace";
import { ChevronRight, Ellipsis, Eye, File, FileCode, FileImage, FilePlus, FileText, Folder, FolderPlus, Type, Upload, Users } from "./icons";
import { type MenuItem, showMenu } from "./Menu";

const DRAG_TYPE = "application/x-typewright-path";

function NodeIcon(props: { node: FileNode; open: boolean }): JSX.Element {
  return (
    <Switch fallback={<File size={15} />}>
      <Match when={props.node.children}>
        <Folder size={15} class="folder-icon" />
      </Match>
      <Match when={props.node.kind === "typst"}>
        <span class="typ-icon">t</span>
      </Match>
      <Match when={props.node.kind === "image"}>
        <FileImage size={15} />
      </Match>
      <Match when={props.node.kind === "font"}>
        <Type size={15} />
      </Match>
      <Match when={props.node.kind === "text" && /\.(md|markdown)$/i.test(props.node.name)}>
        <FileText size={15} />
      </Match>
      <Match when={props.node.kind === "text"}>
        <FileCode size={15} />
      </Match>
    </Switch>
  );
}

export default function FileSidebar(props: { workspace: Workspace }) {
  const ws = props.workspace;
  const [dropTarget, setDropTarget] = createSignal<string | null>(null);

  async function newFile(dir = "") {
    const name = await prompt(`New File in ${dir || ws.name}`, "", "Create", undefined, "Name, e.g. chapter.typ");
    if (name !== null) await ws.createFile(dir, name);
  }

  async function newFolder(dir = "") {
    const name = await prompt(`New Folder in ${dir || ws.name}`, "", "Create", undefined, "Folder name");
    if (name !== null) await ws.createFolder(dir, name);
  }

  async function upload(dir = "") {
    const files = await pickFiles();
    if (files.length) await ws.importFiles(dir, files);
  }

  async function rename(node: FileNode) {
    const name = await prompt(`Rename ${node.name}`, node.name, "Rename");
    if (name !== null) await ws.rename(node.path, name);
  }

  async function moveTo(node: FileNode) {
    setOverlay({ type: "palette", page: `move:${node.path}` });
  }

  async function remove(node: FileNode) {
    const ok = await confirm(`Delete “${node.name}”?`, "It moves to the trash in Settings › General, where you can bring it back.", "Delete", true);
    if (ok) await ws.delete(node.path);
  }

  async function save(node: FileNode) {
    if (node.children) {
      // Folders download as a zip of their files.
      const { zipSync } = await import("fflate");
      const files: Record<string, Uint8Array> = {};
      for (const entry of await fs.walk(fs.join(ws.root, node.path))) {
        if (entry.kind === "file") files[`${node.name}/${entry.path}`] = (await fs.readFile(fs.join(ws.root, node.path, entry.path)))!;
      }
      download(`${node.name}.zip`, zipSync(files), "application/zip");
    } else {
      const bytes = await fs.readFile(fs.join(ws.root, node.path));
      if (bytes) download(node.name, bytes, mimeType(node.path));
    }
  }

  function menuFor(node: FileNode): MenuItem[] {
    const dir = node.children ? node.path : fs.dirname(node.path);
    const items: MenuItem[] = [];
    if (!node.children) items.push({ label: "Open", action: () => void ws.select(node.path) });
    if (isPreviewable(node.path)) {
      items.push({ label: ws.state.preview === node.path ? "Hide Preview" : "Preview", action: () => ws.togglePreview(node.path) });
    }
    if (node.kind === "typst") items.push({ label: "Find Usages", action: () => setOverlay({ type: "palette", page: `usages:${node.path}` }) });
    items.push(
      { separator: true },
      { label: "New File Here…", action: () => void newFile(dir) },
      { label: "New Folder Here…", action: () => void newFolder(dir) },
      { label: "Upload Files Here…", action: () => void upload(dir) },
      { separator: true },
      { label: "Rename…", action: () => void rename(node) },
      { label: "Move To…", action: () => void moveTo(node) },
      { label: "Copy Relative Path", action: () => void copyText(node.path, "Path copied") },
      { label: node.children ? "Download as Zip" : "Download", action: () => void save(node) },
      { separator: true },
      { label: "Delete", destructive: true, action: () => void remove(node) },
    );
    return items;
  }

  function spaceMenu(): MenuItem[] {
    const synced = syncService.isSynced(ws.folder);
    return [
      { label: "New File…", action: () => void newFile() },
      { label: "New Folder…", action: () => void newFolder() },
      { label: "Upload Files…", action: () => void upload() },
      {
        label: "Upload Folder…",
        action: async () => {
          const files = await pickFiles({ directory: true });
          if (files.length) await ws.importFiles("", files);
        },
      },
      { separator: true },
      { label: "Rename Space…", action: () => void renameCurrentSpace(ws) },
      { label: "Download Space as Zip", action: async () => download(`${ws.folder}.zip`, await zipSpace(ws.folder), "application/zip") },
      { separator: true },
      synced
        ? { label: "Stop Syncing on This Device", action: () => syncService.stopSyncing(ws.folder) }
        : { label: "Sync to My Devices", disabled: !syncService.isRunning(), action: () => syncService.share(ws.folder) },
      { label: "Copy Invite Link…", action: () => void commands.copyInviteLink(ws.folder) },
    ];
  }

  async function onDrop(event: DragEvent, dir: string) {
    event.preventDefault();
    event.stopPropagation();
    setDropTarget(null);
    const moved = event.dataTransfer?.getData(DRAG_TYPE);
    if (moved) return ws.move(moved, dir);
    if (event.dataTransfer) await ws.importFiles(dir, await readDrop(event.dataTransfer));
  }

  function dropProps(dir: string) {
    return {
      onDragOver: (e: DragEvent) => {
        e.preventDefault();
        e.stopPropagation();
        setDropTarget(dir);
      },
      onDragLeave: () => setDropTarget((t) => (t === dir ? null : t)),
      onDrop: (e: DragEvent) => void onDrop(e, dir),
    };
  }

  function Row(rowProps: { node: FileNode; depth: number }): JSX.Element {
    const node = rowProps.node;
    const open = () => ws.state.expanded.includes(node.path);
    const folderDrop = node.children ? dropProps(node.path) : dropProps(fs.dirname(node.path));
    return (
      <>
        <div
          class="tree-row"
          classList={{
            selected: ws.state.selected === node.path,
            "drop-target": !!node.children && dropTarget() === node.path,
          }}
          style={{ "padding-left": `${8 + rowProps.depth * 14}px` }}
          draggable={true}
          onDragStart={(e) => e.dataTransfer?.setData(DRAG_TYPE, node.path)}
          {...folderDrop}
          onClick={() => (node.children ? ws.toggleExpanded(node.path) : void ws.select(node.path))}
          onDblClick={() => !node.children && isPreviewable(node.path) && ws.setPreview(node.path)}
          onContextMenu={(e) => showMenu(e, menuFor(node))}
          title={node.path}
        >
          <span class="disclosure" classList={{ open: open(), hidden: !node.children }}>
            <ChevronRight size={12} />
          </span>
          <NodeIcon node={node} open={open()} />
          <span class="tree-name">{node.name}</span>
          <Show when={ws.state.preview === node.path}>
            <Eye size={13} class="tree-badge" />
          </Show>
        </div>
        <Show when={node.children && open()}>
          <For each={node.children}>{(child) => <Row node={child} depth={rowProps.depth + 1} />}</For>
        </Show>
      </>
    );
  }

  return (
    <aside class="file-sidebar">
      <header class="pane-header">
        <button class="space-name" title="Rename space" onClick={() => void renameCurrentSpace(ws)}>
          {ws.name}
        </button>
        <Show when={syncService.isShared(ws.folder)}>
          <Users size={13} class="secondary" />
        </Show>
        <div class="spacer" />
        <button class="icon-button" title="New file" onClick={() => void newFile()}>
          <FilePlus size={15} />
        </button>
        <button class="icon-button" title="New folder" onClick={() => void newFolder()}>
          <FolderPlus size={15} />
        </button>
        <button class="icon-button" title="Upload files" onClick={() => void upload()}>
          <Upload size={15} />
        </button>
        <button class="icon-button" title="More" onClick={(e) => showMenu(e, spaceMenu())}>
          <Ellipsis size={15} />
        </button>
      </header>
      <div class="tree" classList={{ "drop-target": dropTarget() === "" }} {...dropProps("")} onContextMenu={(e) => showMenu(e, spaceMenu())}>
        <For each={ws.state.tree}>{(node) => <Row node={node} depth={0} />}</For>
        <Show when={ws.state.loaded && ws.state.tree.length === 0}>
          <div class="empty-state small">
            <p class="secondary">No files yet. Drop files here or create one.</p>
          </div>
        </Show>
      </div>
    </aside>
  );
}

export async function renameCurrentSpace(ws: Workspace) {
  const name = await prompt(`Rename “${ws.folder}”`, ws.folder, "Rename");
  const clean = name ? cleanName(name) : "";
  if (!clean || clean === ws.folder) return;
  if (await fs.exists(spacePath(clean))) return alert(`There's already a space named “${clean}”.`);
  await ws.flushSaves();
  const old = ws.folder;
  openSpace(null);
  // Sync follows the new name before the folder moves, so it never sees the space vanish.
  syncService.renamed(old, clean);
  const renamed = await renameSpace(old, clean);
  if (renamed) Workspace.renameState(old, renamed);
  else syncService.renamed(clean, old);
  openSpace(renamed ?? old);
}
