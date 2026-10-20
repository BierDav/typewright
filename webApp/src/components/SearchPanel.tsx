import { createEffect, createSignal, For, on, onMount, Show } from "solid-js";
import { confirm, openSpace, setOverlay, toast, workspace } from "~/lib/app";
import { kindOf } from "~/lib/kinds";
import { spacePath, spaces } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import { File, Replace, Search } from "./icons";

type Match = { from: number; to: number; line: number; before: string; text: string; after: string };
type FileResult = { space: string; path: string; matches: Match[] };

const MAX_MATCHES = 2000;

function pattern(query: string, options: { regex: boolean; caseSensitive: boolean; word: boolean }): RegExp | null {
  if (!query) return null;
  let source = options.regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if (options.word) source = `\\b${source}\\b`;
  try {
    return new RegExp(source, options.caseSensitive ? "gu" : "giu");
  } catch {
    return null;
  }
}

function matchesIn(text: string, re: RegExp): Match[] {
  const out: Match[] = [];
  re.lastIndex = 0;
  for (let m = re.exec(text); m && out.length < 500; m = re.exec(text)) {
    if (m[0].length === 0) {
      re.lastIndex++;
      continue;
    }
    const lineStart = text.lastIndexOf("\n", m.index) + 1;
    const lineEndRaw = text.indexOf("\n", m.index);
    const lineEnd = lineEndRaw < 0 ? text.length : lineEndRaw;
    out.push({
      from: m.index,
      to: m.index + m[0].length,
      line: text.slice(0, m.index).split("\n").length,
      before: text.slice(Math.max(lineStart, m.index - 60), m.index).trimStart(),
      text: m[0],
      after: text.slice(m.index + m[0].length, Math.min(lineEnd, m.index + m[0].length + 80)),
    });
  }
  return out;
}

/** Text files of a space with unsaved edits where the space is open. */
async function* texts(space: string): AsyncGenerator<{ path: string; text: string }> {
  const ws = workspace();
  const buffers = ws?.folder === space ? ws.unsavedBuffers() : new Map<string, string>();
  for (const entry of await fs.walk(spacePath(space))) {
    if (entry.kind !== "file" || entry.path.split("/").some((p) => p.startsWith(".")) || entry.size > 4_000_000) continue;
    const kind = kindOf(entry.path);
    if (kind && kind !== "typst" && kind !== "text") continue;
    const buffered = buffers.get(entry.path);
    if (buffered !== undefined) {
      yield { path: entry.path, text: buffered };
      continue;
    }
    const bytes = await fs.readFile(spacePath(space, entry.path));
    const text = bytes && fs.decodeText(bytes);
    if (text !== null && text !== undefined) yield { path: entry.path, text };
  }
}

