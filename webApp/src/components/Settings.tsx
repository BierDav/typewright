import { createMemo, createResource, createSignal, For, type JSX, Match, onMount, Show, Switch } from "solid-js";
import { confirm, openSpace, overlay, prompt, setOverlay, type SettingsTab, workspace } from "~/lib/app";
import * as commands from "~/lib/commands";
import { compiler } from "~/lib/compiler";
import * as fontLib from "~/lib/fonts";
import { createPasskey, identity, passkeysSupported, relyingParty, sharesMacPasskeys, signInWithPasskey, signOut } from "~/lib/identity";
import { setSettings, settings } from "~/lib/settings";
import { spacePath } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import * as syncService from "~/lib/sync";
import { sync } from "~/lib/sync";
import { pickFiles } from "~/lib/drop";
import { Download, KeyRound, Link, MonitorSmartphone, Package, Pencil, Settings as Gear, Trash2, Type, Users, X } from "./icons";

const TABS: { id: SettingsTab; label: string; icon: () => JSX.Element }[] = [
  { id: "general", label: "General", icon: () => <Gear size={18} /> },
  { id: "editor", label: "Editor", icon: () => <Pencil size={18} /> },
  { id: "fonts", label: "Fonts", icon: () => <Type size={18} /> },
  { id: "packages", label: "Packages", icon: () => <Package size={18} /> },
  { id: "devices", label: "Devices", icon: () => <MonitorSmartphone size={18} /> },
];

function Section(props: { title?: string; footer?: string; children: JSX.Element }) {
  return (
    <section class="form-section">
      <Show when={props.title}>
        <h3>{props.title}</h3>
      </Show>
      <div class="form-group">{props.children}</div>
      <Show when={props.footer}>
        <p class="form-footer">{props.footer}</p>
      </Show>
    </section>
  );
}

function Row(props: { label: string; children: JSX.Element }) {
  return (
    <div class="form-row">
      <span class="form-label">{props.label}</span>
      <div class="form-control">{props.children}</div>
    </div>
  );
}

function Toggle(props: { checked: boolean; onChange: (value: boolean) => void; label?: string }) {
  return (
    <label class="switch" aria-label={props.label}>
      <input type="checkbox" checked={props.checked} onChange={(e) => props.onChange(e.currentTarget.checked)} />
      <span />
    </label>
  );
}

function Stepper(props: { value: number; min: number; max: number; step?: number; suffix?: string; onChange: (value: number) => void }) {
  const step = () => props.step ?? 1;
  return (
    <div class="stepper">
      <span class="stepper-value">
        {props.value}
        {props.suffix ?? ""}
      </span>
      <button onClick={() => props.onChange(Math.max(props.min, props.value - step()))} aria-label="Less">
        −
      </button>
      <button onClick={() => props.onChange(Math.min(props.max, props.value + step()))} aria-label="More">
        +
      </button>
    </div>
  );
}

