import { createMemo, createResource, createSignal, For, type JSX, Match, onCleanup, onMount, Show, Switch } from "solid-js";
import { closeSettings, confirm, copyText, openSpace, overlay, prompt, setSettingsTab, type SettingsTab, settingsTab, showRecentlyDeleted, workspace } from "~/lib/app";
import * as core from "~/lib/core";
import * as commands from "~/lib/commands";
import { compiler } from "~/lib/compiler";
import * as fontLib from "~/lib/fonts";
import { accountKey, createPasskey, createWithKey, identity, setIdentity, passkeysSupported, relyingParty, sharesMacPasskeys, signInWithKey, signInWithPasskey, signOut } from "~/lib/identity";
import { DEFAULT_RETENTION, type RetentionPolicy, setSettings, settings } from "~/lib/settings";
import * as fs from "~/lib/storage";
import * as syncService from "~/lib/sync";
import { sync } from "~/lib/sync";
import { pickFiles } from "~/lib/drop";
import { desktop } from "~/lib/desktop";
import { libraryFolder } from "~/lib/disk";
import { cloneFromGitHub } from "~/lib/packages";
import { fetchSpace } from "./SpacesSidebar";
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

function Count(props: { value: number; onChange: (value: number) => void; label: string }) {
  return (
    <input
      class="text-field number"
      type="number"
      min="0"
      max="9999"
      aria-label={props.label}
      value={props.value}
      onChange={(e) => props.onChange(Math.min(9999, Math.max(0, Math.trunc(Number(e.currentTarget.value) || 0))))}
    />
  );
}

/** Mirrors the Mac's History settings: a backup-style policy of how many old versions stay. */
function Retention() {
  const policy = () => settings.historyRetention;
  const set = (key: keyof RetentionPolicy, value: number) => setSettings("historyRetention", key, value);
  const isDefault = () => (Object.keys(DEFAULT_RETENTION) as (keyof RetentionPolicy)[]).every((k) => policy()[k] === DEFAULT_RETENTION[k]);
  const rows: [keyof RetentionPolicy, string][] = [["last", "Most recent"], ["hourly", "Hourly"], ["daily", "Daily"], ["weekly", "Weekly"], ["monthly", "Monthly"]];
  return (
    <Section title="History" footer="Typewright keeps the most recent versions, then the last version of each of that many hours, days, weeks, months and years; the versions in between are combined into the next one kept.">
      <Row label="Thin out old history">
        <Toggle checked={settings.historyThinOut} onChange={(v) => setSettings("historyThinOut", v)} label="Thin out old history" />
      </Row>
      <For each={rows}>
        {([key, label]) => (
          <Row label={label}>
            <fieldset class="plain" disabled={!settings.historyThinOut}>
              <Count label={label} value={policy()[key]} onChange={(v) => set(key, v)} />
            </fieldset>
          </Row>
        )}
      </For>
      <Row label="Yearly">
        <fieldset class="plain inline-field" disabled={!settings.historyThinOut}>
          <Show when={policy().yearly >= 0}>
            <Count label="Yearly" value={policy().yearly} onChange={(v) => set("yearly", v)} />
          </Show>
          <label class="inline-field">
            <input type="checkbox" checked={policy().yearly < 0} onChange={(e) => set("yearly", e.currentTarget.checked ? -1 : 10)} />
            <span>All</span>
          </label>
        </fieldset>
      </Row>
      <Row label="">
        <button class="button small" disabled={isDefault()} onClick={() => setSettings("historyRetention", { ...DEFAULT_RETENTION })}>
          Restore Defaults
        </button>
      </Row>
    </Section>
  );
}

