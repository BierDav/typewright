// One open space: its files, buffers, autosave, compilation and previews, like the Mac app's `Workspace`.
import { batch, createRoot, createSignal, type Accessor } from "solid-js";
import { createStore, produce, reconcile } from "solid-js/store";
import { compiler, Format, type CompileOutput, type DiagnosticJSON } from "./compiler";
import { spaceRelativePath } from "./core";
import { Solveng } from "./editor/solveng";
import { sharedFontFiles } from "./fonts";
import { isFont, isMarkdown, isPreviewable, kindOf, kindWithContents, type Kind } from "./kinds";
import { settings } from "./settings";
import { spacePath, uniqueName } from "./spaces";
import * as fs from "./storage";
import * as syncService from "./sync";
import { showRecentlyDeleted, toast } from "./app";
import { FileUndo } from "./fileops";
import * as jj from "./jj";

/** An image saved for a paste or drop in the editor, with the text that shows it. */
type PastedImage = { path: string; document: string; reference: string; removed?: jj.DeletedItem[]; pending?: boolean };

export type FileNode = { path: string; name: string; kind: Kind; children?: FileNode[] };

export type Diagnostic = DiagnosticJSON & { fromPackage: boolean };

export type EditorState = { anchor: number; head: number; scroll: number };

type SpaceState = {
  selected?: string | null;
  preview?: string | null;
  expanded?: string[];
  editors?: Record<string, EditorState>;
};

/** A request to show a place in the editor, e.g. from a diagnostic, search result or definition. */
export type Reveal = { path: string; from: number; to?: number; line?: number; column?: number; id: number };

const STATE_KEY = (folder: string) => `typewright.space.${folder}`;
let revealCounter = 0;

export class Workspace {
  readonly folder: string;
  readonly root: string;
  readonly state;
  private readonly setState;
  /** Unsaved texts by path relative to the space. */
  private buffers = new Map<string, string>();
  private dirty = new Set<string>();
  private autosave: ReturnType<typeof setTimeout> | undefined;
  private compileTimer: ReturnType<typeof setTimeout> | undefined;
  private compileRunning = false;
  private compileQueued = false;
  private generation = 0;
  private disposers: (() => void)[] = [];
  private editorStates: Record<string, EditorState>;
  private closed = false;
  /** Bumped when the selected file changed outside its editor, so the editor reloads it. */
  readonly external: Accessor<number>;
  private setExternal: (v: number) => void;
  /** Set by the editor; the selected text and selection. */
  currentText: () => string = () => this.state.text;
  /** Settles once the space's files are listed and its first file is selected. */
  readonly loaded: Promise<void>;
  /** File tree changes and their undo (⌘Z in the file sidebar). */
  readonly fileUndo: FileUndo;
  private pastedImages: PastedImage[] = [];
  private finishLoading!: () => void;

  constructor(folder: string) {
    this.folder = folder;
    this.root = spacePath(folder);
    const saved = this.loadState();
    this.editorStates = saved?.editors ?? {};
    const [state, setState] = createStore({
      tree: [] as FileNode[],
      selected: null as string | null,
      selectedKind: null as Kind | null,
      text: "",
      preview: (saved?.preview ?? null) as string | null,
      expanded: saved?.expanded ?? ([] as string[]),
      svgPages: null as string[] | null,
      pdf: null as Uint8Array | null,
      html: null as string | null,
      markdownHtml: null as string | null,
      diagnostics: [] as Diagnostic[],
      /** Problems solveng finds in the shown file while typing, like unknown units. */
      solvengDiagnostics: [] as { from: number; to: number; message: string; severity: "error" | "warning" }[],
      /** solveng's report from the last compile, which says what it calculates where. */
      solvengReport: "",
      /** solveng's report on the shown file compiled on its own, when it isn't the previewed one. */
      solvengFileReport: null as { path: string; report: string } | null,
      packageErrors: [] as string[],
      failure: null as string | null,
      compiling: false,
      duration: null as number | null,
      reveal: null as Reveal | null,
      selection: { from: 0, to: 0 },
      fontFamilies: [] as string[],
      loaded: false,
    });
    this.state = state;
    this.setState = setState;
    this.fileUndo = new FileUndo(this);
    const [external, setExternal] = createRoot(() => createSignal(0));
    this.external = external;
    this.setExternal = setExternal;
    this.disposers.push(
      fs.onChange(({ paths }) => {
        const mine = paths.filter((p) => p === this.root || p.startsWith(`${this.root}/`));
        if (mine.length) void this.refreshFromDisk(mine.map((p) => p.slice(this.root.length + 1)));
      }),
      syncService.onWillChange((f) => (f === this.folder ? this.flushSaves() : undefined)),
    );
    // Edits wait for autosave; leaving the page must not lose them.
    const hide = () => {
      if (document.visibilityState === "hidden") void this.flushSaves();
    };
    const leave = () => void this.flushSaves();
    document.addEventListener("visibilitychange", hide);
    addEventListener("pagehide", leave);
    this.disposers.push(
      () => document.removeEventListener("visibilitychange", hide),
      () => removeEventListener("pagehide", leave),
    );
    this.loaded = new Promise((resolve) => (this.finishLoading = resolve));
    void this.start(saved).finally(() => this.finishLoading());
  }

