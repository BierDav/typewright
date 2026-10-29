//! Interface for the web app, which runs it in a worker: the page hands over the space's files, the
//! packages a compile asked for (`missing`) and font files; typst-ide answers completions, hovers,
//! definitions and jumps between source and preview.

use std::collections::{HashMap, HashSet};
use std::num::NonZeroUsize;
use std::str::FromStr;
use std::sync::{Arc, LazyLock};

use parking_lot::Mutex;
use serde::Serialize;
use serde_json::json;
use typst::diag::{FileError, FileResult, PackageError, SourceDiagnostic, Warned};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::layout::{Abs, Point};
use typst::syntax::package::PackageSpec;
use typst::syntax::{FileId, RootedPath, Side, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, World, WorldExt};
use typst_html::{HtmlDocument, HtmlOptions};
use typst_ide::{Completion, Definition, IdeWorld, Jump, Tooltip};
use typst_kit::datetime::Time;
use typst_kit::fonts::FontStore;
use typst_layout::PagedDocument;
use typst_pdf::PdfOptions;
use wasm_bindgen::prelude::*;

use crate::{LIBRARY, Slot, decode, display_path, highlight_runs, markdown, refactor_json, solveng_report, svg_page_updates};

static EMBEDDED: LazyLock<Vec<(Font, typst::text::FontInfo)>> = LazyLock::new(|| typst_kit::fonts::embedded().collect());

fn font_store(extra: &[Font]) -> FontStore {
    // Space fonts come first so they win over the embedded ones, like `--font-path` in the CLI.
    let mut fonts = FontStore::new();
    fonts.extend(extra.iter().map(|font| (font.clone(), font.info().clone())));
    fonts.extend(EMBEDDED.iter().cloned());
    fonts
}

struct WebWorld {
    main: Option<FileId>,
    files: HashMap<FileId, Bytes>,
    /// Packages the page loaded; asking for any other one records it in `missing`.
    packages: HashSet<PackageSpec>,
    missing: Mutex<HashSet<PackageSpec>>,
    index: Vec<(PackageSpec, Option<ecow::EcoString>)>,
    slots: Mutex<HashMap<FileId, Slot>>,
    time: Time,
    extra_fonts: Vec<Font>,
    fonts: FontStore,
    svg_pages: Mutex<HashMap<u128, Arc<str>>>,
    /// The last successful paged compile, for label completions and jumps.
    document: Option<PagedDocument>,
    /// solveng's report from the last compile that produced a document.
    solveng: String,
}

fn project_id(path: &str) -> Option<FileId> {
    Some(RootedPath::new(VirtualRoot::Project, VirtualPath::new(path).ok()?).intern())
}

fn package_id(spec: &str, path: &str) -> Option<FileId> {
    let spec = PackageSpec::from_str(spec).ok()?;
    Some(RootedPath::new(VirtualRoot::Package(spec), VirtualPath::new(path).ok()?).intern())
}

/// Not cached, so each compile reports the package in `missing` again until it is added.
fn missing_package<T>(result: &FileResult<T>) -> bool {
    matches!(result, Err(FileError::Package(PackageError::NotFound(_))))
}

impl WebWorld {
    fn invalidate(&mut self, id: FileId) {
        if let Some(slot) = self.slots.get_mut().get_mut(&id) {
            slot.invalidate();
        }
    }

    fn load(&self, id: FileId) -> FileResult<Bytes> {
        if let Some(bytes) = self.files.get(&id) {
            return Ok(bytes.clone());
        }
        match id.root() {
            VirtualRoot::Project => Err(FileError::NotFound(id.vpath().get_without_slash().into())),
            VirtualRoot::Package(spec) if self.packages.contains(spec) => {
                Err(FileError::NotFound(id.vpath().get_without_slash().into()))
            }
            VirtualRoot::Package(spec) => {
                self.missing.lock().insert(spec.clone());
                Err(FileError::Package(PackageError::NotFound(spec.clone())))
            }
        }
    }

    fn source_at(&self, path: &str) -> Option<Source> {
        self.source(project_id(path)?).ok()
    }
}

impl World for WebWorld {
    fn library(&self) -> &LazyHash<Library> {
        &LIBRARY
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.fonts.book()
    }