function General() {
  const [trash, { refetch }] = createResource(async () => {
    const stamps = (await fs.list("trash")).filter((e) => e.kind === "dir").map((e) => fs.basename(e.path)).sort().reverse();
    const items: { stamp: string; space: string; path: string }[] = [];
    for (const stamp of stamps) {
      for (const space of await fs.list(fs.join("trash", stamp))) {
        for (const item of await fs.walk(space.path)) {
          if (item.kind === "file") items.push({ stamp, space: fs.basename(space.path), path: item.path });
        }
      }
    }
    return items;
  });
  const [persisted, { refetch: recheck }] = createResource(() => navigator.storage.persisted().catch(() => false));
  const [estimate] = createResource(() => navigator.storage.estimate().catch(() => null));

  async function restore(item: { stamp: string; space: string; path: string }) {
    const target = spacePath(item.space, item.path);
    const free = (await fs.exists(target)) ? target.replace(/(\.[^./]+)?$/, " (restored)$1") : target;
    await fs.move(fs.join("trash", item.stamp, item.space, item.path), free);
    void refetch();
  }

  async function empty() {
    if (!(await confirm("Empty the trash?", "The files in it are deleted for good.", "Empty Trash", true))) return;
    await fs.remove("trash", true);
    void refetch();
  }

  return (
    <>
      <Section title="Appearance">
        <Row label="Theme">
          <select value={settings.theme} onChange={(e) => setSettings("theme", e.currentTarget.value as typeof settings.theme)}>
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </Row>
      </Section>
      <Section title="Preview" footer="For Markdown files.">
        <Row label="Text size">
          <Stepper value={settings.previewTextSize} min={10} max={28} suffix=" px" onChange={(v) => setSettings("previewTextSize", v)} />
        </Row>
      </Section>
      <Section title="Diagnostics" footer="Hide warnings from imported packages (e.g. @preview/…). Errors are always shown.">
        <Row label="Ignore library warnings">
          <Toggle checked={settings.ignoreLibraryWarnings} onChange={(v) => setSettings("ignoreLibraryWarnings", v)} />
        </Row>
      </Section>
      <Section
        title="Storage"
        footer="Spaces live in this browser's storage for this site. Browsers may clear it under storage pressure unless it's kept; sync or download spaces you can't lose."
      >
        <Row label="Used">
          <span class="secondary">{estimate() ? `${((estimate()!.usage ?? 0) / 1_048_576).toFixed(1)} MB` : "–"}</span>
        </Row>
        <Row label="Keep storage">
          <Show when={!persisted()} fallback={<span class="secondary">Kept</span>}>
            <button class="button small" onClick={async () => { await fs.persist(); void recheck(); }}>
              Ask Browser
            </button>
          </Show>
        </Row>
      </Section>
      <Section
        title="History"
        footer="Every space keeps a version of each file a few seconds after it changes. Older versions are kept one per day. Larger files and binary files like PDFs and images have no history and are synced whole; when two devices change one at once, both versions are kept."
      >
        <Row label="Keep every version for">
          <Stepper value={settings.historySquashDays} min={1} max={365} suffix=" days" onChange={(v) => setSettings("historySquashDays", v)} />
        </Row>
        <Row label="Track files up to">
          <div class="inline-field">
            <input
              class="text-field number"
              type="number"
              min="0.1"
              step="0.5"
              value={settings.lfsThresholdMB}
              onChange={(e) => {
                const value = Math.max(0.1, Number(e.currentTarget.value) || 1);
                setSettings("lfsThresholdMB", value);
                syncService.setLfsThreshold(value);
              }}
            />
            <span>MB</span>
          </div>
        </Row>
      </Section>
      <Section title="Trash" footer="Deleted files and files other devices deleted wait here.">
        <Show when={trash()?.length} fallback={<div class="form-row secondary">The trash is empty.</div>}>
          <For each={trash()!.slice(0, 100)}>
            {(item) => (
              <div class="form-row">
                <span class="form-label ellipsis" title={`${item.space}/${item.path}`}>
                  {item.path} <span class="secondary">· {item.space}</span>
                </span>
                <button class="button small" onClick={() => void restore(item)}>
                  Put Back
                </button>
              </div>
            )}
          </For>
          <div class="form-row">
            <span />
            <button class="button small destructive" onClick={() => void empty()}>
              Empty Trash
            </button>
          </div>
        </Show>
      </Section>
    </>
  );
}

function Editor() {
  return (
    <>
      <Section title="Font">
        <Row label="Size">
          <Stepper value={settings.fontSize} min={9} max={32} suffix=" px" onChange={(v) => setSettings("fontSize", v)} />
        </Row>
        <div class="font-sample" style={{ "font-size": `${settings.fontSize}px` }}>
          <span class="tw-keyword">#let</span> greeting = <span class="tw-string">"Hello, Typst"</span>
        </div>
      </Section>
      <Section footer="Normal, insert and visual modes with Vim's motions and operators.">
        <Row label="Vim key bindings">
          <Toggle checked={settings.vim} onChange={(v) => setSettings("vim", v)} />
        </Row>
      </Section>
      <Section title="Wrapping" footer="Lines wrap at the guide, or at the editor's edge when it's narrower.">
        <Row label="Wrap lines at a column">
          <Toggle checked={settings.wrapGuide} onChange={(v) => setSettings("wrapGuide", v)} />
        </Row>
        <Show when={settings.wrapGuide}>
          <Row label="Column">
            <Stepper value={settings.wrapColumn} min={40} max={200} step={4} onChange={(v) => setSettings("wrapColumn", v)} />
          </Row>
        </Show>
      </Section>
      <Section
        title="Language Features"
        footer="Completions pop up while typing, or with Ctrl-Space. ⌘-click (Ctrl-click) a name, import or path to open its definition; F1 shows its documentation. They come from typst itself, running in this page, and from solveng's language support for its calculations."
      >
        <Row label="Completions and Go to Definition">
          <Toggle checked={settings.language} onChange={(v) => setSettings("language", v)} />
        </Row>
        <Row label={`solveng${solvengVersion() ? ` ${solvengVersion()}` : ""}`}>
          <span class="secondary">Built in</span>
        </Row>
      </Section>
    </>
  );
}

