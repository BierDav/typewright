// Covers independent controls and credential replacement through the real palette.
import { chromium } from "playwright-core";
import { randomBytes } from "node:crypto";
import assert from "node:assert/strict";
const browser = await chromium.launch();
const url = process.argv[2] ?? "http://localhost:5391/";
try {
  const context = await browser.newContext({
    permissions: ["clipboard-read", "clipboard-write"],
  });
  const page = await context.newPage();
  page.setDefaultTimeout(20000);
  page.on("pageerror", (e) => console.log("PAGEERROR", e.message));
  await page.addInitScript(
    (secret) =>
      localStorage.setItem(
        "typewright.account",
        JSON.stringify({ secret, name: "test", kind: "key" }),
      ),
    randomBytes(32).toString("hex"),
  );
  await page.goto(url);
  await page
    .locator('button[title="Devices and syncing"]')
    .filter({ hasText: /Synced|connected/ })
    .waitFor({ timeout: 60000 });
  await page.getByRole("button", { name: "New Space", exact: true }).click();
  await page.getByPlaceholder("Space name").fill("Palette Test");
  await page
    .getByRole("alertdialog")
    .getByRole("button", { name: "Create", exact: true })
    .click();
  const row = page
    .locator(".space-row")
    .filter({ has: page.locator(".space-label", { hasText: "Palette Test" }) });
  const sharing = row.locator('button[title="Sharing…"]');
  const icon = (name: string) => row.locator(`[aria-label="${name}"]`);
  const palette = () => page.getByRole("dialog", { name: "Command palette" });
  const action = (title: string) =>
    palette()
      .locator(".palette-row")
      .filter({
        has: page.locator(".palette-title", {
          hasText: new RegExp("^" + title + "$"),
        }),
      });
  await palette().waitFor({ state: "hidden" });
  await sharing.click();
  await action("Create Sharing Link").click();
  await icon("Shared with others").waitFor();
  assert.equal(await icon("Available on your devices").count(), 0);
  await palette().waitFor({ state: "hidden" });
  await sharing.click();
  await action("Enable Device Sync").click();
  await icon("Available on your devices").waitFor();
  assert.equal(await icon("Shared with others").count(), 1);
  await palette().waitFor({ state: "hidden" });
  await sharing.click();
  await action("Unlink Across My Devices").click();
  await icon("Available on your devices").waitFor({ state: "detached" });
  assert.equal(await icon("Shared with others").count(), 1);
  await palette().waitFor({ state: "hidden" });
  await sharing.click();
  await action("Enable Device Sync").click();
  await icon("Available on your devices").waitFor();
  const oldLink = await page.evaluate(() => navigator.clipboard.readText());
  await palette().waitFor({ state: "hidden" });
  await sharing.click();
  await action("Create New Sharing Link…").click();
  await page
    .getByRole("alertdialog")
    .getByRole("button", { name: "Replace", exact: true })
    .click();
  await page.waitForFunction(
    async (old) => (await navigator.clipboard.readText()) !== old,
    oldLink,
    { timeout: 20000 },
  );
  await palette().waitFor({ state: "hidden" });
  await sharing.click();
  await action("Revoke Sharing Link…").click();
  await page
    .getByRole("alertdialog")
    .getByRole("button", { name: "Revoke", exact: true })
    .click();
  await icon("Shared with others").waitFor({ state: "detached" });
  assert.equal(await icon("Available on your devices").count(), 1);
  console.log(
    "Sharing palette: create, replace, revoke, independent device sync, and both icons passed",
  );
} finally {
  await browser.close();
}