    fn main(&self) -> FileId {
        self.main.expect("main file is checked before compiling")
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        let mut slots = self.slots.lock();
        let slot = slots.entry(id).or_default();
        if let Some(result) = &slot.source {
            return result.clone();
        }
        let result = decode(id, self.load(id), slot.stale.take());
        if !missing_package(&result) {
            slot.source = Some(result.clone());
        }
        result
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        let mut slots = self.slots.lock();
        let slot = slots.entry(id).or_default();
        if let Some(result) = &slot.file {
            return result.clone();
        }
        let result = self.load(id);
        if !missing_package(&result) {
            slot.file = Some(result.clone());
        }
        result
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.font(index)
    }

    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.time.today(offset)
    }
}

impl IdeWorld for WebWorld {
    fn upcast(&self) -> &dyn World {
        self
    }

    fn packages(&self) -> &[(PackageSpec, Option<ecow::EcoString>)] {
        &self.index
    }

    fn files(&self) -> Vec<FileId> {
        self.files.keys().filter(|id| matches!(id.root(), VirtualRoot::Project)).copied().collect()
    }
}

/// What a compile produced: the document (if any), diagnostics as JSON, the packages it lacked and solveng's report.
#[wasm_bindgen(getter_with_clone)]
pub struct CompileResult {
    pub data: Option<Vec<u8>>,
    pub diagnostics: String,
    pub missing: Vec<String>,
    pub solveng: String,
}

#[wasm_bindgen]
pub struct Compiler {
    world: WebWorld,
    /// The file each extra font came from, by index into the last `setFonts` list.
    font_files: Vec<usize>,
}

#[derive(Serialize)]
struct CompletionJSON {
    kind: String,
    label: String,
    apply: Option<String>,
    detail: Option<String>,
}

impl From<Completion> for CompletionJSON {
    fn from(c: Completion) -> Self {
        CompletionJSON {
            kind: serde_json::to_value(&c.kind).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default(),
            label: c.label.to_string(),
            apply: c.apply.map(|a| a.to_string()),
            detail: c.detail.map(|d| d.to_string()),
        }
    }
}

#[wasm_bindgen]
impl Compiler {
    #[wasm_bindgen(constructor)]
    pub fn new() -> Compiler {
        Compiler {
            world: WebWorld {
                main: None,
                files: HashMap::new(),
                packages: HashSet::new(),
                missing: Mutex::new(HashSet::new()),
                index: Vec::new(),
                slots: Mutex::new(HashMap::new()),
                time: Time::system(),
                extra_fonts: Vec::new(),
                fonts: font_store(&[]),
                svg_pages: Mutex::new(HashMap::new()),
                document: None,
                solveng: "{}".into(),
            },
            font_files: Vec::new(),
        }
    }

    pub fn version() -> String {
        crate::typst_version().to_string()
    }

    /// Sets or replaces a project file, relative to the space.
    #[wasm_bindgen(js_name = setFile)]
    pub fn set_file(&mut self, path: &str, bytes: Vec<u8>) {
        let Some(id) = project_id(path) else { return };
        if self.world.files.get(&id).is_some_and(|old| old.as_slice() == bytes.as_slice()) {
            return;
        }
        self.world.files.insert(id, Bytes::new(bytes));
        self.world.invalidate(id);
    }

    #[wasm_bindgen(js_name = setText)]
    pub fn set_text(&mut self, path: &str, text: String) {
        self.set_file(path, text.into_bytes());
    }

    #[wasm_bindgen(js_name = removeFile)]
    pub fn remove_file(&mut self, path: &str) {
        let Some(id) = project_id(path) else { return };
        if self.world.files.remove(&id).is_some() {
            self.world.invalidate(id);
        }
    }

    /// Forgets every project file, for switching spaces.
    #[wasm_bindgen(js_name = clearFiles)]
    pub fn clear_files(&mut self) {
        self.world.files.retain(|id, _| !matches!(id.root(), VirtualRoot::Project));
        self.world.slots.get_mut().retain(|id, _| !matches!(id.root(), VirtualRoot::Project));
        self.world.document = None;
        self.world.main = None;
    }

    #[wasm_bindgen(js_name = setMain)]
    pub fn set_main(&mut self, path: &str) {
        self.world.main = project_id(path);
    }

    /// Adds a file of a package like `@preview/cetz:0.3.1`; `done` marks the package complete.
    #[wasm_bindgen(js_name = addPackageFile)]
    pub fn add_package_file(&mut self, spec: &str, path: &str, bytes: Vec<u8>) {
        let Some(id) = package_id(spec, path) else { return };
        self.world.files.insert(id, Bytes::new(bytes));
        self.world.invalidate(id);
    }

