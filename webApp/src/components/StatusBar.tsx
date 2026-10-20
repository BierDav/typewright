import { createMemo, createSignal, For, Show } from "solid-js";
import { Portal } from "solid-js/web";
import { participants } from "~/lib/editor/live";
import { isEditable } from "~/lib/kinds";
import { basename } from "~/lib/storage";
import type { Workspace } from "~/lib/workspace";
import { CircleAlert, CircleCheck, Eye, TriangleAlert, Users } from "./icons";

function words(text: string): number {
  return text.match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu)?.length ?? 0;
}

export default function StatusBar(props: { workspace: Workspace }) {
  const ws = props.workspace;
  const [issuesOpen, setIssuesOpen] = createSignal(false);
  const errors = () => ws.state.diagnostics.filter((d) => d.severity === "error").length;
  const warnings = () => ws.state.diagnostics.length - errors();
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
      <button class="status-item" classList={{ error: errors() > 0 }} onClick={() => setIssuesOpen(!issuesOpen())} title="Errors and warnings">
        <Show when={ws.state.diagnostics.length > 0} fallback={<CircleCheck size={13} />}>
          <Show when={errors() > 0}>
            <CircleAlert size={13} /> {errors()}
          </Show>
          <Show when={warnings() > 0}>
            <TriangleAlert size={13} class="warning" /> {warnings()}
          </Show>
        </Show>
      </button>
      <Show when={participants().length > 0}>
        <span class="status-item" title="Also editing this file">
          <Users size={13} /> {participants().join(", ")}
        </span>
      </Show>
      <Show when={ws.state.preview}>
        <span class="status-item" title="Previewed file">
          <Eye size={13} /> {basename(ws.state.preview!)}
        </span>
      </Show>
      <Show when={ws.state.duration !== null}>
        <span class="status-item secondary">{ws.state.compiling ? "Compiling…" : `${Math.round(ws.state.duration!)} ms`}</span>
      </Show>
      <div class="spacer" />
      <Show when={isEditable(ws.state.selectedKind)}>
        <span class="status-item secondary">{caret().characters > 0 ? `${caret().words} of ${total()} words` : `${total()} words`}</span>
        <span class="status-item secondary">
          Ln {caret().line}, Col {caret().column}
          <Show when={caret().characters > 0}>
            {caret().lines > 1 ? ` (${caret().lines} lines, ${caret().characters} selected)` : ` (${caret().characters} selected)`}
          </Show>
        </span>
      </Show>
      <Show when={issuesOpen()}>
        <Portal>
          <div class="menu-backdrop" onMouseDown={() => setIssuesOpen(false)} />
          <div class="issues glass">
            <Show when={ws.state.diagnostics.length > 0 || ws.state.packageErrors.length > 0} fallback={<p class="secondary issues-empty"><CircleCheck size={14} /> No issues</p>}>
              <For each={ws.state.packageErrors}>{(message) => <div class="issue"><CircleAlert size={14} class="error" /><div><div>{message}</div></div></div>}</For>
              <For each={ws.state.diagnostics}>
                {(d) => (
                  <button
                    class="issue"
                    disabled={d.fromPackage || !d.path}
                    onClick={() => {
                      setIssuesOpen(false);
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
    </footer>
  );
}
