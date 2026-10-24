// Deleted files and folders, found again in the history: there's no trash, deleting is a commit (like the Mac app's
// Recently Deleted window).
import { createMemo, createResource, createSignal, For, Match, onCleanup, Show, Switch } from "solid-js";
import { choose, openSpace, overlay, setOverlay, workspace } from "~/lib/app";
import * as jj from "~/lib/jj";
import { uniqueName, spacePath } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import { File, Folder, X } from "./icons";

export function relative(time: number): string {
  const minutes = Math.round((Date.now() - time) / 60_000);
  const format = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  if (minutes < 60) return format.format(-minutes, "minute");
  if (minutes < 1440) return format.format(-Math.round(minutes / 60), "hour");
  return format.format(-Math.round(minutes / 1440), "day");
}

export default function RecentlyDeleted() {
  const initial = () => {
    const o = overlay();
    return o?.type === "deleted" ? o.scope : null;
  };
  const [scope, setScope] = createSignal<string | null>(initial());
  const [query, setQuery] = createSignal("");
  const [selected, setSelected] = createSignal<jj.DeletedItem | null>(null);
  const [reveal, setReveal] = createSignal(localStorage.getItem("typewright.revealAfterRestore") !== "false");
  const [items, { refetch }] = createResource(scope, async (s) => jj.deleted(s ?? ""), { initialValue: [] });
  // Restores and deletions elsewhere change the list.
  onCleanup(jj.onCommit(() => void refetch()));
  const visible = createMemo(() => {
    const q = query().trim().toLowerCase();
    return q ? items().filter((i) => i.path.toLowerCase().includes(q)) : items();
  });
  const [preview] = createResource(selected, async (item) => {
    if (item.kind !== "file" || !item.lastCommit) return null;
    return jj.contentAt(item.path, item.lastCommit);
  });
  const close = () => setOverlay(null);
  const name = (item: jj.DeletedItem) => item.path.split("/").pop()!;

  async function restore(item: jj.DeletedItem, keepBoth = false) {
    let dest = item.path;
    if (keepBoth) {
      const parts = item.path.split("/");
      const base = parts.pop()!;
      const dot = item.kind === "file" ? base.lastIndexOf(".") : -1;
      const free = await uniqueName(spacePath(parts.join("/")), dot > 0 ? base.slice(0, dot) : base, dot > 0 ? base.slice(dot + 1) : null);
      dest = [...parts, free].join("/");
    }
    const result = await jj.restoreDeleted(item, dest);
    if (result === "exists") {
      const answer = await choose(`“${name(item)}” already exists`, "Something else is at its place now. Keep both, with a number added to the restored one?", [
        { label: "Cancel", value: "cancel", role: "cancel" },
        { label: "Keep Both", value: "both", role: "default" },
      ]);
      if (answer === "both") await restore(item, true);
      return;
    }
    if (result === "failed") return;
    await refetch();
    setSelected(null);
    const space = dest.split("/")[0];
    if (reveal()) {
      close();
      if (workspace()?.folder !== space) openSpace(space);
      const ws = workspace();
      const inside = dest.slice(space.length + 1);
      if (ws && inside && item.kind === "file") {
        await ws.loaded;
        await ws.reloadTree();
        await ws.select(inside);
      }
    } else {
      await workspace()?.reloadTree();
    }
  }

  return (
    <div class="overlay-backdrop" onMouseDown={(e) => e.target === e.currentTarget && close()} onKeyDown={(e) => e.key === "Escape" && close()}>
      <div class="settings deleted glass" role="dialog" aria-label="Recently Deleted" tabIndex={-1} ref={(el) => requestAnimationFrame(() => el.focus())}>
        <header class="deleted-toolbar">
          <h2>Recently Deleted</h2>
          <Show when={initial()}>
            <div class="segmented">
              <button classList={{ active: scope() === null }} onClick={() => setScope(null)}>
                All Spaces
              </button>
              <button classList={{ active: scope() !== null }} onClick={() => setScope(initial())}>
                {initial()}
              </button>
            </div>
          </Show>
          <input class="text-field search" type="search" placeholder="Search" value={query()} onInput={(e) => setQuery(e.currentTarget.value)} />
          <button class="icon-button" title="Close" onClick={close}>
            <X size={15} />
          </button>
        </header>
        <div class="deleted-body">
          <Show
            when={jj.isOpen()}
            fallback={<p class="empty-state secondary">Another tab runs this browser's history. Open Recently Deleted there.</p>}
          >
            <Show when={visible().length} fallback={<p class="empty-state secondary">{query() ? `Nothing deleted matches “${query()}”.` : "Files you delete show up here, so you can bring them back."}</p>}>
              <div class="deleted-list" role="listbox">
                <For each={visible()}>
                  {(item) => (
                    <div
                      class="deleted-row"
                      role="option"
                      aria-selected={selected() === item}
                      classList={{ selected: selected() === item }}
                      onClick={() => setSelected(item)}
                      onDblClick={() => void restore(item)}
                    >
                      {item.kind === "folder" ? <Folder size={15} /> : <File size={15} />}
                      <span class="ellipsis">{name(item)}</span>
                      <span class="secondary ellipsis">{item.path.split("/").slice(0, -1).join(" › ")}</span>
                      <span class="secondary" title={new Date(item.time).toLocaleString()}>
                        {relative(item.time)}
                      </span>
                    </div>
                  )}
                </For>
              </div>
              <div class="deleted-preview">
                <Switch fallback={<p class="secondary">Select an item to preview it.</p>}>
                  <Match when={selected()?.kind === "folder"}>
                    <p class="secondary">{selected()!.files === 1 ? "1 file" : `${selected()!.files} files`}</p>
                  </Match>
                  <Match when={preview() && "text" in preview()!}>
                    <pre>{(preview() as { text: string }).text.slice(0, 20_000)}</pre>
                  </Match>
                  <Match when={selected()}>
                    <p class="secondary">No preview</p>
                  </Match>
                </Switch>
              </div>
            </Show>
          </Show>
        </div>
        <footer class="deleted-footer">
          <label class="checkbox">
            <input
              type="checkbox"
              checked={reveal()}
              onChange={(e) => {
                setReveal(e.currentTarget.checked);
                localStorage.setItem("typewright.revealAfterRestore", String(e.currentTarget.checked));
              }}
            />
            Open After Restoring
          </label>
          <div class="spacer" />
          <button class="button primary" disabled={!selected()} onClick={() => selected() && void restore(selected()!)}>
            Restore
          </button>
        </footer>
      </div>
    </div>
  );
}

/** Repo-relative folder of `path` in the shown space, for "Show Recently Deleted in This Folder". */
export function folderScope(space: string, path: string): string {
  return path ? fs.join(space, path) : space;
}
