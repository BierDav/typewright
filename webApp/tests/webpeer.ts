// The browser side of macApp's WebPeerSyncTests: the web app (dev server) in headless Chromium, signed in to the
// account the Mac test writes, answering its steps through marks in a shared folder.
// Usage: bun tests/webpeer.ts <folder> [url]; Chromium from `bunx playwright install chromium`, or `CHROMIUM`.
import { chromium } from "playwright-core";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const talk = process.argv[2];
const URL = process.argv[3] ?? "http://localhost:3000/";
const profile = mkdtempSync(join(tmpdir(), "typewright-webpeer-"));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();
const log = (text: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${text}`);

async function mac(step: string, timeout = 300_000) {
  const deadline = Date.now() + timeout;
  while (!existsSync(`${talk}/mac-${step}`)) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for mac-${step}`);
    await sleep(200);
  }
}
function signal(step: string) {
  writeFileSync(`${talk}/web-${step}`, "");
  log(`web: ${step}`);
}

await mac("1");
const secret = readFileSync(`${talk}/account.hex`, "utf8").trim();
const context = await chromium.launchPersistentContext(profile, {
  executablePath: process.env.CHROMIUM ?? chromium.executablePath(),
  headless: true,
});
const page = context.pages()[0] ?? (await context.newPage());
const logs: string[] = [];
page.on("console", (m) => logs.push(`[${m.type()}] ${m.text()}`));
page.on("pageerror", (e) => logs.push(`[pageerror] ${e.message}`));

const ev = <T>(fn: string, arg?: unknown): Promise<T> =>
  page.evaluate(new Function("arg", `return (async () => { const {jj, fs, spaces, sync, core} = window; ${fn} })()`) as any, arg);

async function until(what: string, fn: string, arg?: unknown, timeout = 180_000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    if (await ev<boolean>(fn, arg)) return;
    if (Date.now() > deadline) throw new Error(`timed out: ${what}`);
    await sleep(300);
  }
}

async function load() {
  // Modules of the dev server, by URL.
  await page.evaluate(async () => {
    const w = window as any;
    const load = (path: string) => import(path);
    w.jj = await load("/src/lib/jj.ts");
    w.fs = await load("/src/lib/storage.ts");
    w.spaces = await load("/src/lib/spaces.ts");
    w.sync = await load("/src/lib/sync.ts");
    w.core = await load("/src/lib/core.ts");
  });
  await until("repository open", `return jj.repository.status === "open";`, undefined, 60_000);
  await until("sync running", `return sync.sync.status === "running";`, undefined, 60_000);
}