  get name(): string {
    return this.folder;
  }

  private async start(saved: SpaceState | null) {
    compiler.clear();
    await this.reloadTree();
    await this.loadAllIntoCompiler();
    await this.updateFonts();
    const initial = (saved?.selected && this.exists(saved.selected) ? saved.selected : null) ?? this.defaultMain();
    if (initial) await this.select(initial);
    // New spaces start out previewing their main file; known ones keep their choice, even none.
    if (!saved) this.setState("preview", initial && initial.endsWith(".typ") ? initial : this.defaultMain());
    else if (this.state.preview && !this.exists(this.state.preview)) this.setState("preview", null);
    this.setState("loaded", true);
    this.scheduleCompile(0);
  }

  dispose() {
    this.closed = true;
    void this.flushSaves();
    this.persist();
    this.disposers.forEach((d) => d());
    clearTimeout(this.compileTimer);
    clearTimeout(this.checkTimer);
  }

  // MARK: - Files

  private exists(path: string): boolean {
    return flatten(this.state.tree).some((n) => n.path === path);
  }

  files(): FileNode[] {
    return flatten(this.state.tree).filter((n) => !n.children);
  }

  folders(): FileNode[] {
    return flatten(this.state.tree).filter((n) => n.children);
  }

  private defaultMain(): string | null {
    if (this.exists("main.typ")) return "main.typ";
    return this.files().find((n) => n.kind === "typst")?.path ?? null;
  }

  async reloadTree() {
    const entries = await fs.walk(this.root);
    const tree = buildTree(entries.filter((e) => !e.path.split("/").some((p) => p.startsWith(".")) && !e.path.endsWith(".crswap")));
    this.setState("tree", reconcile(tree, { key: "path" }));
  }

  /** Hands every typst-relevant file to the compiler: sources, data, images and fonts. */
  private async loadAllIntoCompiler() {
    for (const node of this.files()) {
      if (node.kind === "binary" && !isFont(node.path)) continue;
      await this.loadIntoCompiler(node.path);
    }
  }

  private async loadIntoCompiler(path: string) {
    const buffer = this.buffers.get(path);
    if (buffer !== undefined) return compiler.setText(path, buffer);
    const bytes = await fs.readFile(fs.join(this.root, path));
    if (bytes) compiler.setFile(path, bytes);
    else compiler.removeFile(path);
  }

  /** Fonts of the space's font folders, then the shared ones. */
  async updateFonts() {
    const own: Uint8Array[] = [];
    for (const folder of settings.spaceFontPaths) {
      const dir = fs.join(this.root, folder);
      for (const entry of await fs.walk(dir)) {
        if (entry.kind === "file" && isFont(entry.path)) {
          const bytes = await fs.readFile(fs.join(dir, entry.path));
          if (bytes) own.push(bytes);
        }
      }
    }
    await compiler.setFonts([...own, ...(await sharedFontFiles())]);
    this.setState("fontFamilies", await compiler.fontFamilies());
    this.scheduleCompile(0);
  }

  async select(path: string) {
    if (path === this.state.selected) return;
    let kind = kindOf(path);
    if (kind === null) {
      const bytes = await fs.readFile(fs.join(this.root, path));
      kind = kindWithContents(path, !!bytes && fs.decodeText(bytes) !== null);
    }
    if (kind === "folder") return;
    await this.flushSaves();
    let text = "";
    if (kind === "typst" || kind === "text") {
      text = this.buffers.get(path) ?? (await fs.readText(fs.join(this.root, path))) ?? "";
      this.buffers.set(path, text);
    }
    batch(() => {
      this.setState({ selected: path, selectedKind: kind, text, solvengDiagnostics: [] });
      this.scheduleSolvengCheck(0);
      // Opening a file inside collapsed folders shows it in the sidebar.
      const parents = ancestors(path);
      if (parents.some((p) => !this.state.expanded.includes(p))) {
        this.setState("expanded", (all) => [...new Set([...all, ...parents])]);
      }
    });
    this.persist();
  }