function General() {
  const [persisted, { refetch: recheck }] = createResource(() => navigator.storage.persisted().catch(() => false));
  const [estimate] = createResource(() => navigator.storage.estimate().catch(() => null));

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
      <Show
        when={libraryFolder()}
        fallback={
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
        }
      >
        {(folder) => (
          <Section title="Library" footer="Spaces are folders here, kept in one jj repository. Other programs, like coding agents, can work on them by path; their edits show up and are committed like yours.">
            <Row label="Spaces">
              <div class="button-row">
                {/* Marks keep the slashes in place: the path is cut on the left, so it's laid out right to left. */}
                <span class="secondary mono library-path" title={`${folder()}/Spaces`}>{`\u200E${folder()}/Spaces\u200E`}</span>
                <button class="button small" onClick={() => void copyText(`${folder()}/Spaces`, "Path copied")}>
                  Copy
                </button>
                <button class="button small" onClick={() => desktop?.reveal?.(`${folder()}/Spaces`)}>
                  {desktop?.platform === "darwin" ? "Show in Finder" : "Show Folder"}
                </button>
              </div>
            </Row>
          </Section>
        )}
      </Show>
      <Retention />
      <Section
        title="Large Files"
        footer="Every space keeps a version of each file a few seconds after it changes. Larger files and binary files like PDFs and images have no history and are synced whole; when two devices change one at once, both versions are kept."
      >
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
              }}
            />
            <span>MB</span>
          </div>
        </Row>
      </Section>
      <Section title="Recently Deleted" footer="Files deleted here, on another device or by someone you share with stay in the history, where Recently Deleted finds them again.">
        <Row label="Deleted files">
          <button class="button small" onClick={() => showRecentlyDeleted(null)}>
            Show Recently Deleted…
          </button>
        </Row>
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

  const [linked, { refetch: refreshLinked }] = createResource(async () => {
    try { return await desktop?.packageLinks() ?? []; }
    catch (error) { setMessage(`Couldn’t load linked packages: ${String((error as Error).message ?? error)}`); return []; }
  });
  const [cloning, setCloning] = createSignal(false);
  const [cloneMessage, setCloneMessage] = createSignal<string | null>(null);

  async function clone() {
    const repository = (await prompt("Clone from GitHub", "", "Next", "A package repository with a typst.toml, or one of name/version folders.", "owner/repo or a GitHub link"))?.trim();
    if (!repository) return;
    const namespace = (await prompt("Clone from GitHub", "local", "Clone", "The namespace documents import it from, as in @local/name:1.0.0."))?.trim();
    if (!namespace) return;
    setCloning(true);
    setCloneMessage("Cloning…");
    try {
      setCloneMessage(`Added ${await cloneFromGitHub(repository, namespace)}.`);
      void refetch();
      await compiler.retryPackages();
      workspace()?.scheduleCompile(0);
    } catch (err) {
      setCloneMessage((err as Error).message);
    } finally {
      setCloning(false);
    }
  }

  return (
    <>
      <Show when={desktop}>
        <Section title="Linked namespaces" footer="Linked folders stay in their original location. Unlinking leaves their contents intact.">
          <For each={linked()}>{namespace => <div class="form-row"><span class="form-label">@{namespace}</span><button class="button small" onClick={async () => { await desktop!.unlinkPackages(namespace); void refreshLinked(); void refetch(); await compiler.retryPackages(); workspace()?.scheduleCompile(0); }}>Unlink</button></div>}</For>
        </Section>
      </Show>
      <Section title="Installed" footer="Other namespaces, like @local, come from folders you add or repositories you clone from GitHub; each holds name/version folders.">
        <For each={installed()} fallback={<div class="form-row secondary">No packages yet.</div>}>
          {(item) => (
            <div class="form-row">
              <span class="form-label mono">{item}</span>
              <button class="icon-button" title="Remove" disabled={linked()?.includes(item.slice(1, item.indexOf("/")))} onClick={() => void compiler.removePackage(item).then(refetch)}>
                <Trash2 size={14} />
              </button>
            </div>
          )}
        </For>
        <div class="form-row">
          <span class="form-label" />
          <button
            class="button small"
            onClick={async () => {
              if (desktop) {
                try {
                  const picked = await desktop.packageFolder();
                  if (!picked) return;
                  const namespace = (await prompt("Link Local Packages", "local", "Link", "The namespace used in @local/name:1.0.0."))?.trim();
                  if (!namespace) return;
                  const packages = picked.manifests.flatMap(({ target, toml }) => {
                    const manifest = core.packageManifest(toml);
                    return manifest ? [{ target, name: manifest.name, version: manifest.version }] : [];
                  });
                  await desktop.linkPackages(namespace, picked.folder, packages);
                  void refetch();
                  void refreshLinked();
                  await compiler.retryPackages();
                  workspace()?.scheduleCompile(0);
                } catch (error) { setCloneMessage((error as Error).message); }
                return;
              }
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
              await compiler.retryPackages();
              workspace()?.scheduleCompile(0);
            }}
          >
            Add Local Packages…
          </button>
          <button class="button small" disabled={cloning()} onClick={() => void clone()}>
            Clone from GitHub…
          </button>
        </div>
        <Show when={cloneMessage()}>
          <div class="form-row secondary">{cloneMessage()}</div>
        </Show>
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
  const [key, setKey] = createSignal("");
  async function signIn(action: () => Promise<void>) {
    setIdentity({ working: true, error: null });
    try {
      await action();
      await syncService.restart();
    } catch (err) {
      setIdentity("error", (err as Error).message);
    } finally {
      setIdentity("working", false);
    }
  }
  const synced = createMemo(() =>
    Object.entries(sync.shares)
      .filter(([, share]) => share)
      .sort(([, a], [, b]) => a.path.localeCompare(b.path)),
  );

  return (
    <>
      <Section
        title="Account"
        footer={
          identity.kind === "temporary"
            ? "Your guest identity is saved only in this browser. Sign in or create an account below to keep these shares on your account automatically. Your files stay here."
            : identity.account
            ? "Anyone with the account key can sign in to your account; keep it like a password."
            : (sharesMacPasskeys()
                ? "Create a passkey once, then sign in with it on each device, here and in the Mac app; your password manager brings it along. Synced spaces then show up on all of them, with nothing to exchange."
                : `Passkeys here belong to ${relyingParty()}, so they don't sign in to the Mac app's account. The app at bierdav.github.io shares them.`) +
              " Without a passkey, create an account key and paste it on your other devices."
        }
      >
        <Show when={identity.kind === "temporary"}><div class="form-row">Using a temporary guest identity</div></Show>
        <Show
          when={identity.account && identity.kind !== "temporary"}
          fallback={
            <>
              <Show when={passkeysSupported()} fallback={<div class="form-row secondary">This browser can't use passkeys here (it needs a secure context).</div>}>
                <Row label="Name">
                  <input class="text-field" value={name()} placeholder="you@example.com" onInput={(e) => setName(e.currentTarget.value)} />
                </Row>
                <Row label="Passkey">
                  <div class="button-row">
                    <button class="button small" disabled={identity.working} onClick={() => void signIn(() => createPasskey(name()))}>
                      <KeyRound size={13} /> Create…
                    </button>
                    <button class="button small" disabled={identity.working} onClick={() => void signIn(signInWithPasskey)}>
                      Sign In…
                    </button>
                  </div>
                </Row>
              </Show>
              <Row label="Account Key">
                <div class="button-row">
                  <input class="text-field mono" value={key()} placeholder="Key from another device" onInput={(e) => setKey(e.currentTarget.value)} />
                  <button class="button small" disabled={identity.working || !key().trim()} onClick={() => void signIn(() => signInWithKey(key()))}>
                    Sign In
                  </button>
                  <button class="button small" disabled={identity.working} onClick={() => void signIn(createWithKey)}>
                    Create
                  </button>
                </div>
              </Row>
            </>
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
          <Row label="Account Key">
            <button class="button small" onClick={() => void navigator.clipboard.writeText(accountKey() ?? "")}>
              Copy
            </button>
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
        <Section title="Available on Your Devices" footer="Spaces, folders and files synced by your other devices can be downloaded here. Keep another device online while they download.">
          <For each={syncService.elsewhere()} fallback={
            <div class="form-row secondary">
              {sync.status === "starting" ? "Connecting to your account…" : sync.connected.length === 0 ? "Waiting for your other devices. Open Typewright on a device that syncs your spaces." : "No other shares available to download."}
            </div>
          }>
            {(share) => (
              <Row label={share.name}>
                <Show when={share.shared}><Users size={12} class="secondary" aria-label="Shared with others" /></Show>
                <button class="button small" onClick={() => void fetchSpace(share).then((path) => path && closeSettings())}>
                  <Download size={13} /> Download…
                </button>
              </Row>
            )}
          </For>
        </Section>
        <Section
          title="Shares"
          footer="A share is a space, or any folder or file in one, kept the same on your devices. Invite links let other people's accounts sync it too; anyone with a link can edit it."
        >
          <For each={synced()} fallback={<div class="form-row secondary">Share a space, folder or file from its menu.</div>}>
            {([id, share]) => (
              <div class="form-row">
                <span class="form-label">
                  {share.path}{" "}
                  <Show when={sync.accountShares.find((s) => s.id === id)?.shared}>
                    <Users size={12} class="secondary" />
                  </Show>
                  <span class="secondary"> · {sync.problems[id] ?? sync.statuses[id] ?? (syncService.isSynced(share.path) || syncService.isShared(share.path) ? "Starting" : "Unlinked")}</span>
                </span>
                <div class="button-row">
                  <button class="button small" onClick={() => { openSpace(share.path.split("/")[0]); closeSettings(); }}>
                    Open
                  </button>
                  <button class="button small" onClick={() => void commands.share(share.path)}>
                    <Link size={14} /> Sharing…
                  </button>
                </div>
              </div>
            )}
          </For>
          <For each={Object.entries(sync.parked).filter(([, p]) => p)}>
            {([id, entry]) => (
              <div class="form-row">
                <span class="form-label">
                  {entry.name}
                  <span class="secondary"> · Stopped since it was deleted. Restore it from Recently Deleted to sync it again.</span>
                </span>
                <button class="button small" onClick={() => syncService.forgetParked(id)}>
                  Forget
                </button>
              </div>
            )}
          </For>
          <div class="form-row">
            <span />
            <button class="button small" onClick={async () => { const folder = await commands.joinFromLink(); if (folder) { openSpace(folder); closeSettings(); } }}>
              Join Shared Space…
            </button>
          </div>
        </Section>
      </Show>
    </>
  );
}

/** Settings as a page of its own in the main area, picked in the spaces list. */
export default function SettingsPage() {
  const tab = () => settingsTab() ?? "general";
  let page!: HTMLDivElement;
  // Also when focus fell back to the page, as it does when a clicked button goes away.
  const onKey = (e: KeyboardEvent) => {
    const active = document.activeElement;
    if (e.key === "Escape" && !overlay() && workspace() && (!active || active === document.body || page.contains(active))) closeSettings();
  };
  window.addEventListener("keydown", onKey);
  onCleanup(() => window.removeEventListener("keydown", onKey));
  return (
    <div class="settings-page" role="region" aria-label="Settings" tabIndex={-1} ref={page}>
      <header class="settings-toolbar">
        <For each={TABS}>
          {(t) => (
            <button class="settings-tab" classList={{ active: tab() === t.id }} onClick={() => setSettingsTab(t.id)}>
              {t.icon()}
              <span>{t.label}</span>
            </button>
          )}
        </For>
      </header>
      <div class="settings-body">
        <div class="settings-content">
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