const [solvengVersion] = createResource(() => compiler.solveng<string>("version", "").catch(() => ""));

function Fonts() {
  const [query, setQuery] = createSignal("");
  onMount(() => void fontLib.loadCatalog());
  const matches = createMemo(() => {
    const q = query().trim().toLowerCase();
    if (!q) return [];
    return fontLib.fonts.catalog.filter((f) => f.family.toLowerCase().includes(q)).slice(0, 30);
  });
  const refresh = () => void workspace()?.updateFonts();

  return (
    <>
      <Section title="Space Fonts" footer="Folders inside each space, relative to its root. Their fonts are only used by that space, and sync along with it.">
        <For each={settings.spaceFontPaths}>
          {(path, i) => (
            <div class="form-row">
              <input class="text-field" value={path} placeholder="./fonts" onChange={(e) => { setSettings("spaceFontPaths", i(), e.currentTarget.value); refresh(); }} />
              <button class="icon-button" title="Remove" onClick={() => { setSettings("spaceFontPaths", (all) => all.filter((_, j) => j !== i())); refresh(); }}>
                <X size={14} />
              </button>
            </div>
          )}
        </For>
        <div class="form-row">
          <span />
          <button class="button small" onClick={() => setSettings("spaceFontPaths", (all) => [...all, "./"])}>
            Add Folder
          </button>
        </div>
      </Section>
      <Section title="Uploaded Fonts" footer="TrueType and OpenType files every space can use, kept in this browser.">
        <For each={fontLib.fonts.uploads}>
          {(name) => (
            <div class="form-row">
              <span class="form-label ellipsis">{name}</span>
              <button class="icon-button" title="Remove" onClick={() => void fontLib.removeUpload(name).then(refresh)}>
                <Trash2 size={14} />
              </button>
            </div>
          )}
        </For>
        <div class="form-row">
          <span />
          <button
            class="button small"
            onClick={async () => {
              const files = await pickFiles({ accept: ".ttf,.otf,.ttc,.otc" });
              await fontLib.upload(files.map((f) => f.file as File));
              refresh();
            }}
          >
            Upload Fonts…
          </button>
        </div>
      </Section>
      <Section title="Google Fonts" footer="Kept in this browser and available to every space. Downloaded through Fontsource.">
        <div class="form-row">
          <input class="text-field" value={query()} placeholder="Search Google Fonts" onInput={(e) => setQuery(e.currentTarget.value)} />
        </div>
        <Show when={fontLib.fonts.error}>
          <div class="form-row error-text">{fontLib.fonts.error}</div>
        </Show>
        <For each={matches()}>
          {(font) => (
            <div class="form-row">
              <span class="form-label">
                {font.family} <span class="secondary">{font.category}</span>
              </span>
              <Switch>
                <Match when={fontLib.fonts.downloads[font.family] !== undefined}>
                  <span class="secondary">{Math.round((fontLib.fonts.downloads[font.family] ?? 0) * 100)}%</span>
                </Match>
                <Match when={fontLib.fonts.installed.includes(font.family)}>
                  <span class="secondary">Downloaded</span>
                </Match>
                <Match when={true}>
                  <button class="icon-button" title="Download" onClick={() => void fontLib.download(font.family).then(refresh)}>
                    <Download size={14} />
                  </button>
                </Match>
              </Switch>
            </div>
          )}
        </For>
        <For each={fontLib.fonts.installed}>
          {(family) => (
            <div class="form-row">
              <span class="form-label">{family}</span>
              <button class="icon-button" title="Remove" onClick={() => void fontLib.remove(family).then(refresh)}>
                <Trash2 size={14} />
              </button>
            </div>
          )}
        </For>
      </Section>
    </>
  );
}