  togglePreview(path: string) {
    this.setPreview(this.state.preview === path ? null : path);
  }

  setPreview(path: string | null) {
    if (path === this.state.preview) return;
    this.previewChosen = true;
    this.generation++;
    this.setState({ preview: path, svgPages: null, pdf: null, html: null, markdownHtml: null, diagnostics: [], failure: null, duration: null });
    this.persist();
    this.scheduleCompile(0);
  }

  setRenderMode() {
    this.generation++;
    this.setState({ svgPages: null, pdf: null, html: null });
    this.scheduleCompile(0);
  }

  revealAt(reveal: Omit<Reveal, "id">) {
    this.setState("reveal", { ...reveal, id: ++revealCounter });
  }

  async open(path: string, from = 0, to = from) {
    await this.select(path);
    this.revealAt({ path, from, to });
  }

  revealDiagnostic(d: Diagnostic) {
    if (d.fromPackage || !d.path) return;
    void this.select(d.path).then(() => this.revealAt({ path: d.path, from: 0, line: d.line, column: d.column }));
  }

  toggleExpanded(path: string) {
    this.setState("expanded", (all) => (all.includes(path) ? all.filter((p) => p !== path) : [...all, path]));
    this.persist();
  }

  editorState(path: string | null): EditorState | undefined {
    return path ? this.editorStates[path] : undefined;
  }

  saveEditorState(path: string, state: EditorState) {
    this.editorStates[path] = state;
    this.persistSoon();
  }

  setSelection(from: number, to: number) {
    this.setState("selection", { from, to });
  }

  // MARK: - Creating and moving

  /** `Space/path` for the repository and commit messages. */
  repoPath(path: string): string {
    return path ? `${this.folder}/${path}` : this.folder;
  }

  /** A repo-relative path back to one relative to the space. */
  spacePath(repoPath: string): string {
    return repoPath === this.folder ? "" : repoPath.slice(this.folder.length + 1);
  }

