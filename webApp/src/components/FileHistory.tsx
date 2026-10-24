// A file's local history (like the Mac app's history sheet): versions by day on the left, the selected one's diff
// against now or against the version before it on the right.
import { createEffect, createMemo, createSignal, For, Match, on, onCleanup, Show, Switch, untrack } from "solid-js";
import { confirm, copyText, overlay, setOverlay, workspace } from "~/lib/app";
import { lineDiff } from "~/lib/core";
import { diffRows, groupByDay, versionPaths, versionSubtitle } from "~/lib/history";
import * as jj from "~/lib/jj";
import { mimeType } from "~/lib/kinds";
import { download } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import type { DiffHunk } from "~/wasm/core/core.js";
import { relative } from "./RecentlyDeleted";
import { Copy, Download, X } from "./icons";

type Comparison = "current" | "previous";

const text = (content: jj.FileContent | null): string | null =>
  !content ? null : "text" in content ? content.text : "missing" in content ? "" : null;

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} bytes`;
  if (bytes < 1_048_576) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1_048_576).toFixed(1)} MB`;
}

export default function FileHistory() {
  const path = untrack(() => {
    const o = overlay();
    return o?.type === "history" ? o.path : "";
  });
  const name = path.split("/").pop() ?? path;
  const [versions, setVersions] = createSignal<jj.FileVersion[]>([]);
  const [loading, setLoading] = createSignal(true);
  const [selection, setSelection] = createSignal<string | null>(null);
  const selected = createMemo(() => Math.max(0, versions().findIndex((v) => v.commit === selection())));
  const setSelected = (index: number) => setSelection(versions()[index]?.commit ?? null);
  const [comparison, setComparison] = createSignal<Comparison>(
    (localStorage.getItem("typewright.historyComparison") as Comparison | null) ?? "current",
  );
  const [content, setContent] = createSignal<jj.FileContent | null>(null);
  const [hunks, setHunks] = createSignal<DiffHunk[] | null>(null);
  const [expanded, setExpanded] = createSignal<ReadonlySet<number>>(new Set());
  const paths = createMemo(() => versionPaths(versions(), path));
  const days = createMemo(() => groupByDay(versions()));
  const version = () => versions()[selected()] as jj.FileVersion | undefined;
  const rows = createMemo(() => (hunks() ? diffRows(hunks()!, expanded()) : null));
  const unchanged = () => rows()?.every((r) => r.type === "fold" || r.kind === "same") ?? false;
  const close = () => setOverlay(null);

  async function load() {
    const list = await jj.history(path);
    setVersions(list);
    setLoading(false);
    if (!list.some((v) => v.commit === selection())) setSelection(list[0]?.commit ?? null);
  }
  void load();
  // New autosaves show up while the window is open.
  onCleanup(jj.onCommit((changed) => changed.some((p) => p === path || path.startsWith(`${p}/`)) && void load()));

  /** The file's text now, with unsaved edits when its space is open. */
  async function currentText(): Promise<string | null> {
    const ws = workspace();
    if (ws && (path === ws.folder || path.startsWith(`${ws.folder}/`))) return ws.bufferText(ws.spacePath(path));
    return fs.readText(jj.storagePath(path));
  }

  createEffect(
    on([() => version()?.commit, comparison], ([, compare]) => {
      const current = version();
      setExpanded(new Set<number>());
      setContent(null);
      setHunks(null);
      if (!current) return;
      let live = true;
      onCleanup(() => (live = false));
      const index = selected();
      const all = versions();
      const older = index + 1 < all.length && current.kind !== "added" ? index + 1 : null;
      void (async () => {
        const at = await jj.contentAt(paths()[index], current.commit);
        let base: jj.FileContent;
        if (compare === "current") {
          const now = await currentText();
          base = now === null ? { missing: true } : { text: now };
        } else base = older === null ? { missing: true } : await jj.contentAt(paths()[older], all[older].commit);
        if (!live) return;
        const [mine, other] = [text(at), text(base)];
        // Compared to now the version is the old side; otherwise it's the new side of its own change.
        if (mine !== null && other !== null) setHunks(compare === "current" ? lineDiff(mine, other) : lineDiff(other, mine));
        setContent(at);
      })();
    }),
  );

  const imageUrl = createMemo<string | null>((previous) => {
    if (previous) URL.revokeObjectURL(previous);
    const c = content();
    if (!c || !("data" in c)) return null;
    return URL.createObjectURL(new Blob([c.data as Uint8Array<ArrayBuffer>], { type: mimeType(paths()[selected()] ?? path) }));
  }, null);
  onCleanup(() => imageUrl() && URL.revokeObjectURL(imageUrl()!));

  const hasContent = () => {
    const c = content();
    return !!c && !("missing" in c);
  };

  function copy() {
    const c = content();
    if (c && "text" in c) void copyText(c.text, "Version copied");
  }

  function save() {
    const c = content();
    const v = version();
    if (!c || "missing" in c || !v) return;
    const file = (paths()[selected()] ?? path).split("/").pop()!;
    const dot = file.lastIndexOf(".");
    const stamp = new Date(v.time).toISOString().slice(0, 16).replace("T", " ").replace(":", ".");
    const named = dot > 0 ? `${file.slice(0, dot)} (${stamp})${file.slice(dot)}` : `${file} (${stamp})`;
    download(named, "text" in c ? new TextEncoder().encode(c.text) : c.data, mimeType(file));
  }

  async function restore() {
    const v = version();
    const c = content();
    if (!v || !c || "missing" in c) return;
    const ok = await confirm(`Restore “${name}” to this version?`, "The current content stays in the history, so you can go back to it.", "Restore");
    if (!ok) return;
    // Unsaved edits would otherwise be written over the restored file.
    await workspace()?.flushSaves();
    let restored: boolean;
    if (paths()[selected()] === path) restored = await jj.restore(path, v.commit);
    else {
      // The version lived under an older name; its content goes to the file's current place.
      await fs.writeFile(jj.storagePath(path), "text" in c ? c.text : c.data);
      restored = (await jj.commit(`Restore ${path}`)).length > 0;
    }
    if (restored) close();
  }

  function onKey(event: KeyboardEvent) {
    if (event.target instanceof HTMLInputElement) return;
    const count = versions().length;
    if (event.key === "Escape") (event.preventDefault(), close());
    else if (count && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
      event.preventDefault();
      setSelected(Math.min(count - 1, Math.max(0, selected() + (event.key === "ArrowDown" ? 1 : -1))));
      document.querySelector(`.history-row[data-index="${selected()}"]`)?.scrollIntoView({ block: "nearest" });
    }
  }

  const time = (t: number) => new Date(t).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  // Refreshes so "5 minutes ago" keeps counting while the window is open.
  const [tick, setTick] = createSignal(0);
  const timer = setInterval(() => setTick((t) => t + 1), 30_000);
  onCleanup(() => clearInterval(timer));

  return (
    <div class="overlay-backdrop" onMouseDown={(e) => e.target === e.currentTarget && close()} onKeyDown={onKey}>
      <div class="settings history glass" role="dialog" aria-label={`History of ${name}`} tabIndex={-1} ref={(el) => requestAnimationFrame(() => el.focus())}>
        <header class="deleted-toolbar">
          <h2>
            History of <span class="history-name">{name}</span>
          </h2>
          <button class="icon-button" title="Close" onClick={close}>
            <X size={15} />
          </button>
        </header>
        <Show
          when={jj.isOpen()}
          fallback={<p class="empty-state secondary history-empty">Another tab runs this browser's history. Open the file's history there.</p>}
        >
          <div class="history-body">
            <div class="history-list" role="listbox">
              <Show
                when={versions().length}
                fallback={
                  <Show when={!loading()}>
                    <p class="empty-state secondary history-empty">
                      Versions appear here a few seconds after the file changes. Large and binary files have no history; they sync whole.
                    </p>
                  </Show>
                }
              >
                <For each={days()}>
                  {(day) => (
                    <>
                      <div class="history-day">{day.title}</div>
                      <For each={day.versions}>
                        {(v) => {
                          const index = () => versions().indexOf(v);
                          return (
                            <div
                              class="history-row"
                              role="option"
                              data-index={index()}
                              aria-selected={selected() === index()}
                              classList={{ selected: selected() === index() }}
                              onClick={() => setSelected(index())}
                            >
                              <div class="history-row-top">
                                <span>{time(v.time)}</span>
                                <span class="spacer" />
                                <Show when={v.added > 0}>
                                  <span class="diff-count added">+{v.added}</span>
                                </Show>
                                <Show when={v.removed > 0}>
                                  <span class="diff-count removed">−{v.removed}</span>
                                </Show>
                              </div>
                              <span class="secondary ellipsis history-subtitle">{versionSubtitle(v, paths()[index()] ?? path, path)}</span>
                            </div>
                          );
                        }}
                      </For>
                    </>
                  )}
                </For>
              </Show>
            </div>
            <div class="history-detail">
              <Show when={version()}>
                {(v) => (
                  <>
                    <div class="history-detail-header">
                      <div class="history-when">
                        <div>
                          <strong>{new Date(v().time).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}</strong>
                          <span class="secondary"> {(tick(), relative(v().time))}</span>
                        </div>
                        <span class="secondary ellipsis history-path">{paths()[selected()]}</span>
                      </div>
                      <div class="segmented">
                        <For each={["current", "previous"] as Comparison[]}>
                          {(c) => (
                            <button
                              classList={{ active: comparison() === c }}
                              onClick={() => {
                                setComparison(c);
                                localStorage.setItem("typewright.historyComparison", c);
                              }}
                            >
                              {c === "current" ? "Compared to Now" : "Changes in Version"}
                            </button>
                          )}
                        </For>
                      </div>
                    </div>
                    <div class="history-content">
                      <Switch>
                        <Match when={rows() && unchanged()}>
                          <p class="empty-state secondary">{comparison() === "current" ? "Same as now" : "No changes"}</p>
                        </Match>
                        <Match when={rows()}>
                          <div class="diff">
                            <For each={rows()!}>
                              {(row) =>
                                row.type === "fold" ? (
                                  <button class="diff-fold" title="Show the unchanged lines" onClick={() => setExpanded(new Set([...expanded(), row.hunk]))}>
                                    {row.count} unchanged lines
                                  </button>
                                ) : (
                                  <div class={`diff-line ${row.kind}`}>
                                    <span class="diff-num">{row.old ?? ""}</span>
                                    <span class="diff-num">{row.new ?? ""}</span>
                                    <span class="diff-mark">{row.kind === "added" ? "+" : row.kind === "removed" ? "−" : ""}</span>
                                    <span class="diff-text">{row.text || " "}</span>
                                  </div>
                                )
                              }
                            </For>
                          </div>
                        </Match>
                        <Match when={content() && "missing" in content()!}>
                          <p class="empty-state secondary">Not in this version</p>
                        </Match>
                        <Match when={imageUrl() && mimeType(paths()[selected()] ?? path) === "application/pdf"}>
                          <iframe class="history-pdf" src={imageUrl()!} title="Version preview" />
                        </Match>
                        <Match when={imageUrl() && mimeType(paths()[selected()] ?? path).startsWith("image/")}>
                          <img class="history-image" src={imageUrl()!} alt={name} />
                        </Match>
                        <Match when={content() && "data" in content()!}>
                          <p class="empty-state secondary">No preview · {formatSize((content() as { data: Uint8Array }).data.length)}</p>
                        </Match>
                      </Switch>
                    </div>
                  </>
                )}
              </Show>
            </div>
          </div>
        </Show>
        <footer class="deleted-footer">
          <button class="button" disabled={!(content() && "text" in content()!)} onClick={copy} title="Copy this version's content">
            <Copy size={13} /> Copy
          </button>
          <button class="button" disabled={!hasContent()} onClick={save} title="Download this version">
            <Download size={13} /> Download
          </button>
          <div class="spacer" />
          <button class="button" disabled={!hasContent()} onClick={() => void restore()}>
            Restore…
          </button>
          <button class="button primary" onClick={close}>
            Done
          </button>
        </footer>
      </div>
    </div>
  );
}
