// Talks to the typst worker. It mirrors the files and fonts it handed over, so a worker whose
// module trapped (typst panicked) is replaced without the page noticing.
import TypstWorker from "~/workers/typst.worker.ts?worker";

export type DiagnosticJSON = { path: string; line: number; column: number; length?: number | null; severity: "error" | "warning"; message: string };

/** One SVG page; pages with the same layout are the same object, so the preview keeps their DOM. */
export type SvgPage = { key: string; svg: string; width: number; height: number };

export type CompileOutput = {
  data: Uint8Array | null;
  /** The pages of an SVG compile. */
  pages: SvgPage[] | null;
  diagnostics: DiagnosticJSON[];
  packageErrors: string[];
  duration: number;
  /** solveng's report if the compile produced a document (empty otherwise), see the typst bridge's `solveng_report`. */
  solveng: string;
};

/** A font face the HTML preview registers, as browsers only know installed fonts. */
export type FontFaceData = { family: string; weight: number; italic: boolean; data: Uint8Array };

export type Completion = { kind: string; label: string; apply?: string | null; detail?: string | null };
export type Location = { path: string; package?: boolean; from: number; to: number } | { std: string | null };
export type Jump = { path: string; offset: number } | { url: string } | { page: number; x: number; y: number };

/** `check` lays out without output, for solveng's report. */
export const Format = { pdf: 0, html: 1, svg: 2, check: 3 } as const;

type Pending = { resolve: (value: any) => void; reject: (err: Error) => void; op: string };

class CompilerClient {
  private worker: Worker | null = null;
  private pending = new Map<number, Pending>();
  private nextId = 1;
  private files = new Map<string, Uint8Array | string>();
  private fonts: Uint8Array[] = [];
  private index: string | null = null;
  /** The pages the worker's bridge sent last, by hash; it only sends the ones missing here. */
  private svgPages = new Map<string, SvgPage>();
  version = "";

  private start(): Worker {
    const worker = new TypstWorker();
    worker.onmessage = (event: MessageEvent) => {
      const { id, ok, value, error, fatal } = event.data;
      const pending = this.pending.get(id);
      this.pending.delete(id);
      if (ok) pending?.resolve(value);
      else pending?.reject(new Error(error));
      if (fatal) this.restart();
    };
    worker.onerror = (event) => console.error("Typst worker:", event.message);
    this.worker = worker;
    // Replays what the previous worker knew.
    for (const [path, content] of this.files) {
      if (typeof content === "string") this.post({ op: "setText", path, text: content });
      else this.post({ op: "setFile", path, bytes: content });
    }
    if (this.fonts.length) this.post({ op: "setFonts", files: this.fonts });
    void this.post({ op: "version" }).then((v) => (this.version = v));
    return worker;
  }

  private restart() {
    const old = this.worker;
    this.worker = null;
    old?.terminate();
    for (const [id, pending] of this.pending) {
      pending.reject(new Error("typst crashed"));
      this.pending.delete(id);
    }
    this.start();
  }