  async createFile(dir: string, typed: string): Promise<string> {
    // A name without an extension becomes a Typst file.
    const clean = typed.trim().replace(/\//g, "-");
    const dot = clean.lastIndexOf(".");
    const base = clean ? (dot > 0 ? clean.slice(0, dot) : clean) : "untitled";
    const ext = clean && dot > 0 ? clean.slice(dot + 1) : "typ";
    const name = await uniqueName(fs.join(this.root, dir), base, ext);
    const path = fs.join(dir, name);
    await fs.writeFile(fs.join(this.root, path), "");
    await this.reloadTree();
    await this.select(path);
    this.fileUndo.record("New File", { kind: "delete", paths: [path] }, `Add ${this.repoPath(path)}`);
    return path;
  }

  async createFolder(dir: string, typed: string): Promise<string> {
    const clean = typed.trim().replace(/\//g, "-") || "New Folder";
    const name = await uniqueName(fs.join(this.root, dir), clean);
    const path = fs.join(dir, name);
    await fs.makeDirectory(fs.join(this.root, path));
    if (dir) this.setState("expanded", (all) => [...new Set([...all, dir])]);
    await this.reloadTree();
    this.fileUndo.record("New Folder", { kind: "delete", paths: [path] }, `Add ${this.repoPath(path)}`);
    return path;
  }

  /** A copy next to the original, named like Finder's ("name copy.ext"). */
  async duplicate(path: string): Promise<string | null> {
    await this.flushSaves();
    const source = fs.join(this.root, path);
    const entry = await fs.stat(source);
    if (!entry) return null;
    const base = fs.basename(path);
    const dot = entry.kind === "file" ? base.lastIndexOf(".") : -1;
    const name = await uniqueName(fs.join(this.root, fs.dirname(path)), `${dot > 0 ? base.slice(0, dot) : base} copy`, dot > 0 ? base.slice(dot + 1) : null);
    const target = fs.join(fs.dirname(path), name);
    if (entry.kind === "file") await fs.copy(source, fs.join(this.root, target));
    else for (const e of await fs.walk(source)) if (e.kind === "file") await fs.copy(fs.join(source, e.path), fs.join(this.root, target, e.path));
    await this.reloadTree();
    if (entry.kind === "file") await this.select(target);
    this.fileUndo.record(`Duplicate “${base}”`, { kind: "delete", paths: [target] }, `Duplicate ${this.repoPath(path)} as ${this.repoPath(target)}`);
    return target;
  }

  canMove(path: string, dir: string): boolean {
    return dir !== fs.dirname(path) && dir !== path && !dir.startsWith(`${path}/`);
  }

  async rename(path: string, typed: string) {
    const name = typed.trim();
    if (!name || name.includes("/") || name === fs.basename(path)) return;
    const target = fs.join(fs.dirname(path), name);
    const caseOnly = target.toLowerCase() === path.toLowerCase();
    if (!caseOnly && (await fs.exists(fs.join(this.root, target)))) return;
    await this.relocate(path, target);
    this.fileUndo.record(`Rename “${fs.basename(path)}”`, { kind: "move", moves: [{ from: target, to: path }] },
      `Rename ${this.repoPath(path)} to ${this.repoPath(target)}`);
  }

  async move(path: string, dir: string) {
    if (!this.canMove(path, dir)) return;
    const target = fs.join(dir, fs.basename(path));
    if (await fs.exists(fs.join(this.root, target))) return;
    await this.relocate(path, target);
    this.fileUndo.record(`Move “${fs.basename(path)}”`, { kind: "move", moves: [{ from: target, to: path }] },
      `Move ${this.repoPath(path)} to ${this.repoPath(target)}`);
  }

  /** Undo's moves: no new undo step; false when the item is gone or its old place is taken. */
  async moveQuietly(from: string, to: string): Promise<boolean> {
    if (!(await fs.exists(fs.join(this.root, from)))) return false;
    if (to.toLowerCase() !== from.toLowerCase() && (await fs.exists(fs.join(this.root, to)))) return false;
    await this.relocate(from, to);
    return true;
  }

  /** Moves a file or folder and takes buffers, selection, preview and saved state along. */
  private async relocate(from: string, to: string) {
    await this.flushSaves();
    const moved = (p: string) => (p === from ? to : p.startsWith(`${from}/`) ? to + p.slice(from.length) : p);
    for (const [p, text] of [...this.buffers]) {
      this.buffers.delete(p);
      this.buffers.set(moved(p), text);
    }
    for (const p of Object.keys(this.editorStates)) {
      const state = this.editorStates[p];
      delete this.editorStates[p];
      this.editorStates[moved(p)] = state;
    }
    const live = this.state.selected;
    await fs.move(fs.join(this.root, from), fs.join(this.root, to));
    jj.noteMoved(this.repoPath(from), this.repoPath(to));
    batch(() => {
      if (live) this.setState("selected", moved(live));
      if (this.state.preview) this.setState("preview", moved(this.state.preview));
      this.setState("expanded", (all) => all.map(moved));
    });
    await this.reloadTree();
    compiler.clear();
    await this.loadAllIntoCompiler();
    this.persist();
    this.scheduleCompile(0);
  }

  /** Deletes and commits at once; there's no trash: undo, or Recently Deleted, brings it back from the history. */
  async delete(path: string) {
    const name = fs.basename(path);
    await this.fileUndo.perform({ kind: "delete", paths: [path] }, `Delete “${name}”`, `Delete ${this.repoPath(path)}`);
    toast(`Deleted “${name}”`, [
      { label: "Undo", run: () => void this.fileUndo.undo() },
      { label: "Show Recently Deleted", run: () => showRecentlyDeleted(this.repoPath(fs.dirname(path))) },
    ]);
  }

  /** The deletion itself, for `FileUndo`: what the history keeps, or null without a repository in this tab. */
  async deleteNow(paths: string[], message: string): Promise<jj.DeletedItem[] | null> {
    await this.flushSaves();
    let items: jj.DeletedItem[] | null = null;
    if (jj.isOpen()) items = await jj.deleteItems(paths.map((p) => this.repoPath(p)), message);
    // The tab running the repository commits the deletion; undo isn't possible from here.
    else for (const path of paths) await fs.remove(fs.join(this.root, path));
    await this.forgetRemoved(paths);
    return items;
  }

  private async forgetRemoved(paths: string[]) {
    const gone = (p: string) => paths.some((path) => p === path || p.startsWith(`${path}/`));
    for (const p of [...this.buffers.keys()]) if (gone(p)) this.buffers.delete(p);
    for (const p of [...this.dirty]) if (gone(p)) this.dirty.delete(p);
    batch(() => {
      if (this.state.selected && gone(this.state.selected)) this.setState({ selected: null, selectedKind: null, text: "" });
      if (this.state.preview && gone(this.state.preview)) this.setPreview(null);
    });
    for (const node of [...this.files()]) if (gone(node.path)) compiler.removeFile(node.path);
    await this.reloadTree();
    this.persist();
  }

  /** Files picked or dropped into a folder; text and images become available to typst at once. */
  async importFiles(dir: string, files: { path: string; file: Blob }[]) {
    const added = new Set<string>();
    for (const { path, file } of files) {
      const target = fs.join(this.root, dir, path);
      // Undo takes away what's new; files that were replaced keep their new content.
      const top = fs.join(dir, path.split("/")[0]);
      if (!added.has(top) && !(await fs.exists(fs.join(this.root, top)))) added.add(top);
      await fs.writeFile(target, new Uint8Array(await file.arrayBuffer()));
    }
    await this.reloadTree();
    if (!added.size) return;
    const names = [...added].map(fs.basename);
    this.fileUndo.record(names.length === 1 ? `Add “${names[0]}”` : `Add ${names.length} Items`, { kind: "delete", paths: [...added] },
      `Add ${[...added].map((p) => this.repoPath(p)).join(", ")}`);
  }

  /** Saves images pasted or dropped into the editor next to `document`; returns the text that shows them. */
  async saveImages(images: File[], document: string): Promise<string | null> {
    const markdown = isMarkdown(document);
    const dir = fs.dirname(document);
    const references: string[] = [];
    for (const image of images) {
      const type = image.type.split("/")[1]?.replace("jpeg", "jpg").replace("svg+xml", "svg") || "png";
      const stamp = new Date().toISOString().slice(0, 19).replace("T", "-").replace(/:/g, "");
      const given = image.name && image.name !== "image.png" ? image.name : `image-${stamp}.${type}`;
      const dot = given.lastIndexOf(".");
      const name = await uniqueName(fs.join(this.root, dir), dot > 0 ? given.slice(0, dot) : given, dot > 0 ? given.slice(dot + 1) : type);
      const path = fs.join(dir, name);
      await fs.writeFile(fs.join(this.root, path), new Uint8Array(await image.arrayBuffer()));
      await this.loadIntoCompiler(path);
      const reference = markdown ? `![](${name.includes(" ") ? `<${name}>` : name})` : `#image("${name.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}")`;
      references.push(reference);
      this.pastedImages = [...this.pastedImages, { path, document, reference }].slice(-20);
    }
    if (!references.length) return null;
    await this.reloadTree();
    void jj.commit(`Add ${this.pastedImages.slice(-references.length).map((i) => this.repoPath(i.path)).join(", ")}`);
    return references.join("\n");
  }

  /** Undo in the text took a pasted image's reference out: the image goes too; redo brings both back. */
  editorDidUndo(redo: boolean, text: string) {
    const document = this.state.selected;
    for (const image of this.pastedImages) {
      if (image.document !== document || image.pending) continue;
      const present = text.includes(image.reference);
      if (!redo && !present && !image.removed) {
        image.pending = true;
        void this.deleteNow([image.path], `Undo Add ${this.repoPath(image.path)}`).then((items) => {
          image.pending = false;
          image.removed = items ?? undefined;
        });
      } else if (redo && present && image.removed) {
        const items = image.removed;
        image.pending = true;
        void (async () => {
          for (const item of items) await jj.restoreDeleted(item, item.path);
          await this.reloadTree();
          await this.loadIntoCompiler(image.path);
          image.pending = false;
          image.removed = undefined;
        })();
      }
    }
  }

  // MARK: - Editing

  /** The editor's text changed; `immediate` (color wheel drags) compiles at once. */
  textDidChange(text: string, immediate = false) {
    const path = this.state.selected;
    if (!path) return;
    this.setState("text", text);
    this.buffers.set(path, text);
    this.dirty.add(path);
    if (this.state.selectedKind === "typst" || this.isCompilerFile(path)) compiler.setText(path, text);
    this.scheduleAutosave();
    // SVG only swaps changed pages, so it keeps up with every keystroke.
    this.scheduleCompile(settings.renderMode === "pdf" && !immediate ? 250 : 30);
  }

  /** Edits a file that may not be the selected one, e.g. from a refactoring or the search panel. */
  updateBuffer(path: string, text: string) {
    this.buffers.set(path, text);
    this.dirty.add(path);
    compiler.setText(path, text);
    if (path === this.state.selected) {
      this.setState("text", text);
      this.setExternal(this.external() + 1);
    }
    this.scheduleAutosave();
    this.scheduleCompile(30);
  }

  private solvengCache: { key: string; text: string } | null = null;
  /** Counts new solveng reports, for the cache key. */
  private solvengRevision = 0;

  /**
   * The files around the shown one, for solveng: the previewed main file and what it and the shown file import or
   * include, so a `worksheet`, `integration`, units and definitions set up elsewhere count here too.
   */
  async solvengContext(): Promise<string> {
    const file = this.state.selected;
    if (!file || this.state.selectedKind !== "typst") return "";
    const references = (text: string) => Solveng.references(text).catch(() => [] as string[]);
    const own = await references(this.state.text);
    const report = this.state.solvengReport;
    const fileReport = this.state.solvengFileReport?.path === file ? this.state.solvengFileReport.report : "";
    const key = JSON.stringify([file, this.state.preview, this.solvengRevision, own]);
    if (this.solvengCache?.key === key) return this.solvengCache.text;
    const resolve = (path: string, from: string) => {
      const parts: string[] = [];
      for (const p of fs.split(path.startsWith("/") ? path : fs.join(fs.dirname(from), path))) {
        if (p === "..") parts.pop();
        else parts.push(p);
      }
      return parts.join("/");
    };
    const queue = own.map((p) => resolve(p, file));
    const main = this.state.preview;
    if (main && main !== file && main.endsWith(".typ")) queue.unshift(main);
    const seen = new Set([file]);
    const parts: { path: string; text: string }[] = [];
    let size = 0;
    // Bounded, since a space can be large and imports can loop.
    while (queue.length && parts.length < 24 && size < 1_000_000) {
      const next = queue.shift()!;
      if (!next.endsWith(".typ") || seen.has(next)) continue;
      seen.add(next);
      const text = await this.bufferText(next);
      if (text === null) continue;
      parts.push({ path: next, text });
      size += text.length;
      queue.push(...(await references(text)).map((p) => resolve(p, next)));
    }
    // The compiler's report says for sure what solveng calculates here; reading the settings is the fallback.
    const text = Solveng.context(parts, report, file, file === this.state.preview, this.state.preview ?? "", fileReport);
    this.solvengCache = { key, text };
    return text;
  }

  private checkTimer: ReturnType<typeof setTimeout> | undefined;

  /** Compiles the shown file on its own for solveng's report when it isn't the previewed one; without one nothing is calculated. */
  private scheduleSolvengCheck(delay: number) {
    clearTimeout(this.checkTimer);
    this.checkTimer = setTimeout(() => void this.checkSolveng(), delay);
  }

  private async checkSolveng() {
    const file = this.state.selected;
    if (!file || this.state.selectedKind !== "typst" || file === this.state.preview || this.closed) return;
    const text = this.state.text;
    // A file that never mentions solveng has nothing to report.
    // A failed compile reports nothing and keeps the last report.
    const report = text.includes("solve") ? (await compiler.compile(file, Format.check).catch(() => null))?.solveng || null : "";
    if (report == null || file !== this.state.selected || this.closed) return;
    const last = this.state.solvengFileReport;
    if (last?.path === file && last.report === report) return;
    this.solvengRevision++;
    this.setState("solvengFileReport", { path: file, report });
    void this.updateSolvengDiagnostics();
  }

  /** Finds solveng's problems in the shown file, like unknown units. */
  async updateSolvengDiagnostics() {
    const file = this.state.selected;
    const text = this.state.text;
    const found =
      file && this.state.selectedKind === "typst" ? await Solveng.diagnostics(text, await this.solvengContext()).catch(() => []) : [];
    if (file !== this.state.selected || text !== this.state.text) return;
    this.setState(
      "solvengDiagnostics",
      found.map((p) => ({ from: p.start, to: p.end, message: p.message, severity: p.severity === "error" ? "error" : "warning" })),
    );
  }

  /** A file's text including unsaved edits. */
  async bufferText(path: string): Promise<string | null> {
    return this.buffers.get(path) ?? fs.readText(fs.join(this.root, path));
  }

  unsavedBuffers(): Map<string, string> {
    return new Map([...this.buffers].filter(([p]) => this.dirty.has(p) || p === this.state.selected));
  }

  private isCompilerFile(path: string): boolean {
    return compiler.hasFile(path);
  }

  /** Edits reach storage every 30 s and on switches; synced spaces save within a second so other devices keep up. */
  private scheduleAutosave() {
    if (this.autosave) return;
    const delay = syncService.syncsAnything(this.folder) ? 1000 : 30_000;
    this.autosave = setTimeout(() => void this.flushSaves(), delay);
  }

  async flushSaves() {
    clearTimeout(this.autosave);
    this.autosave = undefined;
    const pending = [...this.dirty];
    this.dirty.clear();
    for (const path of pending) {
      const text = this.buffers.get(path);
      if (text !== undefined) {
        this.selfWrites.add(path);
        await fs.writeFile(fs.join(this.root, path), text);
      }
    }
  }

  private selfWrites = new Set<string>();
  /** Set once the user picked a preview, even none, so arriving files don't override it. */
  private previewChosen = false;

  /** Picks up files changed elsewhere (sync, another tab), keeping files with pending edits. */
  private async refreshFromDisk(paths: string[]) {
    if (this.closed) return;
    const own = paths.filter((p) => this.selfWrites.delete(p));
    const changed = paths.filter((p) => !own.includes(p));
    if (changed.length === 0) return;
    this.solvengCache = null;
    const structural = changed.some((p) => !this.exists(p) || p === "");
    if (structural) await this.reloadTree();
    // A space joined from elsewhere opens empty; its main file shows once it arrives.
    const main = this.defaultMain();
    if (main && !this.state.selected) await this.select(main);
    if (main && !this.state.preview && !this.previewChosen) this.setPreview(main);
    for (const path of changed) {
      if (path === "") continue;
      const info = await fs.stat(fs.join(this.root, path));
      if (!info) {
        compiler.removeFile(path);
        this.buffers.delete(path);
        continue;
      }
      if (info.kind === "dir") {
        for (const node of this.files().filter((n) => n.path.startsWith(`${path}/`))) await this.loadIntoCompiler(node.path);
        continue;
      }
      if (this.dirty.has(path)) continue;
      this.buffers.delete(path);
      await this.loadIntoCompiler(path);
      if (path === this.state.selected && (this.state.selectedKind === "typst" || this.state.selectedKind === "text")) {
        const disk = (await fs.readText(fs.join(this.root, path))) ?? "";
        if (disk !== this.currentText()) {
          this.buffers.set(path, disk);
          this.setState("text", disk);
          this.setExternal(this.external() + 1);
        }
      }
      if (settings.spaceFontPaths.some((f) => path.startsWith(fs.join(f) + "/")) && isFont(path)) void this.updateFonts();
    }
    this.scheduleCompile(0);
  }

  // MARK: - Compilation

  scheduleCompile(delay: number) {
    this.scheduleSolvengCheck(Math.max(delay, 250));
    clearTimeout(this.compileTimer);
    this.compileTimer = setTimeout(() => void this.compile(), delay);
  }

  /** Never drops a running compile for a newer edit; one follow-up compile picks up everything typed meanwhile. */
  private async compile() {
    if (this.compileRunning) {
      this.compileQueued = true;
      return;
    }
    this.compileRunning = true;
    do {
      this.compileQueued = false;
      await this.compileOnce().catch((err) => this.setState({ failure: String(err?.message ?? err), compiling: false }));
    } while (this.compileQueued && !this.closed);
    this.compileRunning = false;
  }

  private async compileOnce() {
    const preview = this.state.preview;
    if (!preview || this.closed) return;
    const generation = this.generation;
    if (isMarkdown(preview)) {
      const started = performance.now();
      const html = await compiler.markdown((await this.bufferText(preview)) ?? "");
      if (generation === this.generation) this.setState({ markdownHtml: html, duration: performance.now() - started });
      return;
    }
    if (!isPreviewable(preview)) return;
    const mode = settings.renderMode;
    this.setState("compiling", true);
    const result = await compiler.compile(preview, Format[mode]);
    this.setState("compiling", false);
    if (generation !== this.generation || this.closed) return;
    this.apply(result, mode);
  }

  private apply(result: CompileOutput, mode: "pdf" | "html" | "svg") {
    const diagnostics = result.diagnostics
      .map((d) => ({ ...d, fromPackage: d.path.startsWith("@") }))
      .filter((d) => !(settings.ignoreLibraryWarnings && d.fromPackage && d.severity === "warning"));
    batch(() => {
      this.setState({
        diagnostics,
        packageErrors: result.packageErrors,
        duration: result.duration,
        failure: !result.data && diagnostics.length === 0 ? (result.packageErrors[0] ?? "Compilation failed.") : null,
      });
      // A failed compile keeps the last report.
      if (result.solveng && result.solveng !== this.state.solvengReport) {
        this.solvengRevision++;
        this.setState("solvengReport", result.solveng);
      }
      void this.updateSolvengDiagnostics();
      if (!result.data) return;
      if (mode === "pdf") this.setState("pdf", result.data);
      else if (mode === "html") this.setState("html", new TextDecoder().decode(result.data));
      else this.setState("svgPages", splitPages(result.data));
    });
  }

  /** A PDF of the previewed file, compiling one if the preview isn't a PDF. */
  async exportPDF(): Promise<Uint8Array | string> {
    const preview = this.state.preview;
    if (!preview || !preview.endsWith(".typ")) return "Choose a Typst file to preview first.";
    const result = await compiler.compile(preview, Format.pdf);
    if (!result.data) return result.diagnostics.find((d) => d.severity === "error")?.message ?? "Compilation failed.";
    // The SVG preview's document stays the last compiled one for jumps.
    if (settings.renderMode !== "pdf") this.scheduleCompile(0);
    return result.data;
  }

  // MARK: - Usages

  /** Places that import, include or read the file, from other typst files. */
  async fileUsages(target: string): Promise<{ path: string; line: number; from: number; preview: string }[]> {
    const out: { path: string; line: number; from: number; preview: string }[] = [];
    const name = fs.basename(target);
    for (const node of this.files().filter((n) => n.kind === "typst" && n.path !== target)) {
      const text = (await this.bufferText(node.path)) ?? "";
      const dir = fs.dirname(node.path);
      const pattern = /"([^"\n]+)"/g;
      for (let m = pattern.exec(text); m; m = pattern.exec(text)) {
        const literal = m[1];
        if (!literal.endsWith(name)) continue;
        const resolved = literal.startsWith("/") ? fs.join(literal) : normalize(fs.join(dir, literal));
        if (resolved !== target) continue;
        const lineStart = text.lastIndexOf("\n", m.index) + 1;
        const lineEnd = text.indexOf("\n", m.index);
        out.push({
          path: node.path,
          line: text.slice(0, m.index).split("\n").length,
          from: m.index + 1,
          preview: text.slice(lineStart, lineEnd < 0 ? undefined : lineEnd).trim(),
        });
      }
    }
    return out;
  }

