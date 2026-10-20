import { createEffect, createMemo, createResource, createSignal, For, type JSX, on, onMount, Show } from "solid-js";
import { confirm, editorView, openSpace, setOverlay, shortcut, workspace } from "~/lib/app";
import * as commands from "~/lib/commands";
import { FuzzyMatch } from "~/lib/core";
import { symbolAt } from "~/lib/editor/refactor";
import * as fonts from "~/lib/fonts";
import { isEditable, isMarkdown, isPreviewable } from "~/lib/kinds";
import { type RenderMode, setSettings, settings } from "~/lib/settings";
import { download, spaces, zipSpace } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import * as syncService from "~/lib/sync";
import type { Workspace } from "~/lib/workspace";
import { ChevronRight, Command, CornerDownLeft, File, Folder, Layers, Search, Type } from "./icons";
import { importFolder, importZip, newSpace } from "./SpacesSidebar";
import { renameCurrentSpace } from "./FileSidebar";

type Action = { run: () => void } | { stay: () => void } | { page: Page };

type Item = {
  id: string;
  title: string;
  subtitle?: string;
  section: string;
  shortcut?: string;
  keywords?: string[];
  /** Only shown while searching, like file names. */
  searchOnly?: boolean;
  icon?: "file" | "folder" | "space" | "font" | "search";
  action: Action;
};

type Page =
  | { title: string; placeholder: string; kind: "list"; items: () => Item[] | Promise<Item[]> }
  | { title: string; placeholder: string; kind: "input"; initial: string; submit: (value: string) => void };

function score(query: string, item: Item): number | null {
  const q = query.toLowerCase();
  const texts = [item.title, ...(item.keywords ?? []), item.subtitle ?? ""].map((t) => t.toLowerCase());
  let best: number | null = null;
  for (const [i, text] of texts.entries()) {
    const s = FuzzyMatch.score(q, text);
    // Keywords and subtitles count a bit less than the title.
    if (s !== null && s !== undefined) best = Math.min(best ?? Infinity, s + (i === 0 ? 0 : 1));
  }
  return best;
}

function folderItems(ws: Workspace, make: (dir: string) => Action): Item[] {
  return [{ path: "", name: ws.name }, ...ws.folders().map((f) => ({ path: f.path, name: f.name }))].map((dir) => ({
    id: `dir:${dir.path}`,
    title: dir.path ? dir.name : ws.name,
    subtitle: dir.path && dir.path !== dir.name ? dir.path : undefined,
    section: "Folders",
    icon: "folder" as const,
    action: make(dir.path),
  }));
}

function namePage(ws: Workspace, kind: "File" | "Folder", dir: string): Page {
  return {
    title: `New ${kind} in ${dir ? fs.basename(dir) : ws.name}`,
    placeholder: kind === "File" ? "Name, e.g. chapter.typ" : "Folder name",
    kind: "input",
    initial: "",
    submit: (name) => void (kind === "File" ? ws.createFile(dir, name) : ws.createFolder(dir, name)),
  };
}

function usagesPage(ws: Workspace, path: string): Page {
  return {
    title: `Usages of ${fs.basename(path)}`,
    placeholder: "Filter usages…",
    kind: "list",
    items: async () => {
      const usages = await ws.fileUsages(path);
      if (!usages.length) return [{ id: "none", title: `No usages in ${ws.name}`, section: "Usages", action: { stay: () => {} } }];
      return usages.map((u) => ({
        id: `usage:${u.path}:${u.from}`,
        title: `${u.path}:${u.line}`,
        subtitle: u.preview,
        section: "Usages",
        icon: "file" as const,
        action: { run: () => void ws.open(u.path, u.from) },
      }));
    },
  };
}

function movePage(ws: Workspace, path: string): Page {
  return {
    title: `Move ${fs.basename(path)}`,
    placeholder: "Choose a folder…",
    kind: "list",
    items: () => folderItems(ws, (dir) => ({ run: () => void ws.move(path, dir) })).filter((i) => ws.canMove(path, i.id.slice(4))),
  };
}