    /// Marks a package loaded, so its absent files are just missing and no longer a missing package.
    #[wasm_bindgen(js_name = finishPackage)]
    pub fn finish_package(&mut self, spec: &str) {
        let Ok(spec) = PackageSpec::from_str(spec) else { return };
        self.world.missing.get_mut().remove(&spec);
        self.world.packages.insert(spec.clone());
        for (id, slot) in self.world.slots.get_mut().iter_mut() {
            if matches!(id.root(), VirtualRoot::Package(s) if *s == spec) {
                slot.invalidate();
            }
        }
    }

    /// `[{name, version, description}]` from packages.typst.org, for completing imports.
    #[wasm_bindgen(js_name = setPackageIndex)]
    pub fn set_package_index(&mut self, json: &str) {
        let Ok(items) = serde_json::from_str::<Vec<serde_json::Value>>(json) else { return };
        self.world.index = items
            .iter()
            .filter_map(|item| {
                let spec = format!("@preview/{}:{}", item["name"].as_str()?, item["version"].as_str()?);
                Some((PackageSpec::from_str(&spec).ok()?, item["description"].as_str().map(Into::into)))
            })
            .collect();
    }

    /// Sets the space's font files (TTF, OTF, TTC); returns how many faces they hold.
    #[wasm_bindgen(js_name = setFonts)]
    pub fn set_fonts(&mut self, files: Vec<js_sys::Uint8Array>) -> usize {
        let (fonts, font_files): (Vec<Font>, Vec<usize>) = files
            .iter()
            .enumerate()
            .flat_map(|(i, bytes)| Font::iter(Bytes::new(bytes.to_vec())).map(move |font| (font, i)).collect::<Vec<_>>())
            .unzip();
        let same = fonts.len() == self.world.extra_fonts.len()
            && fonts.iter().zip(&self.world.extra_fonts).all(|(a, b)| a.data() == b.data() && a.index() == b.index());
        if !same {
            self.world.fonts = font_store(&fonts);
            self.world.extra_fonts = fonts;
            self.font_files = font_files;
        }
        self.world.extra_fonts.len()
    }

    /// The faces of the `setFonts` files as JSON (`[{file, family, weight, italic}]`), for the HTML preview's
    /// `@font-face` rules; faces after the first of a collection are left out, as CSS can't pick them.
    #[wasm_bindgen(js_name = fontFaces)]
    pub fn font_faces(&self) -> String {
        let faces: Vec<_> = self
            .world
            .extra_fonts
            .iter()
            .zip(&self.font_files)
            .filter(|(font, _)| font.index() == 0)
            .map(|(font, file)| {
                let info = font.info();
                json!({
                    "file": file,
                    "family": info.family,
                    "weight": info.variant.weight.to_number(),
                    "italic": info.variant.style != typst::text::FontStyle::Normal,
                })
            })
            .collect();
        serde_json::Value::Array(faces).to_string()
    }

    /// The families every font of the world offers, for font completions in the editor.
    #[wasm_bindgen(js_name = fontFamilies)]
    pub fn font_families(&self) -> Vec<String> {
        self.world.fonts.book().families().map(|(name, _)| name.to_string()).collect()
    }

    /// Forgets which SVG pages were sent, so the next SVG compile sends every page again.
    #[wasm_bindgen(js_name = resetSvg)]
    pub fn reset_svg(&mut self) {
        self.world.svg_pages.get_mut().clear();
    }

    /// Compiles the main file to `format` 0 PDF, 1 HTML or 2 SVG page updates (`svg_page_updates`); 3 lays out without
    /// output, for solveng's report on the file the editor shows.
    pub fn compile(&mut self, format: u8) -> CompileResult {
        self.world.time.reset();
        self.world.missing.get_mut().clear();
        // Empty unless this compile reports, since the last report may be another main file's.
        self.world.solveng = String::new();
        let (data, diags) = if self.world.main.is_none() {
            (None, vec![SourceDiagnostic::error(typst::syntax::Span::detached(), "no main file")])
        } else {
            self.export(format)
        };
        typst::comemo::evict(10);
        let json = crate::diagnostics::collect(&self.world, diags, data.is_none() && self.world.main.is_some());
        let missing = self.world.missing.get_mut().iter().map(|spec| spec.to_string()).collect();
        let solveng = self.world.solveng.clone();
        CompileResult { data, diagnostics: serde_json::to_string(&json).unwrap_or_else(|_| "[]".into()), missing, solveng }
    }