export default function SearchPanel(props: { allSpaces: boolean }) {
  let input!: HTMLInputElement;
  const [query, setQuery] = createSignal("");
  const [replacement, setReplacement] = createSignal("");
  const [showReplace, setShowReplace] = createSignal(false);
  const [options, setOptions] = createSignal({ regex: false, caseSensitive: false, word: false });
  const [all, setAll] = createSignal(props.allSpaces || !workspace());
  const [results, setResults] = createSignal<FileResult[]>([]);
  const [searching, setSearching] = createSignal(false);
  let run = 0;
  const close = () => setOverlay(null);

  onMount(() => input.focus());

  async function search() {
    const current = ++run;
    const re = pattern(query(), options());
    if (!re) return setResults([]);
    setSearching(true);
    const found: FileResult[] = [];
    let total = 0;
    const targets = all() ? spaces.names : [workspace()!.folder];
    for (const space of targets) {
      for await (const { path, text } of texts(space)) {
        if (current !== run) return;
        const matches = matchesIn(text, re);
        if (matches.length) {
          found.push({ space, path, matches });
          total += matches.length;
          setResults([...found]);
        }
        if (total > MAX_MATCHES) break;
      }
    }
    if (current === run) {
      setResults(found);
      setSearching(false);
    }
  }

  let timer: ReturnType<typeof setTimeout> | undefined;
  createEffect(
    on([query, options, all], () => {
      clearTimeout(timer);
      timer = setTimeout(() => void search(), 200);
    }),
  );

  async function reveal(result: FileResult, match: Match) {
    if (workspace()?.folder !== result.space) openSpace(result.space);
    const ws = workspace();
    if (!ws) return;
    close();
    await ws.loaded;
    await ws.open(result.path, match.from, match.to);
  }

  async function replaceAll() {
    const ws = workspace();
    const re = pattern(query(), options());
    if (!ws || !re || all()) return;
    const count = results().reduce((n, r) => n + r.matches.length, 0);
    const ok = await confirm(`Replace ${count} matches in ${ws.name}?`, `Every match of “${query()}” becomes “${replacement()}”.`, "Replace All");
    if (!ok) return;
    for (const result of results()) {
      const text = await ws.bufferText(result.path);
      if (text === null) continue;
      re.lastIndex = 0;
      ws.updateBuffer(result.path, text.replace(re, options().regex ? replacement() : replacement().replace(/\$/g, "$$$$")));
    }
    await ws.flushSaves();
    toast(`Replaced ${count} matches`);
    void search();
  }

  const count = () => results().reduce((n, r) => n + r.matches.length, 0);

  return (
    <div class="overlay-backdrop" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div class="search-panel glass" role="dialog" aria-label="Search" onKeyDown={(e) => e.key === "Escape" && close()}>
        <div class="search-fields">
          <div class="search-field">
            <Search size={15} class="secondary" />
            <input ref={input} value={query()} placeholder={all() ? "Search all spaces" : `Search ${workspace()?.name ?? ""}`} onInput={(e) => setQuery(e.currentTarget.value)} spellcheck={false} />
            <button class="toggle" classList={{ on: options().caseSensitive }} title="Match case" onClick={() => setOptions((o) => ({ ...o, caseSensitive: !o.caseSensitive }))}>
              Aa
            </button>
            <button class="toggle" classList={{ on: options().word }} title="Whole words" onClick={() => setOptions((o) => ({ ...o, word: !o.word }))}>
              ab
            </button>
            <button class="toggle" classList={{ on: options().regex }} title="Regular expression" onClick={() => setOptions((o) => ({ ...o, regex: !o.regex }))}>
              .*
            </button>
            <Show when={!all()}>
              <button class="toggle" classList={{ on: showReplace() }} title="Replace" onClick={() => setShowReplace(!showReplace())}>
                <Replace size={13} />
              </button>
            </Show>
          </div>
          <Show when={showReplace() && !all()}>
            <div class="search-field">
              <Replace size={15} class="secondary" />
              <input value={replacement()} placeholder="Replace with" onInput={(e) => setReplacement(e.currentTarget.value)} spellcheck={false} />
              <button class="button small" disabled={!count()} onClick={() => void replaceAll()}>
                Replace All
              </button>
            </div>
          </Show>
          <div class="search-scope">
            <Show when={workspace()}>
              <div class="segmented small">
                <button classList={{ active: !all() }} onClick={() => setAll(false)}>
                  {workspace()!.name}
                </button>
                <button classList={{ active: all() }} onClick={() => setAll(true)}>
                  All Spaces
                </button>
              </div>
            </Show>
            <span class="secondary">{searching() ? "Searching…" : query() ? `${count()} ${count() === 1 ? "match" : "matches"} in ${results().length} ${results().length === 1 ? "file" : "files"}` : ""}</span>
          </div>
        </div>
        <div class="search-results">
          <For each={results()}>
            {(result) => (
              <div class="search-file">
                <div class="search-file-name">
                  <File size={13} />
                  <span>{result.path}</span>
                  <Show when={all()}>
                    <span class="secondary">{result.space}</span>
                  </Show>
                </div>
                <For each={result.matches.slice(0, 50)}>
                  {(match) => (
                    <button class="search-match" onClick={() => void reveal(result, match)}>
                      <span class="line-number">{match.line}</span>
                      <span class="match-text">
                        {match.before}
                        <mark>{match.text}</mark>
                        {match.after}
                      </span>
                    </button>
                  )}
                </For>
                <Show when={result.matches.length > 50}>
                  <div class="secondary more">{result.matches.length - 50} more</div>
                </Show>
              </div>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}
