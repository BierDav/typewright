// Usage: bun tests/desktop-ui.ts [vite URL]; a fresh profile exercises desktop-facing UI in both engines.
import { chromium, webkit } from "playwright-core";
import { strict as assert } from "node:assert";
import * as fs from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

for (const engine of [chromium, webkit]) {
  const library = await fs.mkdtemp(join(tmpdir(), "typewright-ui-"));
  await fs.mkdir(join(library, "Spaces"));
  const browser = await engine.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 820 } });
    await page.exposeFunction("nativeInvoke", async (command: string, args: any) => {
      const path = (rel: string) => join(library, rel.replace(/^spaces(?=\/|$)/, "Spaces"));
      if (command === "disk_write") { await fs.writeFile(path(args.path), new Uint8Array(args.data)); return; }
      if (command === "disk_read") return Array.from(await fs.readFile(path(args.path)));
      if (command === "disk_op") {
        const target = path(args.path);
        switch (args.op) {
          case "stat": { const info = await fs.stat(target).catch(() => null); return info ? { dir: info.isDirectory(), size: info.size, mtime: info.mtimeMs } : null; }
          case "list": return (await fs.readdir(target, { withFileTypes: true })).map(e => ({ name: e.name, dir: e.isDirectory() }));
          case "write": await fs.writeFile(target, new Uint8Array(args.data)); break;
          case "mkdir": await fs.mkdir(target, { recursive: true }); break;
          case "remove": await fs.rm(target, { recursive: args.recursive }); break;
          case "rename": await fs.rename(target, path(args.to)); break;
        }
      }
      if (command === "package_links") return [];
      if (command === "repository") return { ok: true, value: args.request.op === "open" ? { mode: "native" } : args.request.fn === "twj_conflicts" ? [] : null, written: [] };
      return null;
    });
    await page.addInitScript((library) => {
      const w = window as any;
      w.__TYPEWRIGHT_NATIVE__ = { library, platform: "darwin", nativeScroll: true };
      const callbacks = new Map<number, Function>(), events = new Map<string, number>();
      let next = 0;
      w.__TAURI_INTERNALS__ = {
        transformCallback: (callback: Function) => { callbacks.set(++next, callback); return next; },
        unregisterCallback: (id: number) => callbacks.delete(id),
        invoke: async (command: string, args: any, options: any) => {
          if (command === "disk_write") args = { path: decodeURIComponent(options.headers["x-typewright-path"]), data: Array.from(args) };
          if (command === "plugin:event|listen") { events.set(args.event, args.handler); return ++next; }
          if (command === "plugin:event|unlisten") return;
          const result = await w.nativeInvoke(command, args);
          return command === "disk_read" ? new Uint8Array(result).buffer : result;
        },
      };
      w.sendNativeEvent = (event: string, payload: unknown) => callbacks.get(events.get(event)!)?.({ event, payload });
    }, library);
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.goto(process.argv[2] ?? "http://localhost:5393/");
    await page.waitForSelector(".app.ready");
    await page.evaluate(async () => {
      const { monaco, applyTheme } = await import(String("/src/lib/editor/monaco.ts"));
      const { carets } = await import(String("/src/lib/editor/carets.ts"));
      const { connectedSelection } = await import(String("/src/lib/editor/selection.ts"));
      const host = document.createElement("div");
      host.id = "test-editor";
      host.style.cssText = "position:fixed;inset:100px;z-index:100";
      document.body.append(host);
      applyTheme(true);
      const editor = monaco.editor.create(host, { value: "ab\n\ncdef", language: "plaintext", fontSize: 14, multiCursorModifier: "ctrlCmd", roundedSelection: false, minimap: { enabled: false } });
      carets(editor, () => {});
      connectedSelection(editor);
      (window as any).testEditor = editor;
      editor.focus();
    });
    const pos = await page.evaluate(async () => {
      const editor = (window as any).testEditor;
      const host = editor.getContainerDomNode().getBoundingClientRect();
      const a = editor.getScrolledVisiblePosition({ lineNumber: 1, column: 3 })!;
      const b = editor.getScrolledVisiblePosition({ lineNumber: 3, column: 5 })!;
      return { x: host.left + Math.max(a.left, b.left) + 30, y: host.top + a.top + a.height / 2, endY: host.top + b.top + b.height / 2 };
    });
    await page.keyboard.down("Alt");
    await page.mouse.move(pos.x, pos.y);
    await page.mouse.down();
    await page.mouse.move(pos.x + 30, pos.endY, { steps: 8 });
    await page.mouse.up();
    await page.keyboard.up("Alt");
    await page.waitForFunction(() => (window as any).testEditor.getSelections().length === 3);
    const ends = await page.evaluate(async () => {
      const editor = (window as any).testEditor;
      return editor.getSelections()!.map((s: any) => [s.positionLineNumber, s.positionColumn]).sort((a: number[], b: number[]) => a[0] - b[0]);
    });
    assert.deepEqual(ends, [[1, 3], [2, 1], [3, 5]], `${engine.name()} empty rectangle`);
    await page.evaluate(async () => {
      const { monaco } = await import(/* @vite-ignore */ String("/src/lib/editor/monaco.ts"));
      (window as any).testEditor.setSelections([new monaco.Selection(1, 1, 1, 3), new monaco.Selection(2, 1, 3, 3)]);
    });
    await page.waitForFunction(() => !!document.querySelector(".tw-selection-shape path")?.getAttribute("d"));
    assert.equal(await page.locator(".tw-selection-shape path").evaluate((path) => getComputedStyle(path).fill), "rgba(128, 128, 128, 0.4)");
    const pixel = await page.locator("#test-editor .selected-text").last().evaluate(node => {
      const box = node.getBoundingClientRect();
      return { x: Math.round(box.left + box.width / 2), y: Math.round(box.bottom - 2) };
    });
    const png = (await page.screenshot()).toString("base64");
    const rendered = await page.evaluate(async ({ png, pixel }) => {
      const image = new Image();
      image.src = `data:image/png;base64,${png}`;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      return [...context.getImageData(pixel.x, pixel.y, 1, 1).data];
    }, { png, pixel });
    assert.ok(rendered[0] > 80 && rendered[0] < 245 && rendered[0] === rendered[1], "gray selection paints above the editor background");
    if (process.env.TYPEWRIGHT_UI_SCREENSHOT) await page.screenshot({ path: `${process.env.TYPEWRIGHT_UI_SCREENSHOT}-${engine.name()}.png` });
    await page.evaluate(async () => {
      (window as any).testEditor.dispose();
      document.getElementById("test-editor")!.remove();
      (await import(String("/src/lib/app.ts"))).showSettings("packages");
    });
    await page.getByText("Installed", { exact: true }).waitFor();
    await page.evaluate(async () => {
      const app = await import(String("/src/lib/app.ts"));
      const spaces = await import(String("/src/lib/spaces.ts"));
      app.closeSettings();
      app.openSpace(await spaces.createSpace("Gesture test"));
    });
    const rect = await page.locator(".sidebar").boundingBox();
    assert.ok(rect);
    const send = (phase: number, dx = 0, momentum = 0) => page.evaluate((event) => (window as any).sendNativeEvent("scroll-phase", event), { phase, momentum, dx, dy: 0, x: rect.x + 30, y: rect.y + 100 });
    await send(1);
    for (const delta of [50, 20, 10, 5]) await send(4, delta);
    await page.waitForTimeout(200);
    assert.notEqual(await page.evaluate(async () => (await import(String("/src/lib/app.ts"))).swipe()), null, "decreasing deltas and a pause are not a release");
    await send(2);
    await page.waitForTimeout(200);
    assert.notEqual(await page.evaluate(async () => (await import(String("/src/lib/app.ts"))).swipe()), null, "stationary fingers keep holding the sidebar");
    await send(8);
    assert.equal(await page.evaluate(async () => (await import(String("/src/lib/app.ts"))).swipe()), null);

    // Docked dev tools resize the viewport; both transitions must leave the editor usable.
    await page.setViewportSize({ width: 850, height: 620 });
    await page.setViewportSize({ width: 1280, height: 820 });
    await page.evaluate(async () => { (await import(/* @vite-ignore */ String("/src/lib/app.ts"))).closeSettings(); });
    await page.waitForSelector(".sidebar");
    assert.deepEqual(errors, [], `${engine.name()} page errors`);
    console.log(`${engine.name()}: rectangle, gray selection, Packages, native scroll phases and resize passed`);
  } finally { await browser.close(); await fs.rm(library, { recursive: true }); }
}