  private post(message: Record<string, unknown>, transfer: Transferable[] = []): Promise<any> {
    const worker = this.worker ?? this.start();
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, op: String(message.op) });
      worker.postMessage({ id, ...message }, transfer);
    });
  }

  /** Starts the worker early; the module is large. */
  warmUp() {
    if (!this.worker) this.start();
  }

  clear() {
    this.files.clear();
    void this.post({ op: "clear" });
  }

  setFile(path: string, bytes: Uint8Array) {
    this.files.set(path, bytes);
    void this.post({ op: "setFile", path, bytes });
  }

  setText(path: string, text: string) {
    if (this.files.get(path) === text) return;
    this.files.set(path, text);
    void this.post({ op: "setText", path, text });
  }

  removeFile(path: string) {
    if (!this.files.delete(path)) return;
    void this.post({ op: "removeFile", path });
  }

  hasFile(path: string): boolean {
    return this.files.has(path);
  }

  setFonts(files: Uint8Array[]): Promise<number> {
    this.fonts = files;
    return this.post({ op: "setFonts", files });
  }

  fontFamilies(): Promise<string[]> {
    return this.post({ op: "fontFamilies" });
  }

  /** The faces of the files given to `setFonts`, by index into them. */
  fontFaces(): Promise<{ file: number; family: string; weight: number; italic: boolean }[]> {
    return this.post({ op: "fontFaces" });
  }

  async compile(main: string, format: number): Promise<CompileOutput> {
    const result = await this.post({ op: "compile", main, format });
    let pages: SvgPage[] | null = null;
    if (result.pages) {
      pages = this.applySvgUpdates(result.pages);
      // Out of step with the bridge (a crashed worker or a dropped reply): have it send every page again.
      if (!pages) {
        await this.post({ op: "resetSvg" });
        return this.compile(main, format);
      }
    }
    return { ...result, pages, diagnostics: JSON.parse(result.diagnostics) };
  }

  private applySvgUpdates(updates: { key: string; svg: string | null }[]): SvgPage[] | null {
    const next = new Map<string, SvgPage>();
    const pages: SvgPage[] = [];
    for (const { key, svg } of updates) {
      let page = next.get(key) ?? this.svgPages.get(key);
      if (!page && svg !== null) {
        const box = /viewBox="[-\d.]+ [-\d.]+ ([\d.]+) ([\d.]+)"/.exec(svg.slice(0, 400));
        page = { key, svg, width: Number(box?.[1] ?? 595), height: Number(box?.[2] ?? 842) };
      }
      if (!page) return null;
      next.set(key, page);
      pages.push(page);
    }
    this.svgPages = next;
    return pages;
  }

  complete(path: string, cursor: number, explicit: boolean): Promise<{ from: number; items: Completion[] } | null> {
    return this.post({ op: "complete", path, cursor, explicit });
  }

  tooltip(path: string, cursor: number): Promise<{ kind: "text" | "code"; value: string } | null> {
    return this.post({ op: "tooltip", path, cursor });
  }

  definition(path: string, cursor: number): Promise<Location | null> {
    return this.post({ op: "definition", path, cursor });
  }

  jumpFromClick(page: number, x: number, y: number): Promise<Jump | null> {
    return this.post({ op: "jumpFromClick", page, x, y });
  }

  jumpFromCursor(path: string, cursor: number): Promise<{ page: number; x: number; y: number }[]> {
    return this.post({ op: "jumpFromCursor", path, cursor });
  }

  /** solveng's editor support (`solveng-ide` through the typst bridge), see `typstBridge/src/solveng.rs`. */
  solveng<T>(action: string, document: string, context = "", offset = 0): Promise<T> {
    return this.post({ op: "solveng", action, document, context, offset });
  }

  highlight(text: string, code = false): Promise<Uint32Array> {
    return this.post({ op: "highlight", text, code });
  }

  refactor(request: Record<string, unknown>): Promise<any> {
    return this.post({ op: "refactor", request });
  }

  markdown(text: string): Promise<string> {
    return this.post({ op: "markdown", text });
  }

  markdownCss(): Promise<string> {
    return this.post({ op: "markdownCss" });
  }

  /** Typst Universe's package list, which also feeds import completions. */
  async packageIndex(): Promise<{ name: string; version: string; description?: string }[]> {
    this.index ??= await this.post({ op: "packageIndex" });
    return JSON.parse(this.index!);
  }

  installedPackages(): Promise<string[]> {
    return this.post({ op: "installedPackages" });
  }

  downloadPackage(spec: string): Promise<string> {
    return this.post({ op: "downloadPackage", spec });
  }

  removePackage(spec: string): Promise<void> {
    return this.post({ op: "removePackage", spec });
  }

  /** Lets packages that failed to download be tried again. */
  retryPackages(): Promise<void> {
    return this.post({ op: "retryPackages" });
  }
}

export const compiler = new CompilerClient();