const googleFontsPage: Page = {
  title: "Install Google Font",
  placeholder: "Search Google Fonts…",
  kind: "list",
  items: async () => {
    await fonts.loadCatalog();
    if (!fonts.fonts.catalog.length) return [{ id: "error", title: fonts.fonts.error ?? "Couldn't load Google Fonts", section: "Google Fonts", action: { stay: () => {} } }];
    return fonts.fonts.catalog.map((font) => {
      const installed = fonts.fonts.installed.includes(font.family);
      return {
        id: `google:${font.family}`,
        title: font.family,
        subtitle: installed ? "Installed" : font.category,
        section: "Google Fonts",
        icon: "font" as const,
        action: {
          stay: () => {
            if (installed) return;
            void fonts.download(font.family).then(() => workspace()?.updateFonts());
          },
        },
      };
    });
  },
};

const removeFontsPage: Page = {
  title: "Remove Google Font",
  placeholder: "Choose a font…",
  kind: "list",
  items: () =>
    fonts.fonts.installed.map((family) => ({
      id: `installed:${family}`,
      title: family,
      section: "Installed",
      icon: "font" as const,
      action: { stay: () => void fonts.remove(family).then(() => workspace()?.updateFonts()) },
    })),
};

async function refactorItems(ws: Workspace): Promise<Item[]> {
  const view = editorView();
  if (!view || ws.state.selectedKind !== "typst") return [];
  const items: Item[] = [
    { id: "code.docs", title: "Show Documentation", section: "Code", shortcut: "F1", keywords: ["quick documentation", "help", "hover"], action: { run: commands.quickDocs } },
    { id: "code.definition", title: "Go to Definition", section: "Code", shortcut: "F12", keywords: ["jump", "declaration"], action: { run: commands.definition } },
  ];
  const symbol = await symbolAt(view).catch(() => null);
  if (symbol && symbol.kind !== "import") {
    items.push({
      id: "refactor.rename",
      title: `Rename ${symbol.kind === "function" ? "Function" : "Variable"} ${symbol.name}…`,
      section: "Refactor",
      shortcut: "⇧F6",
      keywords: ["rename symbol", "refactor"],
      action: { run: commands.rename },
    });
  }
  items.push(
    { id: "refactor.variable", title: "Extract Variable…", section: "Refactor", shortcut: shortcut("⌥⌘V"), keywords: ["introduce variable"], action: { run: () => void commands.extractVariable() } },
    { id: "refactor.variable.all", title: "Extract Variable, Replacing All Occurrences…", section: "Refactor", keywords: ["introduce variable"], action: { run: () => void commands.extractVariable(true) } },
    { id: "refactor.function", title: "Extract Function…", section: "Refactor", shortcut: shortcut("⌥⌘M"), keywords: ["extract method"], action: { run: () => void commands.extractFunction() } },
    { id: "refactor.function.scope", title: "Extract Function to Scope…", section: "Refactor", shortcut: shortcut("⌥⇧⌘M"), keywords: ["extract method"], action: { run: () => void commands.extractFunction(true) } },
  );
  if (symbol?.kind === "variable") {
    items.push({ id: "refactor.inline", title: `Inline Variable ${symbol.name}`, section: "Refactor", shortcut: shortcut("⌥⌘N"), action: { run: commands.inlineVariable } });
  }
  return items;
}

