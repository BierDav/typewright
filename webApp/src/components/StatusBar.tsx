import { createMemo, createSignal, For, Show } from "solid-js";
import { Portal } from "solid-js/web";
import { participants } from "~/lib/editor/live";
import { compiler } from "~/lib/compiler";
import { isEditable, isMarkdown } from "~/lib/kinds";
import { basename } from "~/lib/storage";
import { PREVIEW_NEXT, type Workspace } from "~/lib/workspace";
import { isMac, toggleSidebar } from "~/lib/app";
import { setSettings, settings } from "~/lib/settings";
import { CircleAlert, CircleCheck, CircleX, Eye, PanelLeft, PanelRight, Pin, TriangleAlert, Users } from "./icons";

function words(text: string): number {
  return text.match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu)?.length ?? 0;
}

export default function StatusBar(props: { workspace: Workspace }) {
  const ws = props.workspace;
  const total = createMemo(() => words(ws.state.text));

  const caret = createMemo(() => {
    const text = ws.state.text;
    const { from, to } = ws.state.selection;
    const before = text.slice(0, to);
    const line = before.split("\n").length;
    const column = to - before.lastIndexOf("\n");
    const selected = text.slice(from, to);
    return { line, column, characters: to - from, lines: selected ? selected.split("\n").length : 0, words: words(selected) };
  });

  return (
    <footer class="status-bar">
      <Show when={!settings.sidebarVisible}>
        <button class="status-button" title={`Keep Sidebar Open (${isMac ? "⌘S" : "Ctrl+S"})`} onClick={() => toggleSidebar()}>
          <PanelLeft size={13} />
        </button>
      </Show>
      <Show when={isEditable(ws.state.selectedKind)}>
        <span class="status-item">
          Ln {caret().line}, Col {caret().column}
          <Show when={caret().characters > 0}>
            {caret().lines > 1 ? ` (${caret().lines} lines, ${caret().characters} selected)` : ` (${caret().characters} selected)`}
          </Show>
        </span>
        <span class="status-item">{caret().characters > 0 ? `${caret().words} of ${total()} words` : `${total()} words`}</span>
      </Show>
      <Show when={participants().length > 0}>
        <span class="status-item" title="Also editing this file">
          <Users size={12} /> {participants().join(", ")}
        </span>
      </Show>
      <div class="spacer" />
      <Show when={ws.state.preview}>
        <button class="status-item status-button" title={`${ws.state.previewMode === "pinned" ? "Pinned" : "Following the selection"} · ${PREVIEW_NEXT[ws.state.previewMode]}`} onClick={() => ws.cyclePreview()}>
          <Show when={ws.state.previewMode === "pinned"} fallback={<Eye size={12} />}>
            <Pin size={12} />
          </Show>{" "}
          {basename(ws.state.preview!)}
        </button>
        <Show when={ws.state.preview!.endsWith(".typ") && compiler.version}>
          <span class="status-item">Typst {compiler.version}</span>
        </Show>
        <Show when={ws.state.duration !== null}>
          <span class="status-item">{Math.round(ws.state.duration!)} ms</span>
        </Show>
        <Show when={settings.split === 0}>
          <button class="status-button" title="Show preview" onClick={() => setSettings("split", 0.5)}>
            <PanelRight size={13} />
          </button>
        </Show>
      </Show>
    </footer>
  );
}

/** The errors and warnings capsule at the editor's bottom right, like the Mac app's. */
export function Issues(props: { workspace: Workspace }) {
  const ws = props.workspace;
  const [open, setOpen] = createSignal(false);
  const errors = () => ws.state.diagnostics.filter((d) => d.severity === "error").length + ws.state.packageErrors.length;
  const count = () => ws.state.diagnostics.length + ws.state.packageErrors.length;

  return (
    <Show when={ws.state.preview && !isMarkdown(ws.state.preview)}>
      <button
        class="issues-button glass-capsule"
        classList={{ error: errors() > 0, warning: errors() === 0 && count() > 0, ok: count() === 0 }}
        onClick={() => setOpen(!open())}
        title="Errors and warnings"
      >
        <Show when={errors() > 0} fallback={<Show when={count() > 0} fallback={<CircleCheck size={13} />}><TriangleAlert size={13} /></Show>}>
          <CircleX size={13} />
        </Show>
        <Show when={count() > 0}>
          <span>{count()}</span>
        </Show>
      </button>
      <Show when={open()}>
        <Portal>
          <div class="menu-backdrop" onMouseDown={() => setOpen(false)} />
          <div class="issues glass">
            <Show when={count() > 0} fallback={<p class="secondary issues-empty"><CircleCheck size={14} /> No issues</p>}>
              <For each={ws.state.packageErrors}>{(message) => <div class="issue"><CircleAlert size={14} class="error" /><div><div>{message}</div></div></div>}</For>
              <For each={ws.state.diagnostics}>
                {(d) => (
                  <button
                    class="issue"
                    disabled={d.fromPackage || !d.path}
                    onClick={() => {
                      setOpen(false);
                      ws.revealDiagnostic(d);
                    }}
                    title="Go to the issue"
                  >
                    {d.severity === "error" ? <CircleAlert size={14} class="error" /> : <TriangleAlert size={14} class="warning" />}
                    <div>
                      <div>{d.message}</div>
                      <Show when={d.path}>
                        <div class="secondary mono">
                          {d.path}:{d.line}:{d.column}
                        </div>
                      </Show>
                    </div>
                  </button>
                )}
              </For>
            </Show>
          </div>
        </Portal>
      </Show>
    </Show>
  );
}