function Packages() {
  const [spec, setSpec] = createSignal("");
  const [message, setMessage] = createSignal<string | null>(null);
  const [installed, { refetch }] = createResource(() => compiler.installedPackages().catch(() => [] as string[]));

  async function download() {
    setMessage("Downloading…");
    try {
      let full = spec().trim();
      if (!/:\d+\.\d+\.\d+$/.test(full)) {
        // Without a version the newest one is fetched.
        const name = full.replace(/^@preview\//, "");
        const newest = (await compiler.packageIndex()).filter((p) => p.name === name).at(-1);
        if (!newest) throw new Error(`No package named ${name} on Typst Universe.`);
        full = `@preview/${name}:${newest.version}`;
      }
      await compiler.downloadPackage(full);
      setMessage(`Downloaded ${full}.`);
      setSpec("");
      void refetch();
      workspace()?.scheduleCompile(0);
    } catch (err) {
      setMessage((err as Error).message);
    }
  }

  return (
    <>
      <Section title="Installed" footer="Other namespaces, like @local, come from folders you add here; each holds name/version folders.">
        <For each={installed()} fallback={<div class="form-row secondary">No packages yet.</div>}>
          {(item) => (
            <div class="form-row">
              <span class="form-label mono">{item}</span>
              <button class="icon-button" title="Remove" onClick={() => void compiler.removePackage(item).then(refetch)}>
                <Trash2 size={14} />
              </button>
            </div>
          )}
        </For>
        <div class="form-row">
          <span />
          <button
            class="button small"
            onClick={async () => {
              const files = await pickFiles({ directory: true });
              if (!files.length) return;
              const namespace = (await prompt("Add Local Packages", "local", "Add", "The namespace documents import these packages from, as in @local/name:1.0.0."))?.trim();
              if (!namespace) return;
              for (const { path, file } of files) {
                // The picked folder itself is the namespace.
                const rel = path.slice(path.indexOf("/") + 1);
                await fs.writeFile(fs.join("packages", namespace, rel), new Uint8Array(await file.arrayBuffer()), true);
              }
              void refetch();
            }}
          >
            Add Local Packages…
          </button>
        </div>
      </Section>
      <Section title="Typst Universe" footer={`Downloaded automatically when a document imports "@preview/…", and kept in this browser. Download one ahead of time, e.g. to work offline. Typst ${compiler.version || "built in"}.`}>
        <div class="form-row">
          <input class="text-field" value={spec()} placeholder="@preview/cetz:0.3.1" onInput={(e) => setSpec(e.currentTarget.value)} onKeyDown={(e) => e.key === "Enter" && void download()} />
          <button class="button small" disabled={!spec().trim()} onClick={() => void download()}>
            Download
          </button>
        </div>
        <Show when={message()}>
          <div class="form-row secondary">{message()}</div>
        </Show>
      </Section>
    </>
  );
}

function short(id: string | null): string {
  return id ? `${id.slice(0, 6)}…${id.slice(-4)}` : "–";
}

function Devices() {
  const [name, setName] = createSignal("");
  const synced = createMemo(() => Object.entries(sync.spaces).filter(([, folder]) => folder));

  return (
    <>
      <Section
        title="Account"
        footer={
          sharesMacPasskeys()
            ? "Create a passkey once, then sign in with it on each device, here and in the Mac app; your password manager brings it along. Synced spaces then show up on all of them, with nothing to exchange."
            : `Passkeys here belong to ${relyingParty()}, so they don't sign in to the Mac app's account. The app at bierdav.github.io shares them.`
        }
      >
        <Show
          when={identity.account}
          fallback={
            <Show when={passkeysSupported()} fallback={<div class="form-row secondary">This browser can't use passkeys here (it needs a secure context).</div>}>
              <Row label="Name">
                <input class="text-field" value={name()} placeholder="you@example.com" onInput={(e) => setName(e.currentTarget.value)} />
              </Row>
              <Row label="Passkey">
                <div class="button-row">
                  <button class="button small" disabled={identity.working} onClick={() => void createPasskey(name()).then(syncService.restart)}>
                    <KeyRound size={13} /> Create…
                  </button>
                  <button class="button small" disabled={identity.working} onClick={() => void signInWithPasskey().then(syncService.restart)}>
                    Sign In…
                  </button>
                </div>
              </Row>
            </Show>
          }
        >
          <Show when={identity.name}>
            <Row label="Passkey">
              <span>{identity.name}</span>
            </Row>
          </Show>
          <Row label="Account">
            <span class="mono">{identity.fingerprint}</span>
          </Row>
          <Row label="">
            <button
              class="button small destructive"
              onClick={async () => {
                if (!(await confirm("Sign out?", "Syncing stops in this browser. Your spaces stay here.", "Sign Out", true))) return;
                await syncService.stop();
                signOut();
              }}
            >
              Sign Out
            </button>
          </Row>
        </Show>
        <Show when={identity.error}>
          <div class="form-row error-text">{identity.error}</div>
        </Show>
      </Section>
      <Show when={identity.account}>
        <Section title="Devices">
          <Row label="This browser">
            <span class="mono">{sync.status === "running" ? short(sync.deviceId) : sync.status === "elsewhere" ? "Syncing in another tab" : sync.status}</span>
          </Row>
          <Row label="Name shown to others">
            <input class="text-field" value={settings.deviceName} onChange={(e) => setSettings("deviceName", e.currentTarget.value || "Browser")} />
          </Row>
          <For each={sync.devices.filter((d) => d !== sync.deviceId)} fallback={<div class="form-row secondary">Sign in on another device to sync with it.</div>}>
            {(device) => (
              <Row label={short(device)}>
                <span class="secondary">{sync.connected.includes(device) ? "Connected" : "Not connected"}</span>
              </Row>
            )}
          </For>
          <Show when={sync.lastError}>
            <div class="form-row error-text">{sync.lastError}</div>
          </Show>
        </Section>
        <Section
          title="Synced Spaces"
          footer="The whole space syncs, except what its .gitignore files exclude. Invite links let other people's accounts sync a space too; anyone with a link can edit it."
        >
          <For each={synced()} fallback={<div class="form-row secondary">Turn on syncing from a space's menu in the spaces sidebar.</div>}>
            {([id, folder]) => (
              <div class="form-row">
                <span class="form-label">
                  {folder}{" "}
                  <Show when={sync.accountSpaces.find((s) => s.id === id)?.shared}>
                    <Users size={12} class="secondary" />
                  </Show>
                </span>
                <div class="button-row">
                  <button class="button small" onClick={() => { openSpace(folder); setOverlay(null); }}>
                    Open
                  </button>
                  <button class="icon-button" title="Copy invite link" onClick={() => void commands.copyInviteLink(folder)}>
                    <Link size={14} />
                  </button>
                  <button class="button small" onClick={() => syncService.stopSyncing(folder)}>
                    Stop Syncing
                  </button>
                </div>
              </div>
            )}
          </For>
          <div class="form-row">
            <span />
            <button class="button small" onClick={async () => { const folder = await commands.joinFromLink(); if (folder) { openSpace(folder); setOverlay(null); } }}>
              Join Shared Space…
            </button>
          </div>
        </Section>
      </Show>
    </>
  );
}

export default function SettingsWindow() {
  const tab = () => {
    const o = overlay();
    return (o?.type === "settings" && o.tab) || "general";
  };
  const select = (id: SettingsTab) => setOverlay({ type: "settings", tab: id });
  const close = () => setOverlay(null);
  return (
    <div class="overlay-backdrop" onMouseDown={(e) => e.target === e.currentTarget && close()} onKeyDown={(e) => e.key === "Escape" && close()}>
      <div class="settings glass" role="dialog" aria-label="Settings" tabIndex={-1} ref={(el) => requestAnimationFrame(() => el.focus())}>
        <header class="settings-toolbar">
          <For each={TABS}>
            {(t) => (
              <button class="settings-tab" classList={{ active: tab() === t.id }} onClick={() => select(t.id)}>
                {t.icon()}
                <span>{t.label}</span>
              </button>
            )}
          </For>
          <button class="icon-button settings-close" title="Close" onClick={close}>
            <X size={15} />
          </button>
        </header>
        <div class="settings-body">
          <Switch>
            <Match when={tab() === "general"}>
              <General />
            </Match>
            <Match when={tab() === "editor"}>
              <Editor />
            </Match>
            <Match when={tab() === "fonts"}>
              <Fonts />
            </Match>
            <Match when={tab() === "packages"}>
              <Packages />
            </Match>
            <Match when={tab() === "devices"}>
              <Devices />
            </Match>
          </Switch>
        </div>
      </div>
    </div>
  );
}
