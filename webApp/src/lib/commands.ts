// Editor commands shared by key bindings and the command palette.
import { openSearchPanel } from "@codemirror/search";
import type { EditorView } from "@codemirror/view";
import { alert, choose, copyText, editorView, prompt, setOverlay, toast, workspace } from "./app";
import { identity } from "./identity";
import { goToDefinition, showDocs, type LanguageContext } from "./editor/language";
import * as refactor from "./editor/refactor";
import * as solveng from "./editor/solveng";
import { download } from "./spaces";
import * as fs from "./storage";
import * as syncService from "./sync";

export function languageContext(): LanguageContext {
  return {
    path: () => workspace()?.state.selected ?? "",
    open: (path, from, to) => void workspace()?.open(path, from, to),
    notify: toast,
    solvengContext: () => workspace()?.solvengContext() ?? Promise.resolve(""),
    showSolvengUsages: (offset) => setOverlay({ type: "palette", page: `solveng-usages:${offset}` }),
  };
}

function view(): EditorView | null {
  return editorView();
}

async function report(result: Promise<string | null>) {
  const error = await result;
  if (error) toast(error);
}

export function find(replace = false) {
  const v = view();
  if (!v) return;
  openSearchPanel(v);
  // The panel's replace field is right after the search field.
  if (replace) requestAnimationFrame(() => v.dom.querySelector<HTMLInputElement>(".cm-search input[name=replace]")?.focus());
}

export function quickDocs() {
  const v = view();
  if (v) void showDocs(v, languageContext());
}

export function definition() {
  const v = view();
  if (v) void goToDefinition(v, languageContext());
}

export function rename() {
  const v = view();
  const path = workspace()?.state.selected;
  if (v && path) void report(refactor.renameSymbol(v, path));
}

export async function extractVariable(all = false) {
  const v = view();
  if (!v) return;
  const candidates = await refactor.extractCandidates(v);
  if (!candidates.length) return toast("Select an expression to extract.");
  let pick = candidates[0];
  if (candidates.length > 1 && v.state.selection.main.empty) {
    const label = (text: string) => (text.length > 48 ? `${text.slice(0, 45)}…` : text).replace(/\s+/g, " ");
    const chosen = await choose("Extract Variable", "Which expression?", [
      ...candidates.slice(0, 5).map((c, i) => ({ label: label(c.text), value: String(i) })),
      { label: "Cancel", value: "cancel", role: "cancel" as const },
    ]);
    if (chosen === null || chosen === "cancel") return;
    pick = candidates[Number(chosen)];
  }
  await report(refactor.extractVariable(v, { start: pick.start, length: pick.length }, all));
}

export async function extractFunction(chooseScope = false) {
  const v = view();
  if (!v) return;
  if (!chooseScope) return report(refactor.extractFunction(v));
  const scopes = await refactor.functionScopes(v);
  if (!scopes.length) return toast("Select the code to extract.");
  const chosen = await choose("Extract Function", "Where should the function go?", [
    ...scopes.map((s, i) => ({ label: s.text, value: String(i) })),
    { label: "Cancel", value: "cancel", role: "cancel" as const },
  ]);
  if (chosen === null || chosen === "cancel") return;
  await report(refactor.extractFunction(v, scopes[Number(chosen)].start));
}

/** ⌥↩: rewrites of the solveng calculation at the caret. */
export async function contextActions() {
  const v = view();
  if (!v) return;
  const found = await solveng.conversions(v, (await workspace()?.solvengContext()) ?? "");
  if (!found.length) return toast("Nothing to convert here.");
  if (found.length === 1) return found[0].run();
  const chosen = await choose("Context Actions", "What should happen here?", [
    ...found.map((c, i) => ({ label: c.title, value: String(i) })),
    { label: "Cancel", value: "cancel", role: "cancel" as const },
  ]);
  if (chosen !== null && chosen !== "cancel") found[Number(chosen)].run();
}

export function inlineVariable() {
  const v = view();
  if (v) void report(refactor.inlineVariable(v));
}