async function rootItems(): Promise<Item[]> {
  const ws = workspace();
  const items: Item[] = [];
  if (ws) {
    const file = ws.state.selected;
    const here = file ? fs.dirname(file) : "";
    for (const kind of ["File", "Folder"] as const) {
      items.push({ id: `new.${kind}.here`, title: `New ${kind} in ${here ? fs.basename(here) : ws.name}`, section: "Create", action: { page: namePage(ws, kind, here) } });
      if (here) items.push({ id: `new.${kind}.root`, title: `New ${kind} in ${ws.name}`, section: "Create", action: { page: namePage(ws, kind, "") } });
      items.push({
        id: `new.${kind}.in`,
        title: `New ${kind} in…`,
        section: "Create",
        action: { page: { title: `New ${kind}`, placeholder: "Choose a folder…", kind: "list", items: () => folderItems(ws, (dir) => ({ page: namePage(ws, kind, dir) })) } },
      });
    }
    if (file) {
      const name = fs.basename(file);
      if (isEditable(ws.state.selectedKind)) {
        items.push({ id: "find", title: `Find in ${name}`, section: "File", shortcut: shortcut("⌘F"), action: { run: () => commands.find() } });
        items.push({ id: "replace", title: `Find and Replace in ${name}`, section: "File", shortcut: shortcut("⌥⌘F"), action: { run: () => commands.find(true) } });
      }
      if (isPreviewable(file)) {
        const previewed = ws.state.preview === file;
        items.push({ id: "preview", title: previewed ? "Hide Preview" : `Preview ${name}`, section: "File", action: { run: () => ws.togglePreview(file) } });
      }
      items.push(...(await refactorItems(ws)));
      if (ws.state.selectedKind === "typst") {
        items.push({ id: "file.usages", title: `Find Usages of ${name}`, section: "File", keywords: ["references", "imports", "includes"], action: { page: usagesPage(ws, file) } });
      }
      items.push(
        {
          id: "file.rename",
          title: `Rename ${name}…`,
          section: "File",
          action: { page: { title: `Rename ${name}`, placeholder: "New name", kind: "input", initial: name, submit: (n) => void ws.rename(file, n) } },
        },
        { id: "file.move", title: `Move ${name} to…`, section: "File", shortcut: shortcut("⌥⌘I"), action: { page: movePage(ws, file) } },
        {
          id: "file.delete",
          title: `Delete ${name}`,
          section: "File",
          keywords: ["trash", "remove"],
          action: { run: async () => (await confirm(`Delete “${name}”?`, "It moves to the trash in Settings › General.", "Delete", true)) && void ws.delete(file) },
        },
        {
          id: "file.download",
          title: `Download ${name}`,
          section: "File",
          action: { run: async () => { const bytes = await fs.readFile(fs.join(ws.root, file)); if (bytes) download(name, bytes); } },
        },
        { id: "file.rel", title: `Copy Relative Path of ${name}`, section: "File", action: { run: () => void navigator.clipboard.writeText(file) } },
      );
    }
    items.push({ id: "space.search", title: `Find in ${ws.name}`, section: "Space", shortcut: shortcut("⇧⌘F"), action: { run: () => setOverlay({ type: "search", allSpaces: false }) } });
    if (ws.state.preview && !isMarkdown(ws.state.preview)) {
      for (const mode of ["pdf", "html", "svg"] as RenderMode[]) {
        if (mode === settings.renderMode) continue;
        items.push({
          id: `render.${mode}`,
          title: `Render Preview as ${mode.toUpperCase()}`,
          section: "Space",
          action: { run: () => { setSettings("renderMode", mode); ws.setRenderMode(); } },
        });
      }
      items.push({ id: "export.pdf", title: "Export PDF", section: "Space", keywords: ["download", "save"], action: { run: () => void commands.exportPDF() } });
    }
    if (syncService.isRunning()) {
      items.push({
        id: "space.invite",
        title: `Copy Invite Link to ${ws.name}…`,
        section: "Space",
        keywords: ["share", "collaborate", "invite", "link"],
        action: { run: () => void commands.copyInviteLink(ws.folder) },
      });
      if (!syncService.isSynced(ws.folder)) {
        items.push({ id: "space.sync", title: `Sync ${ws.name} to My Devices`, section: "Space", action: { run: () => syncService.share(ws.folder) } });
      }
    }
    items.push(
      { id: "space.rename", title: `Rename ${ws.name}…`, section: "Space", action: { run: () => void renameCurrentSpace(ws) } },
      { id: "space.zip", title: `Download ${ws.name} as Zip`, section: "Space", action: { run: async () => download(`${ws.folder}.zip`, await zipSpace(ws.folder), "application/zip") } },
      { id: "space.sidebar", title: settings.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", section: "Space", shortcut: shortcut("⌘S"), action: { run: () => setSettings("sidebarVisible", (v) => !v) } },
      { id: "space.preview", title: settings.split > 0 ? "Hide Preview Pane" : "Show Preview Pane", section: "Space", action: { run: () => setSettings("split", (v) => (v > 0 ? 0 : 0.5)) } },
      { id: "space.close", title: `Close ${ws.name}`, section: "Space", shortcut: shortcut("⌃⌘W"), action: { run: () => openSpace(null) } },
    );
    // Typing searches every file name in the space.
    for (const node of ws.files()) {
      const dir = fs.dirname(node.path);
      items.push({ id: `file:${node.path}`, title: node.name, subtitle: dir || undefined, section: "Files", searchOnly: true, icon: "file", action: { run: () => void ws.select(node.path) } });
    }
  }
  for (const folder of spaces.names.filter((n) => n !== ws?.folder)) {
    items.push({ id: `space:${folder}`, title: `Open ${folder}`, section: "Spaces", icon: "space", action: { run: () => openSpace(folder) } });
  }
  items.push(
    { id: "spaces.toggle", title: settings.spacesVisible ? "Hide Spaces" : "Show Spaces", section: "Spaces", shortcut: shortcut("⌥⌘S"), action: { run: () => setSettings("spacesVisible", (v) => !v) } },
    { id: "spaces.new", title: "New Space…", section: "Spaces", action: { run: () => void newSpace() } },
    { id: "spaces.folder", title: "Import Folder as Space…", section: "Spaces", keywords: ["open", "upload"], action: { run: () => void importFolder() } },
    { id: "spaces.zip", title: "Import Zip as Space…", section: "Spaces", keywords: ["open", "upload"], action: { run: () => void importZip() } },
    {
      id: "spaces.join",
      title: "Join Shared Space…",
      section: "Spaces",
      keywords: ["invite", "link", "collaborate"],
      action: { run: async () => { const folder = await commands.joinFromLink(); if (folder) openSpace(folder); } },
    },
    { id: "spaces.search", title: "Search All Spaces", section: "Spaces", icon: "search", action: { run: () => setOverlay({ type: "search", allSpaces: true }) } },
    { id: "fonts.install", title: "Install Google Font…", section: "Fonts", keywords: ["download", "typeface"], action: { page: googleFontsPage } },
  );
  if (fonts.fonts.installed.length) items.push({ id: "fonts.remove", title: "Remove Google Font…", section: "Fonts", keywords: ["delete", "uninstall"], action: { page: removeFontsPage } });
  items.push(
    { id: "fonts.settings", title: "Font Settings…", section: "Fonts", action: { run: () => setOverlay({ type: "settings", tab: "fonts" }) } },
    { id: "app.settings", title: "Settings…", section: "App", shortcut: shortcut("⌘,"), action: { run: () => setOverlay({ type: "settings" }) } },
    { id: "app.devices", title: "Devices and Syncing…", section: "App", keywords: ["account", "passkey", "sign in"], action: { run: () => setOverlay({ type: "settings", tab: "devices" }) } },
  );
  return items;
}

/** Opens a page by name, for menus that land inside the palette. */
function startPage(name: string | undefined): Page | null {
  const ws = workspace();
  if (!name || !ws) return null;
  if (name.startsWith("move:")) return movePage(ws, name.slice(5));
  if (name.startsWith("usages:")) return usagesPage(ws, name.slice(7));
  if (name === "fonts.install") return googleFontsPage;
  return null;
}

export default function CommandPalette(props: { page?: string }) {
  let input!: HTMLInputElement;
  let list!: HTMLDivElement;
  const [stack, setStack] = createSignal<Page[]>([startPage(props.page)].filter((p): p is Page => !!p));
  const [query, setQuery] = createSignal("");
  const [selected, setSelected] = createSignal(0);
  const page = () => stack().at(-1);
  const [source] = createResource(
    () => ({ page: page(), revision: fonts.fonts.revision + fonts.fonts.catalog.length }),
    async ({ page }) => (page ? (page.kind === "list" ? page.items() : []) : rootItems()),
  );
  const close = () => setOverlay(null);

  const results = createMemo(() => {
    const items = source() ?? source.latest ?? [];
    const q = query().trim();
    if (!q) return items.filter((i) => !i.searchOnly).slice(0, 400);
    return items
      .map((item) => ({ item, s: score(q, item) }))
      .filter((r): r is { item: Item; s: number } => r.s !== null)
      .sort((a, b) => a.s - b.s)
      .slice(0, 200)
      .map((r) => r.item);
  });

  createEffect(on(results, () => setSelected(0)));
  onMount(() => input.focus());

  function push(next: Page) {
    setStack([...stack(), next]);
    setQuery(next.kind === "input" ? next.initial : "");
    requestAnimationFrame(() => input?.select());
  }

  function run(item?: Item) {
    const current = page();
    if (current?.kind === "input") {
      close();
      return current.submit(query());
    }
    if (!item) return;
    if ("page" in item.action) return push(item.action.page);
    if ("stay" in item.action) return item.action.stay();
    close();
    item.action.run();
  }

  function move(delta: number) {
    const count = results().length;
    if (!count) return;
    setSelected((s) => (s + delta + count) % count);
    list?.querySelector(`[data-index="${selected()}"]`)?.scrollIntoView({ block: "nearest" });
  }

  function onKey(event: KeyboardEvent) {
    if (event.key === "ArrowDown" || (event.ctrlKey && event.key === "n")) (event.preventDefault(), move(1));
    else if (event.key === "ArrowUp" || (event.ctrlKey && event.key === "p")) (event.preventDefault(), move(-1));
    else if (event.key === "Enter") (event.preventDefault(), run(results()[selected()]));
    else if (event.key === "Escape") {
      event.preventDefault();
      if (stack().length) {
        setStack(stack().slice(0, -1));
        setQuery("");
      } else close();
    } else if (event.key === "Backspace" && !query() && stack().length) {
      setStack(stack().slice(0, -1));
    }
  }

  const icon = (item: Item): JSX.Element => {
    switch (item.icon) {
      case "file":
        return <File size={15} />;
      case "folder":
        return <Folder size={15} />;
      case "space":
        return <Layers size={15} />;
      case "font":
        return <Type size={15} />;
      case "search":
        return <Search size={15} />;
      default:
        return <Command size={15} />;
    }
  };

  return (
    <div class="overlay-backdrop" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div class="palette glass" role="dialog" aria-label="Command palette">
        <div class="palette-field">
          <Show when={page()}>
            <span class="palette-page">{page()!.title}</span>
          </Show>
          <input
            ref={input}
            value={query()}
            placeholder={page()?.placeholder ?? "Search commands, files and spaces…"}
            onInput={(e) => setQuery(e.currentTarget.value)}
            onKeyDown={onKey}
            spellcheck={false}
          />
        </div>
        <Show when={page()?.kind !== "input"}>
          <div class="palette-list" ref={list}>
            <Show when={!source.loading || results().length} fallback={<p class="secondary palette-empty">Loading…</p>}>
              <For each={results()} fallback={<p class="secondary palette-empty">No results</p>}>
                {(item, index) => (
                  <>
                    <Show when={!query() && (index() === 0 || results()[index() - 1].section !== item.section)}>
                      <div class="palette-section">{item.section}</div>
                    </Show>
                    <button
                      class="palette-row"
                      classList={{ selected: selected() === index() }}
                      data-index={index()}
                      onMouseMove={() => setSelected(index())}
                      onClick={() => run(item)}
                    >
                      <span class="palette-icon">{icon(item)}</span>
                      <span class="palette-title">{item.title}</span>
                      <Show when={item.subtitle}>
                        <span class="palette-subtitle">{item.subtitle}</span>
                      </Show>
                      <span class="spacer" />
                      <Show when={item.shortcut}>
                        <span class="palette-shortcut">{item.shortcut}</span>
                      </Show>
                      <Show when={"page" in item.action}>
                        <ChevronRight size={13} class="secondary" />
                      </Show>
                    </button>
                  </>
                )}
              </For>
            </Show>
          </div>
        </Show>
        <div class="palette-hints secondary">
          <span>↑↓ Select</span>
          <span>
            <CornerDownLeft size={11} /> {page()?.kind === "input" ? "Create" : "Run"}
          </span>
          <span>esc {stack().length ? "Back" : "Close"}</span>
        </div>
      </div>
    </div>
  );
}
