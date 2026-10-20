import { createResource, createSignal, Match, onCleanup, Show, Switch } from "solid-js";
import { mimeType } from "~/lib/kinds";
import { download } from "~/lib/spaces";
import * as fs from "~/lib/storage";
import type { Workspace } from "~/lib/workspace";
import { Download } from "./icons";

const SAMPLE = "The quick brown fox jumps over the lazy dog 0123456789";

/** Shows the selected file when it isn't text: images, PDFs and fonts, or offers it as a download. */
export default function FileViewer(props: { workspace: Workspace; path: string }) {
  const ws = props.workspace;
  let family = "";
  const [url] = createResource(
    () => props.path,
    async (path) => {
      const file = await fs.readBlob(fs.join(ws.root, path));
      if (!file) return null;
      return URL.createObjectURL(new Blob([await file.arrayBuffer()], { type: mimeType(path) }));
    },
  );
  const [font] = createResource(
    () => (ws.state.selectedKind === "font" ? props.path : null),
    async (path) => {
      const bytes = await fs.readFile(fs.join(ws.root, path));
      if (!bytes) return null;
      family = `preview-${Math.random().toString(36).slice(2)}`;
      const face = new FontFace(family, bytes as Uint8Array<ArrayBuffer>);
      await face.load();
      document.fonts.add(face);
      return face;
    },
  );
  const [size, setSize] = createSignal(40);
  onCleanup(() => {
    const u = url();
    if (u) URL.revokeObjectURL(u);
    const f = font();
    if (f) document.fonts.delete(f);
  });

  async function save() {
    const bytes = await fs.readFile(fs.join(ws.root, props.path));
    if (bytes) download(fs.basename(props.path), bytes, mimeType(props.path));
  }

  return (
    <div class="file-viewer">
      <Switch
        fallback={
          <div class="empty-state">
            <p class="title">{fs.basename(props.path)}</p>
            <p class="secondary">This kind of file can't be shown here.</p>
            <button class="button" onClick={() => void save()}>
              <Download size={14} /> Download
            </button>
          </div>
        }
      >
        <Match when={ws.state.selectedKind === "image" && url()}>
          <div class="image-view">
            <img src={url()!} alt={fs.basename(props.path)} />
          </div>
        </Match>
        <Match when={ws.state.selectedKind === "pdf" && url()}>
          <iframe class="pdf-frame" src={url()!} title={fs.basename(props.path)} />
        </Match>
        <Match when={ws.state.selectedKind === "font"}>
          <Show when={font()} fallback={<div class="empty-state secondary">{font.error ? "This font can't be shown." : "Loading…"}</div>}>
            <div class="font-view" style={{ "font-family": family }}>
              <input type="range" min="12" max="120" value={size()} onInput={(e) => setSize(Number(e.currentTarget.value))} aria-label="Size" />
              <p style={{ "font-size": `${size()}px` }} contentEditable>
                {SAMPLE}
              </p>
              <p style={{ "font-size": `${Math.round(size() * 0.5)}px` }}>ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz</p>
              <p class="secondary font-meta">{font()!.family !== family ? font()!.family : fs.basename(props.path)}</p>
            </div>
          </Show>
        </Match>
      </Switch>
    </div>
  );
}