  // MARK: - State

  private loadState(): SpaceState | null {
    try {
      return JSON.parse(localStorage.getItem(STATE_KEY(this.folder)) ?? "null");
    } catch {
      return null;
    }
  }

  private persistTimer: ReturnType<typeof setTimeout> | undefined;

  private persistSoon() {
    clearTimeout(this.persistTimer);
    this.persistTimer = setTimeout(() => this.persist(), 1000);
  }

  persist() {
    const state: SpaceState = {
      selected: this.state.selected,
      preview: this.state.preview,
      expanded: [...this.state.expanded],
      editors: this.editorStates,
    };
    localStorage.setItem(STATE_KEY(this.folder), JSON.stringify(state));
  }

  /** Moves the saved view state along with a renamed space. */
  static renameState(old: string, folder: string) {
    const saved = localStorage.getItem(STATE_KEY(old));
    if (saved) localStorage.setItem(STATE_KEY(folder), saved);
    localStorage.removeItem(STATE_KEY(old));
  }

  relative(path: string): string | null {
    return spaceRelativePath(path, this.root) ?? null;
  }

  mutate(fn: (state: typeof this.state) => void) {
    this.setState(produce(fn));
  }
}

function splitPages(data: Uint8Array): string[] {
  const pages: string[] = [];
  const decoder = new TextDecoder();
  let start = 0;
  for (let i = 0; i <= data.length; i++) {
    if (i === data.length || data[i] === 0) {
      pages.push(decoder.decode(data.subarray(start, i)));
      start = i + 1;
    }
  }
  return pages;
}