let failed = false;
try {
  await page.goto(URL);
  await page.evaluate(async (secret) => {
    const load = (path: string) => import(path);
    const identity = await load("/src/lib/identity.ts");
    const sync = await load("/src/lib/sync.ts");
    await identity.signInWithKey(secret.match(/.{8}/g)!.join("-"));
    await sync.restart();
  }, secret);
  await load();
  log(`device ${await ev<string>(`return sync.sync.deviceId;`)}`);

  // 1. Download the Mac's space.
  await until("space listed", `return sync.elsewhere().some((s) => s.name === "Thesis");`);
  await page.evaluate(async () => {
    const load = (path: string) => import(path);
    const app = await load("/src/lib/app.ts");
    app.setOverlay({ type: "settings", tab: "devices" });
  });
  const available = page.locator("section").filter({ has: page.getByRole("heading", { name: "Available on Your Devices", exact: true }) });
  await available.getByText("Thesis", { exact: true }).waitFor();
  await available.getByRole("button", { name: "Download…" }).waitFor();
  await page.evaluate(async () => {
    const load = (path: string) => import(path);
    (await load("/src/lib/app.ts")).setOverlay(null);
  });
  await ev(`const share = sync.elsewhere().find((s) => s.name === "Thesis"); return await sync.join(share, await sync.suggestedDestination(share));`);
  await until("files arrived", `
    const text = await fs.readText("spaces/Thesis/main.typ");
    const pdf = await fs.readFile("spaces/Thesis/figures/plot.pdf");
    return text === "one\\ntwo\\nthree\\nfour\\nfive\\n" && pdf && [...pdf].join() === "37,80,68,70,0,1,2";`);
  signal("1");

  // 2. Change the first line while the Mac changes the last.
  await mac("2");
  await ev(`const t = await fs.readText("spaces/Thesis/main.typ"); await fs.writeFile("spaces/Thesis/main.typ", t.replace(/^one\\n/, "ONE\\n")); await jj.commit("Edit");`);
  await until("merged in the browser", `return (await fs.readText("spaces/Thesis/main.typ")) === "ONE\\ntwo\\nthree\\nfour\\nFIVE\\n";`);
  signal("2");
  await mac("2-merged");

  // 3. Offline, edit the same line as the Mac; back online, resolve the conflict here.
  await ev(`await sync.stop();`);
  signal("3-offline");
  await mac("3");
  await ev(`await fs.writeFile("spaces/Thesis/main.typ", "ONE (web)\\ntwo\\nthree\\nfour\\nFIVE\\n"); await jj.commit("Edit");`);
  await ev(`void sync.restart();`);
  await until("sync running again", `return sync.sync.status === "running";`, undefined, 60_000);
  await until("conflict in the browser", `return jj.repository.conflicted.includes("Thesis/main.typ");`);
  const conflict = await ev<any>(`return await jj.conflict("Thesis/main.typ");`);
  log(`conflict sides: ${JSON.stringify(conflict?.sides)}`);
  await until("conflicts status", `const id = sync.shareId("Thesis"); return sync.sync.statuses[id] === "Conflicts";`, undefined, 30_000);
  const resolved = await ev<boolean>(`return await jj.resolve("Thesis/main.typ", "ONE (both)\\ntwo\\nthree\\nfour\\nFIVE\\n");`);
  if (!resolved) throw new Error("resolve failed");
  await until("resolved here", `return jj.repository.conflicted.length === 0 && (await fs.readText("spaces/Thesis/main.typ")) === "ONE (both)\\ntwo\\nthree\\nfour\\nFIVE\\n";`);
  signal("3");

  // 4. LFS files both ways.
  await mac("4");
  await until("the Mac's LFS file", `const b = await fs.readFile("spaces/Thesis/image.png"); return !!b && [...b].join() === "137,80,78,71,0,1,2,3";`);
  await ev(`await fs.writeFile("spaces/Thesis/figures/web.png", new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 9, 9, 9])); await jj.commit("Add");`);
  signal("4");

  // 5. Join the Mac's file share as Inbox/shopping.typ and edit it.
  await mac("5");
  const link = readFileSync(`${talk}/invite.txt`, "utf8").trim();
  const joined = await ev<string | null>(`const invite = sync.parseInvite(arg); return await sync.joinInvite(invite, "Inbox/shopping.typ");`, link);
  if (joined !== "Inbox/shopping.typ") throw new Error(`joined at ${joined}: ${await ev(`return sync.sync.lastError;`)}`);
  await until("the shared file", `return (await fs.readText("spaces/Inbox/shopping.typ")) === "- milk\\n";`);
  await ev(`await fs.writeFile("spaces/Inbox/shopping.typ", "- milk\\n- eggs\\n"); await jj.commit("Edit");`);
  const inbox = await ev<string[]>(`return (await fs.list("spaces/Inbox")).map((e) => fs.basename(e.path));`);
  if (inbox.join() !== "shopping.typ") throw new Error(`Inbox holds ${inbox}`);
  signal("5");

  // 6. Live editing with the Mac.
  await mac("6-open");
  await ev(`
    window.lt = await fs.readText("spaces/Thesis/main.typ");
    window.cursors = [];
    sync.liveOpen("Thesis", "main.typ", window.lt);
    window.liveStep = (location) => {
      const r = sync.liveSync("Thesis", "main.typ", window.lt, location, 0, 0);
      if (!r) return false;
      if (r.adopted) {
        const m = core.merge3(r.adopted.base, window.lt, r.adopted.theirs);
        window.lt = m.conflicts === 0 ? m.text : r.adopted.theirs;
        return window.liveStep(location);
      }
      for (const e of r.edits) window.lt = window.lt.slice(0, e.location) + e.text + window.lt.slice(e.location + e.length);
      window.cursors = r.cursors;
      return true;
    };`);
  await until("live sessions meet", `window.liveStep(0); return window.cursors.length > 0;`, undefined, 120_000);
  await mac("6");
  const start = Date.now();
  await until("the Mac's live edit", `window.liveStep(0); return window.lt.includes("two (live from mac)");`, undefined, 60_000);
  log(`live edit from the Mac seen after ${Date.now() - start} ms`);
  await ev(`window.lt = window.lt.replace("three\\n", "three (live from web)\\n"); window.liveStep(0);`);
  for (let i = 0; i < 20; i++) {
    await ev(`window.liveStep(0);`);
    await sleep(250);
  }
  signal("6");
  await mac("done");
  const text = await ev<string>(`window.liveStep(0); return window.lt;`);
  await fs_write(text);
  await until("settled in the browser", `
    window.liveStep(0);
    const id = sync.shareId("Thesis");
    return sync.sync.statuses[id] === "Synced" && jj.repository.conflicted.length === 0 &&
      (await fs.readText("spaces/Thesis/main.typ")) === window.lt;`);
  log(`final text: ${JSON.stringify(text)}`);
  signal("done");

  // 7. A large LFS file, then a reload before the Mac may have fetched it: it still arrives.
  await ev(`
    const bytes = new Uint8Array(4 << 20);
    for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 7) % 251;
    bytes.set([0x89, 0x50, 0x4e, 0x47]);
    await fs.writeFile("spaces/Thesis/figures/big.png", bytes);
    await jj.commit("Add");`);
  await until("big.png published", `
    for (const e of await fs.walk("sync")) {
      if (!e.path.includes("/lfs/") || e.kind !== "file") continue;
      if ((await fs.readText("sync/" + e.path))?.includes("figures/big.png")) return true;
    }
    return false;`);
  await page.reload();
  await load();
  signal("7");
  const report = setInterval(async () => log(`state: ${await ev<string>(`const s = sync.sync; return JSON.stringify({ statuses: s.statuses, connected: s.connected.length, lastError: s.lastError });`).catch(() => "?")}`), 10_000);
  await mac("7").finally(() => clearInterval(report));
} catch (err) {
  failed = true;
  console.log(`FAIL ${(err as Error).message}`);
  console.log(`sync: ${await ev<string>(`const s = sync.sync; return JSON.stringify({ statuses: s.statuses, problems: s.problems, lastError: s.lastError, connected: s.connected, conflicted: jj.repository.conflicted });`).catch(() => "unavailable")}`);
} finally {
  const errors = logs.filter((l) => /error|warn/i.test(l));
  if (errors.length) console.log(`console:\n${errors.slice(-40).join("\n")}`);
  await context.close();
  rmSync(profile, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

async function fs_write(text: string) {
  await ev(`await fs.writeFile("spaces/Thesis/main.typ", arg); await jj.commit("Edit");`, text);
}