    fn export(&mut self, format: u8) -> (Option<Vec<u8>>, Vec<SourceDiagnostic>) {
        fn finish<T>(
            Warned { output, warnings }: Warned<typst::diag::SourceResult<T>>,
            export: impl FnOnce(&T) -> typst::diag::SourceResult<Vec<u8>>,
        ) -> (Option<Vec<u8>>, Vec<SourceDiagnostic>, Option<T>) {
            let mut diags: Vec<_> = warnings.into_iter().collect();
            match output {
                Ok(doc) => match export(&doc) {
                    Ok(data) => (Some(data), diags, Some(doc)),
                    Err(errors) => {
                        diags.splice(0..0, errors);
                        (None, diags, Some(doc))
                    }
                },
                Err(errors) => {
                    diags.splice(0..0, errors);
                    (None, diags, None)
                }
            }
        }
        let world = &self.world;
        match format {
            0 => {
                let (data, diags, doc) =
                    finish(typst::compile::<PagedDocument>(world), |doc| typst_pdf::pdf(doc, &PdfOptions::default()));
                if let Some(doc) = doc {
                    self.world.solveng = solveng_report(&self.world, &**doc.introspector());
                    self.world.document = Some(doc);
                }
                (data, diags)
            }
            1 => {
                let (data, diags, doc) = finish(typst::compile::<HtmlDocument>(world), |doc| {
                    typst_html::html(doc, &HtmlOptions::default()).map(String::into_bytes)
                });
                if let Some(doc) = doc {
                    self.world.solveng = solveng_report(&self.world, &**doc.introspector());
                }
                (data, diags)
            }
            3 => {
                let (_, diags, doc) = finish(typst::compile::<PagedDocument>(world), |_| Ok(Vec::new()));
                // Not kept for completions, since it isn't the previewed document.
                if let Some(doc) = doc {
                    self.world.solveng = solveng_report(&self.world, &**doc.introspector());
                }
                (None, diags)
            }
            _ => {
                let (data, diags, doc) =
                    finish(typst::compile::<PagedDocument>(world), |doc| Ok(svg_page_updates(&world.svg_pages, doc)));
                if let Some(doc) = doc {
                    self.world.solveng = solveng_report(&self.world, &**doc.introspector());
                    self.world.document = Some(doc);
                }
                (data, diags)
            }
        }
    }

    /// Completions at a UTF-16 `cursor` of the file: JSON `{from, items: [{kind, label, apply, detail}]}` or null.
    pub fn complete(&self, path: &str, cursor: usize, explicit: bool) -> String {
        let Some(source) = self.world.source_at(path) else { return "null".into() };
        let Some(byte) = source.lines().utf16_to_byte(cursor) else { return "null".into() };
        let output = self.world.document.as_ref();
        match typst_ide::autocomplete(&self.world, output, &source, byte, explicit) {
            Some((from, items)) => {
                let items: Vec<CompletionJSON> = items.into_iter().map(Into::into).collect();
                json!({"from": source.lines().byte_to_utf16(from), "items": items}).to_string()
            }
            None => "null".into(),
        }
    }

    /// Hover text at a UTF-16 `cursor`: JSON `{kind: "text" | "code", value}` or null.
    pub fn tooltip(&self, path: &str, cursor: usize) -> String {
        let Some(source) = self.world.source_at(path) else { return "null".into() };
        let Some(byte) = source.lines().utf16_to_byte(cursor) else { return "null".into() };
        match typst_ide::tooltip(&self.world, self.world.document.as_ref(), &source, byte, Side::After) {
            Some(Tooltip::Text(text)) => json!({"kind": "text", "value": text.as_str()}).to_string(),
            Some(Tooltip::Code(code)) => json!({"kind": "code", "value": code.as_str()}).to_string(),
            None => "null".into(),
        }
    }

    /// Where the item at a UTF-16 `cursor` is defined: JSON `{path, from, to}` in UTF-16, `{std}` for the
    /// standard library, or null.
    pub fn definition(&self, path: &str, cursor: usize) -> String {
        let Some(source) = self.world.source_at(path) else { return "null".into() };
        let Some(byte) = source.lines().utf16_to_byte(cursor) else { return "null".into() };
        match typst_ide::definition(&self.world, self.world.document.as_ref(), &source, byte, Side::After) {
            Some(Definition::Span(span)) => {
                let (Some(id), Some(range)) = (span.id(), self.world.range(span)) else { return "null".into() };
                self.location(id, range.start, range.end)
            }
            Some(Definition::File(id)) => self.location(id, 0, 0),
            Some(Definition::Std(value)) => {
                let name = match &value {
                    typst::foundations::Value::Func(func) => func.name().map(str::to_string),
                    typst::foundations::Value::Type(ty) => Some(ty.short_name().to_string()),
                    _ => None,
                };
                json!({"std": name}).to_string()
            }
            None => "null".into(),
        }
    }