export async function exportPDF() {
  const ws = workspace();
  if (!ws) return;
  const result = await ws.exportPDF();
  if (typeof result === "string") return alert("Couldn't export a PDF", result);
  const name = fs.basename(ws.state.preview ?? "document").replace(/\.typ$/, "") + ".pdf";
  download(name, result, "application/pdf");
}

/** Share… for a space, folder or file (repository path): sync it to this account's devices, or invite others. */
export async function share(path: string) {
  if (!syncService.isRunning()) {
    return alert("Syncing isn't running.", "Sign in with your passkey in Settings › Devices first.");
  }
  const name = fs.basename(path);
  const synced = syncService.isSynced(path);
  const choice = await choose(
    `Share “${name}”`,
    "Syncing keeps it the same on every device of your account. An invite link lets other people's accounts sync and edit it too, so only send it to people you trust; they need a Typewright account, in the Mac app or in the browser.",
    [
      { label: "Cancel", value: "cancel", role: "cancel" },
      synced ? { label: "Stop Syncing on This Device", value: "stop" } : { label: "Sync to My Devices", value: "sync" },
      { label: "Copy Invite Link", value: "invite", role: "default" },
    ],
  );
  if (choice === "stop") return syncService.stopSyncing(path);
  if (choice === "sync") return void (await syncService.share(path));
  if (choice !== "invite") return;
  if (!synced && !(await syncService.share(path))) return alert(`Couldn't share “${name}”.`);
  const link = syncService.inviteLink(path);
  if (!link) return alert("Couldn't create an invite link.", "Syncing has to be running; check Settings › Devices.");
  await copyText(link, "Invite link copied");
  await alert("Invite link copied", "Send it to the people you invite. The first link opens in the Mac app; the second joins in the browser.", [
    link,
    syncService.webInviteLink(link),
  ]);
}

type DestinationRequest = { name: string; file: boolean; resolve: (path: string | null) => void };
let destinationRequest: DestinationRequest | null = null;

/** What the destination page asks for, while it's open. */
export function pendingDestination(): { name: string; file: boolean } | null {
  return destinationRequest;
}

/** Asks where a share goes in the library: a new space, or into a folder (a file always goes into a space). */
export function pickDestination(name: string, file: boolean): Promise<string | null> {
  destinationRequest?.resolve(null);
  return new Promise((resolve) => {
    destinationRequest = { name, file, resolve };
    setOverlay({ type: "palette", page: "destination" });
  });
}

/** Answers `pickDestination`; null when the page closed without a choice. */
export function settleDestination(path: string | null) {
  const request = destinationRequest;
  destinationRequest = null;
  request?.resolve(path);
}

/** Joins an invite link (asking for a destination); returns the space folder to open. */
export async function joinFromLink(text?: string): Promise<string | null> {
  const link = text ?? (await prompt("Join a Shared Space", "", "Join", "Paste the invite link someone sent you.", "typewright://join/…"));
  if (!link) return null;
  const invite = syncService.parseInvite(link);
  if (!invite) {
    await alert("This invite link isn't valid.", "It may have been cut off when it was sent; ask for a new one.");
    return null;
  }
  // Links that open the page arrive while the node is still starting.
  const waiting = () => syncService.sync.status === "starting" || (!!identity.account && syncService.sync.status === "off");
  for (let i = 0; i < 150 && waiting(); i++) await new Promise((r) => setTimeout(r, 100));
  if (!syncService.isRunning()) {
    await alert(`Sign in to join “${invite.name}”`, "Shared spaces sync through a Typewright account. Create a passkey or sign in with yours in Settings › Devices, then open the link again.");
    return null;
  }
  const existing = syncService.pathOf(invite.id);
  if (existing) return fs.split(existing)[0];
  const dest = await pickDestination(invite.name, !!invite.file);
  if (!dest) return null;
  const path = await syncService.joinInvite(invite, dest);
  if (!path) await alert(`Couldn't join “${invite.name}”`, syncService.sync.lastError ?? undefined);
  return path ? fs.split(path)[0] : null;
}