function ancestors(path: string): string[] {
  const parts = path.split("/");
  return parts.slice(0, -1).map((_, i) => parts.slice(0, i + 1).join("/"));
}

function normalize(path: string): string {
  const out: string[] = [];
  for (const part of path.split("/")) {
    if (part === "..") out.pop();
    else if (part && part !== ".") out.push(part);
  }
  return out.join("/");
}

export function flatten(nodes: FileNode[]): FileNode[] {
  return nodes.flatMap((n) => [n, ...flatten(n.children ?? [])]);
}

function buildTree(entries: fs.Entry[]): FileNode[] {
  const root: FileNode[] = [];
  const dirs = new Map<string, FileNode>();
  const sorted = [...entries].sort((a, b) => a.path.split("/").length - b.path.split("/").length);
  for (const entry of sorted) {
    const name = fs.basename(entry.path);
    const node: FileNode =
      entry.kind === "dir" ? { path: entry.path, name, kind: "folder", children: [] } : { path: entry.path, name, kind: kindOf(entry.path) ?? "text" };
    if (entry.kind === "dir") dirs.set(entry.path, node);
    const parent = fs.dirname(entry.path);
    (parent ? (dirs.get(parent)?.children ?? root) : root).push(node);
  }
  const sort = (nodes: FileNode[]) => {
    nodes.sort((a, b) => (!!a.children === !!b.children ? a.name.localeCompare(b.name, undefined, { numeric: true }) : a.children ? -1 : 1));
    nodes.forEach((n) => n.children && sort(n.children));
  };
  sort(root);
  return root;
}