    fn location(&self, id: FileId, start: usize, end: usize) -> String {
        let Ok(source) = self.world.source(id) else { return json!({"path": display_path(id), "from": 0, "to": 0}).to_string() };
        let lines = source.lines();
        json!({
            "path": display_path(id),
            "package": matches!(id.root(), VirtualRoot::Package(_)),
            "from": lines.byte_to_utf16(start).unwrap_or(0),
            "to": lines.byte_to_utf16(end).unwrap_or(0),
        })
        .to_string()
    }

    /// Where a click on page `page` (from 0) at `x`, `y` points goes: JSON `{path, offset}` (UTF-16),
    /// `{url}`, `{page, x, y}` or null.
    #[wasm_bindgen(js_name = jumpFromClick)]
    pub fn jump_from_click(&self, page: usize, x: f64, y: f64) -> String {
        let Some(doc) = &self.world.document else { return "null".into() };
        let Some(page) = NonZeroUsize::new(page + 1) else { return "null".into() };
        let position = typst::introspection::PagedPosition { page, point: Point::new(Abs::pt(x), Abs::pt(y)) };
        match typst_ide::jump_from_click(&self.world, doc, &position) {
            Some(Jump::File(id, offset)) => {
                let Ok(source) = self.world.source(id) else { return "null".into() };
                json!({"path": display_path(id), "offset": source.lines().byte_to_utf16(offset).unwrap_or(0)}).to_string()
            }
            Some(Jump::Url(url)) => json!({"url": url.as_str()}).to_string(),
            Some(Jump::Position(pos)) => {
                json!({"page": pos.page.get() - 1, "x": pos.point.x.to_pt(), "y": pos.point.y.to_pt()}).to_string()
            }
            None => "null".into(),
        }
    }

    /// Where the text at a UTF-16 `cursor` shows in the preview: JSON `[{page, x, y}]`, pages from 0.
    #[wasm_bindgen(js_name = jumpFromCursor)]
    pub fn jump_from_cursor(&self, path: &str, cursor: usize) -> String {
        let (Some(doc), Some(source)) = (&self.world.document, self.world.source_at(path)) else { return "[]".into() };
        let Some(byte) = source.lines().utf16_to_byte(cursor) else { return "[]".into() };
        let positions: Vec<_> = typst_ide::jump_from_cursor(doc, &source, byte)
            .into_iter()
            .map(|p| json!({"page": p.page.get() - 1, "x": p.point.x.to_pt(), "y": p.point.y.to_pt()}))
            .collect();
        serde_json::to_string(&positions).unwrap_or_else(|_| "[]".into())
    }
}

impl Default for Compiler {
    fn default() -> Self {
        Self::new()
    }
}

/// Highlighting runs for `text` (markup, or code if `code`): three values per run, UTF-16 start and
/// length and the tag (low byte) with style flags (bold 1, italic 2, math 4) from bit 8.
#[wasm_bindgen]
pub fn highlight(text: &str, code: bool) -> Vec<u32> {
    highlight_runs(text, code)
}

/// Refactors typst markup; the request and response are JSON as in the C header's `tw_refactor`.
#[wasm_bindgen]
pub fn refactor(request: &str) -> String {
    refactor_json(request)
}

/// GitHub flavored Markdown as HTML, math as MathML and code with syntect classes.
#[wasm_bindgen(js_name = markdownHtml)]
pub fn markdown_html(text: &str) -> String {
    markdown::to_html(text)
}

#[wasm_bindgen(js_name = markdownBlocks)]
pub fn markdown_blocks(text: &str) -> String {
    markdown::blocks(text)
}

#[wasm_bindgen(js_name = markdownBlockHtml)]
pub fn markdown_block_html(text: &str) -> String {
    markdown::block_html(text)
}

#[wasm_bindgen(js_name = markdownNotebook)]
pub fn markdown_notebook(cells: Vec<String>, package: &str) -> String {
    markdown::notebook(&cells, package)
}

#[wasm_bindgen(js_name = markdownCodeCss)]
pub fn markdown_code_css() -> String {
    markdown::code_css()
}

/// solveng's editor support for the page: `op` on `document` with its `context`, answering JSON; see `solveng::call`.
#[wasm_bindgen]
pub fn solveng(op: &str, document: &str, context: &str, offset: u32) -> String {
    crate::solveng::call(op, document, context, offset)
}
