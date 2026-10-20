// Editor commands shared by key bindings and the command palette.
import { openSearchPanel } from "@codemirror/search";
import type { EditorView } from "@codemirror/view";
import { alert, choose, copyText, editorView, prompt, toast, workspace } from "./app";
import { identity } from "./identity";
import { goToDefinition, showDocs, type LanguageContext } from "./editor/language";
import * as refactor from "./editor/refactor";
import { download } from "./spaces";
import * as fs from "./storage";
import * as syncService from "./sync";

export function languageContext(): LanguageContext {
  return {
    path: () => workspace()?.state.selected ?? "",
    open: (path, from, to) => void workspace()?.open(path, from, to),
    notify: toast,
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

export async function copyInviteLink(folder: string) {
  if (!syncService.isRunning()) {
    return alert("Syncing isn't running.", "Sign in with your passkey in Settings › Devices first.");
  }
  if (!syncService.isSynced(folder)) {
    const ok = await choose(`Sync “${folder}” to invite others?`, "Invites work for synced spaces. Turn on syncing for this space?", [
      { label: "Cancel", value: "cancel", role: "cancel" },
      { label: "Sync and Invite", value: "ok", role: "default" },
    ]);
    if (ok !== "ok") return;
    syncService.share(folder);
  }
  const ok = await choose(
    `Invite others to “${folder}”?`,
    "Anyone with the link can download this space and edit its files, so only send it to people you trust. They need a Typewright account (a passkey) to join, in the Mac app or in the browser.",
    [
      { label: "Cancel", value: "cancel", role: "cancel" },
      { label: "Copy Invite Link", value: "ok", role: "default" },
    ],
  );
  if (ok !== "ok") return;
  const link = syncService.inviteLink(folder);
  if (!link) return alert("Couldn't create an invite link.", "Syncing has to be running; check Settings › Devices.");
  await copyText(link, "Invite link copied");
  await alert("Invite link copied", "Send it to the people you invite. The first link opens in the Mac app; the second joins in the browser.", [
    link,
    syncService.webInviteLink(link),
  ]);
}

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
  return syncService.joinInvite(invite);
}
