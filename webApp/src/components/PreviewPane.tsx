import { createEffect, createMemo, createResource, createSignal, For, Match, on, onCleanup, Show, Switch } from "solid-js";
import * as core from "~/lib/core";
import * as commands from "~/lib/commands";
import { compiler } from "~/lib/compiler";
import { isDark, type RenderMode, setSettings, settings } from "~/lib/settings";
import type { Workspace } from "~/lib/workspace";
import { isMarkdown, isPreviewable } from "~/lib/kinds";
import { basename, readText, join } from "~/lib/storage";
import { Ellipsis, Moon, Sun, ZoomIn, ZoomOut } from "./icons";
import { type MenuItem, showMenu } from "./Menu";

const ZOOMS = [0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];

function blobUrl(data: () => Uint8Array | null, type: string) {
  const url = createMemo<string | null>((previous) => {
    if (previous) URL.revokeObjectURL(previous);
    const bytes = data();
    return bytes ? URL.createObjectURL(new Blob([bytes as Uint8Array<ArrayBuffer>], { type })) : null;
  }, null);
  onCleanup(() => {
    const last = url();
    if (last) URL.revokeObjectURL(last);
  });
  return url;
}

function markdownPage(body: string, textSize: number, codeCss: string): string {
  const dark = isDark();
  return `<!doctype html><html><head><meta charset="utf-8"><base target="_blank"><style>
:root { color-scheme: ${dark ? "dark" : "light"}; }
body { font: ${textSize}px/1.55 -apple-system, system-ui, sans-serif; max-width: 46em; margin: 0 auto; padding: 24px 28px 64px; color: ${dark ? "#e6e6e6" : "#1d1d1f"}; background: transparent; }
pre, code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.88em; }
pre { padding: 12px 14px; border-radius: 8px; background: ${dark ? "#ffffff10" : "#00000008"}; overflow: auto; }
:not(pre) > code { padding: 1px 5px; border-radius: 5px; background: ${dark ? "#ffffff14" : "#0000000b"}; }
table { border-collapse: collapse; } td, th { border: 1px solid ${dark ? "#ffffff24" : "#0000001f"}; padding: 4px 10px; }
blockquote { margin-left: 0; padding-left: 14px; border-left: 3px solid ${dark ? "#ffffff30" : "#00000020"}; color: ${dark ? "#bbb" : "#555"}; }
img { max-width: 100%; } a { color: #0a84ff; }
${codeCss}
</style></head><body>${body}</body></html>`;
}

/** Registers the fonts the app posts (the sandboxed page can't read origin storage); the page stays hidden until
 * they're in, so text doesn't jump from a fallback font. */
const FONT_SCRIPT = `<script>(() => {
  const root = document.documentElement;
  root.style.visibility = "hidden";
  const show = () => (root.style.visibility = "");
  setTimeout(show, 1000);
  addEventListener("message", (event) => {
    if (event.source !== parent || event.data?.type !== "typewright-fonts") return;
    const loads = event.data.fonts.map((f) => {
      const face = new FontFace(f.family, f.data, { weight: String(f.weight), style: f.italic ? "italic" : "normal" });
      document.fonts.add(face);
      return face.load().catch(() => {});
    });
    Promise.all(loads).then(show);
  });
})();</script>`;

/** typst's HTML with the font script at the start of its head. */
function htmlPage(html: string): string {
  const dark = settings.previewDark && isDark();
  html = html.replace(/(<style\b[^>]*>)([\s\S]*?)(<\/style>)/gi, (_, start, css, end) =>
    start + css.replace(/\(prefers-color-scheme:\s*(dark|light)\)/gi, (_: string, scheme: string) => scheme.toLowerCase() === (dark ? "dark" : "light") ? "(min-width: 0px)" : "(max-width: -1px)") + end);
  const head = /<head[^>]*>/i.exec(html);
  if (!head) return FONT_SCRIPT + html;
  const at = head.index + head[0].length;
  return html.slice(0, at) + `<style>:root { color-scheme: ${settings.previewDark && isDark() ? "dark" : "light"}; }</style>` + FONT_SCRIPT + html.slice(at);
}

// Mobile browsers have no inline PDF viewer and leave the frame blank.
const canShowPdf = typeof navigator === "undefined" || navigator.pdfViewerEnabled !== false;

