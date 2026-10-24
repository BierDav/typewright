import { createEffect, createMemo, createResource, createSignal, For, Match, on, onCleanup, Show, Switch } from "solid-js";
import * as commands from "~/lib/commands";
import { compiler } from "~/lib/compiler";
import { isDark, type RenderMode, setSettings, settings } from "~/lib/settings";
import type { Workspace } from "~/lib/workspace";
import { isMarkdown, isPreviewable } from "~/lib/kinds";
import { basename } from "~/lib/storage";
import { ChevronDown, EyeOff, FileDown, ZoomIn, ZoomOut } from "./icons";

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
  const head = /<head[^>]*>/i.exec(html);
  if (!head) return FONT_SCRIPT + html;
  const at = head.index + head[0].length;
  return html.slice(0, at) + FONT_SCRIPT + html.slice(at);
}

// Mobile browsers have no inline PDF viewer and leave the frame blank.
const canShowPdf = typeof navigator === "undefined" || navigator.pdfViewerEnabled !== false;

export default function PreviewPane(props: { workspace: Workspace }) {
  const ws = props.workspace;
  const [markdownCss] = createResource(() => compiler.markdownCss().catch(() => ""));
  let scroller!: HTMLDivElement;
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
    const first = ws.state.svgPages?.[0];
    const pt = first ? Number(/viewBox="[\d.]+ [\d.]+ ([\d.]+)/.exec(first)?.[1] ?? 595) : 595;
    return Math.max((width() - 48) / pt, 0.1);
  });

  function step(delta: number) {
    const current = zoom() === "fit" ? scale() / (96 / 72) : (zoom() as number);
    const next = delta > 0 ? ZOOMS.find((z) => z > current + 0.001) : [...ZOOMS].reverse().find((z) => z < current - 0.001);
    if (next) setZoom(next);
  }

  /** A click on a page jumps to the source that made it. */
  async function click(event: MouseEvent, index: number) {
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

  function scrollTo(position: { page: number; x: number; y: number }, onlyIfHidden = false) {
    const pageEl = scroller?.querySelectorAll<HTMLElement>(".svg-page")[position.page];
    if (!pageEl) return;
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

  function onScroll() {
    const pages = scroller.querySelectorAll<HTMLElement>(".svg-page");
    let index = 0;
    pages.forEach((p, i) => {
      if (p.offsetTop - scroller.scrollTop < scroller.clientHeight / 2) index = i;
    });
    setPage(index);
  }

  function setMode(mode: RenderMode) {
    if (mode === settings.renderMode) return;
    setSettings("renderMode", mode);
    ws.setRenderMode();
  }

  const file = () => ws.state.preview;
  const errors = () => ws.state.diagnostics.filter((d) => d.severity === "error").length;

  return (
    <section class="preview">
      <header class="pane-header">
        <div class="preview-title">
          <select class="plain-select" onChange={(e) => ws.setPreview(e.currentTarget.value || null)} title="Previewed file">
            <option value="" selected={!file()}>No Preview</option>
            {/* `selected` per option, as a `value` on the select is set before its options exist. */}
            <For each={previewable()}>{(f) => <option value={f.path} selected={f.path === file()}>{f.path}</option>}</For>
          </select>
          <ChevronDown size={12} />
        </div>
        <div class="spacer" />
        <Show when={file() && !isMarkdown(file()!)}>
          <div class="segmented" role="radiogroup" aria-label="Render as">
            <For each={["pdf", "html", "svg"] as RenderMode[]}>
              {(mode) => (
                <button classList={{ active: settings.renderMode === mode }} onClick={() => setMode(mode)}>
                  {mode.toUpperCase()}
                </button>
              )}
            </For>
          </div>
        </Show>
        <Show when={settings.renderMode === "svg" && ws.state.svgPages}>
          <button class="icon-button" title="Zoom out" onClick={() => step(-1)}>
            <ZoomOut size={15} />
          </button>
          <button class="zoom-label" title="Fit width" onClick={() => setZoom("fit")}>
            {zoom() === "fit" ? "Fit" : `${Math.round((zoom() as number) * 100)}%`}
          </button>
          <button class="icon-button" title="Zoom in" onClick={() => step(1)}>
            <ZoomIn size={15} />
          </button>
        </Show>
        <Show when={file()?.endsWith(".typ")}>
          <button class="icon-button" title="Export PDF" onClick={() => void commands.exportPDF()}>
            <FileDown size={15} />
          </button>
        </Show>
        <button class="icon-button" title="Hide preview" onClick={() => setSettings("split", 0)}>
          <EyeOff size={15} />
        </button>
      </header>
      <div class="preview-body" classList={{ stale: ws.state.compiling }}>
        <Switch
          fallback={
            <div class="empty-state">
              <Show when={file()} fallback={<p>Choose a Typst or Markdown file to preview.</p>}>
                <Show when={ws.state.failure} fallback={<p class="secondary">Compiling…</p>}>
                  <p class="title">Couldn't compile {basename(file()!)}</p>
                  <p class="secondary">{ws.state.failure}</p>
                </Show>
                <Show when={errors() > 0 && !ws.state.failure}>
                  <button class="link-button" onClick={() => ws.revealDiagnostic(ws.state.diagnostics[0])}>
                    {errors()} {errors() === 1 ? "error" : "errors"}; show the first
                  </button>
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
              <For each={ws.state.svgPages!}>
                {(svg, index) => (
                  <div
                    class="svg-page"
                    style={{ width: `${(Number(/viewBox="[\d.]+ [\d.]+ ([\d.]+)/.exec(svg)?.[1] ?? 595) * scale()).toFixed(1)}px` }}
                    innerHTML={svg}
                    onClick={(e) => void click(e, index())}
                  />
                )}
              </For>
              <Show when={marker()}>
                {(m) => {
                  const pageEl = () => scroller?.querySelectorAll<HTMLElement>(".svg-page")[m().page];
                  return (
                    <Show when={pageEl()}>
                      <div class="jump-marker" style={{ top: `${pageEl()!.offsetTop + m().y * scale()}px`, left: `${pageEl()!.offsetLeft + m().x * scale()}px` }} />
                    </Show>
                  );
                }}
              </Show>
            </div>
            <div class="page-indicator">
              Page {page() + 1} of {ws.state.svgPages!.length}
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
    </section>
  );
}