export default function PreviewPane(props: { workspace: Workspace }) {
  const ws = props.workspace;
  const [warningDismissed, setWarningDismissed] = createSignal(false);
  createEffect(on(() => ws.state.preview, () => setWarningDismissed(false)));
  async function addLetmeout() {
    const path = file();
    if (!path) return;
    const text = path === ws.state.selected ? ws.state.text : await readText(join(ws.root, path));
    if (text === null) return;
    const installed = await compiler.installedPackages();
    const spec = installed.filter(s => /^@[^/]+\/letmeout:/.test(s)).sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))[0] ?? "@preview/letmeout:0.2.0";
    ws.updateBuffer(path, core.applyPackageShowRule(text, "letmeout", spec));
  }
  const [markdownCss] = createResource(() => compiler.markdownCss().catch(() => ""));
  let scroller: HTMLDivElement | undefined;
  const [zoom, setZoom] = createSignal<number | "fit">("fit");
  const [width, setWidth] = createSignal(600);
  const [page, setPage] = createSignal(0);
  const [marker, setMarker] = createSignal<{ page: number; x: number; y: number } | null>(null);
  const pdfUrl = blobUrl(() => ws.state.pdf, "application/pdf");
  const previewable = createMemo(() => ws.files().filter((f) => isPreviewable(f.path)));

  let htmlFrame: HTMLIFrameElement | undefined;
  // Fonts downloaded or added while the page shows.
  createEffect(on(ws.htmlFonts, () => htmlFrame?.isConnected && postFonts(htmlFrame), { defer: true }));

  /** Sends the faces of families the page names; matching the text is cheap and skips most of the bytes. */
  function postFonts(frame: HTMLIFrameElement) {
    const html = (ws.state.html ?? "").toLowerCase();
    const fonts = ws.htmlFonts().filter((f) => html.includes(f.family.toLowerCase()));
    // Copies, as transferring would detach the compiler's buffers.
    frame.contentWindow?.postMessage({ type: "typewright-fonts", fonts: fonts.map((f) => ({ ...f, data: f.data.slice().buffer })) }, "*");
  }

  // Small changes, like a scrollbar appearing, would resize the pages again and again.
  const observer = new ResizeObserver(([entry]) => {
    const next = entry.contentRect.width;
    if (Math.abs(next - width()) > 24) setWidth(next);
  });
  onCleanup(() => observer.disconnect());

  /** Pages in CSS pixels per point: fitted to the pane, or a fixed zoom. */
  const scale = createMemo(() => {
    const z = zoom();
    if (z !== "fit") return z * (96 / 72);
    const pt = ws.state.svgPages?.[0]?.width ?? 595;
    return Math.max((width() - 48) / pt, 0.1);
  });

  function step(delta: number) {
    const current = zoom() === "fit" ? scale() / (96 / 72) : (zoom() as number);
    const next = delta > 0 ? ZOOMS.find((z) => z > current + 0.001) : [...ZOOMS].reverse().find((z) => z < current - 0.001);
    if (next) setZoom(next);
  }

  /** A click on a page jumps to the source that made it. */
  async function click(event: MouseEvent, index: number) {
    // Selecting text isn't a click on the page.
    if (!getSelection()?.isCollapsed) return;
    const svg = (event.currentTarget as HTMLElement).querySelector("svg");
    if (!svg) return;
    const rect = svg.getBoundingClientRect();
    const box = svg.viewBox.baseVal;
    const x = ((event.clientX - rect.left) / rect.width) * box.width;
    const y = ((event.clientY - rect.top) / rect.height) * box.height;
    const jump = await compiler.jumpFromClick(index, x, y).catch(() => null);
    if (!jump) return;
    if ("url" in jump) window.open(jump.url, "_blank", "noopener");
    else if ("path" in jump) void ws.open(jump.path, jump.offset);
    else scrollTo(jump);
  }

  const pageElements = () => scroller?.querySelectorAll<HTMLElement>(".svg-page") ?? [];

  function scrollTo(position: { page: number; x: number; y: number }, onlyIfHidden = false) {
    const pageEl = pageElements()[position.page];
    if (!pageEl || !scroller) return;
    const top = pageEl.offsetTop + position.y * scale() - scroller.clientHeight / 3;
    const visible = top + scroller.clientHeight / 3 > scroller.scrollTop && top + scroller.clientHeight / 3 < scroller.scrollTop + scroller.clientHeight;
    if (onlyIfHidden && visible) return;
    scroller.scrollTo({ top, behavior: "smooth" });
  }

  // The caret's place in the document follows into the SVG preview.
  let followTimer: ReturnType<typeof setTimeout> | undefined;
  createEffect(
    on(
      () => [ws.state.selection.from, ws.state.selected] as const,
      ([from, path]) => {
        clearTimeout(followTimer);
        if (settings.renderMode !== "svg" || !path?.endsWith(".typ")) return;
        followTimer = setTimeout(async () => {
          const positions = await compiler.jumpFromCursor(path, from).catch(() => []);
          const first = positions[0];
          setMarker(first ?? null);
          if (first) scrollTo(first, true);
        }, 350);
      },
      { defer: true },
    ),
  );
  onCleanup(() => clearTimeout(followTimer));

  // Pages above the middle of the pane, binary searched since documents can be long.
  let scrollFrame = 0;
  function onScroll() {
    if (scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = 0;
      const pages = pageElements();
      if (!scroller || !pages.length) return;
      const middle = scroller.scrollTop + scroller.clientHeight / 2;
      let low = 0;
      let high = pages.length - 1;
      while (low < high) {
        const mid = (low + high + 1) >> 1;
        if (pages[mid].offsetTop <= middle) low = mid;
        else high = mid - 1;
      }
      setPage(low);
    });
  }
  onCleanup(() => cancelAnimationFrame(scrollFrame));

  function setMode(mode: RenderMode) {
    if (mode === settings.renderMode) return;
    setSettings("renderMode", mode);
    ws.setRenderMode();
  }

  const file = () => ws.state.preview;
  const errors = () => ws.state.diagnostics.filter((d) => d.severity === "error").length;
  const isTypst = () => !!file()?.endsWith(".typ");
  const zoomable = () => isTypst() && settings.renderMode === "svg" && !!ws.state.svgPages;

  function moreMenu(): MenuItem[] {
    const items: MenuItem[] = [];
    if (isTypst()) {
      items.push({ header: "Render As" });
      for (const [mode, label] of [["svg", "SVG"], ["pdf", "PDF"], ["html", "HTML"]] as [RenderMode, string][]) {
        items.push({ label, checked: settings.renderMode === mode, action: () => setMode(mode) });
      }
      items.push({ separator: true });
    }
    if (previewable().length > 1) {
      items.push({ header: "Preview" });
      for (const f of previewable()) items.push({ label: f.path, checked: f.path === file(), action: () => ws.setPreview(f.path) });
      items.push({ separator: true });
    }
    if (isTypst() && settings.renderMode === "html") items.push({ label: "Dark Mode", checked: settings.previewDark, action: () => setSettings("previewDark", (v) => !v) }, { separator: true });
    if (isTypst()) items.push({ label: "Export PDF…", action: () => void commands.exportPDF() });
    items.push({ label: ws.state.previewMode === "pinned" ? "Unpin Preview" : "Pin Preview", action: () => (ws.state.previewMode === "pinned" ? ws.followSelection() : ws.setPreview(file()!)) });
    items.push({ label: "Hide Preview", action: () => ws.setPreview(null) });
    return items;
  }

  return (
    <section class="preview">
      <Show when={isTypst() && settings.renderMode === "html" && settings.previewDark && isDark() && ws.state.html && !/prefers-color-scheme|color-scheme\s*:/i.test(ws.state.html) && !warningDismissed()}>
        <div class="form-row" role="status">
          <span>This document ignores dark mode. Add letmeout, or configure its show rule, to adapt the HTML to dark mode.</span>
          <button class="button small" onClick={() => void addLetmeout()}>Add / configure letmeout</button>
          <button class="button small" onClick={() => setWarningDismissed(true)}>Dismiss</button>
        </div>
      </Show>
      <div class="preview-body">
        <Switch
          fallback={
            <div class="empty-state">
              <Show when={file()} fallback={<p class="secondary">Choose a Typst or Markdown file to preview.</p>}>
                <Show when={ws.state.failure || errors() > 0} fallback={<div class="spinner" aria-label="Compiling" />}>
                  <p class="title">Compilation failed</p>
                  <Show when={ws.state.failure}>
                    <p class="secondary">{ws.state.failure}</p>
                  </Show>
                  <Show when={errors() > 0 && !ws.state.failure}>
                    <button class="link-button" onClick={() => ws.revealDiagnostic(ws.state.diagnostics[0])}>
                      {errors()} {errors() === 1 ? "error" : "errors"} in {basename(file()!)}; show the first
                    </button>
                  </Show>
                </Show>
              </Show>
            </div>
          }
        >
          <Match when={file() && isMarkdown(file()!) && ws.state.markdownHtml !== null}>
            <iframe class="html-frame" sandbox="allow-popups" srcdoc={markdownPage(ws.state.markdownHtml!, settings.previewTextSize, markdownCss() ?? "")} title="Markdown preview" />
          </Match>
          <Match when={settings.renderMode === "svg" && ws.state.svgPages}>
            <div
              class="svg-scroller"
              ref={(el) => {
                scroller = el;
                observer.observe(el);
              }}
              onScroll={onScroll}
              onWheel={(e) => {
                if (!e.ctrlKey && !e.metaKey) return;
                e.preventDefault();
                step(e.deltaY < 0 ? 1 : -1);
              }}
            >
              {/* Keyed by page object: a page whose layout didn't change keeps its parsed SVG. */}
              <For each={ws.state.svgPages!}>
                {(svgPage, index) => (
                  <div
                    class="svg-page"
                    style={{
                      width: `${(svgPage.width * scale()).toFixed(1)}px`,
                      "aspect-ratio": `${svgPage.width} / ${svgPage.height}`,
                      "contain-intrinsic-size": `auto ${(svgPage.width * scale()).toFixed(0)}px auto ${(svgPage.height * scale()).toFixed(0)}px`,
                    }}
                    innerHTML={svgPage.svg}
                    onClick={(e) => void click(e, index())}
                  />
                )}
              </For>
              <Show when={marker()}>
                {(m) => {
                  const pageEl = () => pageElements()[m().page];
                  return (
                    <Show when={pageEl()}>
                      <div class="jump-marker" style={{ top: `${pageEl()!.offsetTop + m().y * scale()}px`, left: `${pageEl()!.offsetLeft + m().x * scale()}px` }} />
                    </Show>
                  );
                }}
              </Show>
            </div>
          </Match>
          <Match when={settings.renderMode === "pdf" && pdfUrl() && !canShowPdf}>
            <div class="empty-state">
              <p class="title">This browser can't show PDFs inline</p>
              <div class="welcome-actions">
                <a class="button" href={pdfUrl()!} target="_blank" rel="noopener">
                  Open PDF
                </a>
                <button class="button" onClick={() => setMode("svg")}>
                  Show as SVG
                </button>
              </div>
            </div>
          </Match>
          <Match when={settings.renderMode === "pdf" && pdfUrl()}>
            <iframe class="pdf-frame" src={pdfUrl()!} title="PDF preview" />
          </Match>
          <Match when={settings.renderMode === "html" && ws.state.html !== null}>
            <iframe
              class="html-frame white"
              sandbox="allow-popups allow-scripts"
              srcdoc={htmlPage(ws.state.html!)}
              title="HTML preview"
              ref={htmlFrame}
              onLoad={(e) => postFonts(e.currentTarget)}
            />
          </Match>
        </Switch>
      </div>
      {/* Like the Mac app's floating bar: a glass capsule at the bottom, shown while the pointer is over the preview. */}
      <div class="floating-bar glass-capsule">
        <Show when={zoomable()}>
          <button class="icon-button" title="Zoom out" onClick={() => step(-1)}>
            <ZoomOut size={15} />
          </button>
          <button class="zoom-label" title="Fit width" onClick={() => setZoom("fit")}>
            {zoom() === "fit" ? "Fit" : `${Math.round((zoom() as number) * 100)}%`}
          </button>
          <button class="icon-button" title="Zoom in" onClick={() => step(1)}>
            <ZoomIn size={15} />
          </button>
          <span class="bar-label">
            {page() + 1} / {ws.state.svgPages!.length}
          </span>
        </Show>
        <Show when={ws.state.compiling}>
          <div class="spinner small" aria-label="Compiling" />
        </Show>
        <Show when={zoomable() || ws.state.compiling}>
          <span class="bar-separator" />
        </Show>
        <Show when={isTypst() && settings.renderMode === "html"}>
          <button
            class="icon-button"
            classList={{ active: settings.previewDark }}
            title={settings.previewDark ? "Show pages light" : "Show pages dark"}
            aria-pressed={settings.previewDark}
            onClick={() => setSettings("previewDark", (v) => !v)}
          >
            <Show when={settings.previewDark} fallback={<Moon size={15} />}>
              <Sun size={15} />
            </Show>
          </button>
        </Show>
        <button class="icon-button" title="More" onClick={(e) => showMenu(e, moreMenu())}>
          <Ellipsis size={15} />
        </button>
      </div>
    </section>
  );
}
