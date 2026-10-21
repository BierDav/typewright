//! C interface for the Mac app: worlds read the project from disk, packages from typst's cache and
//! fonts from the system.

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::{Arc, LazyLock};

use parking_lot::Mutex;
use typst::World;
use typst::diag::{FileResult, SourceDiagnostic, Warned};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook, FontInfo};
use typst::utils::LazyHash;
use typst::Library;
use typst_html::{HtmlDocument, HtmlOptions};
use typst_kit::datetime::Time;
use typst_kit::downloader::SystemDownloader;
use typst_kit::files::FsRoot;
use typst_kit::fonts::{FontPath, FontStore};
use typst_kit::packages::SystemPackages;
use typst_layout::PagedDocument;
use typst_pdf::PdfOptions;

use crate::{LIBRARY, Slot, decode, diagnostic, highlight_runs, markdown, refactor_json, solveng_report, svg_pages, typst_version};

/// Typst's deep recursion overflows the small stacks of GCD threads.
const STACK_SIZE: usize = 64 * 1024 * 1024;

// Shared by all worlds: scanning fonts is slow and packages live in the same cache as the CLI's.
/// System and embedded fonts, scanned once; every world's store repeats them after its own font folders.
static BASE_FONTS: LazyLock<Vec<(BaseFont, FontInfo)>> = LazyLock::new(|| {
    let system = typst_kit::fonts::system().map(|(path, info)| (BaseFont::Path(path.path, path.index), info));
    let embedded = typst_kit::fonts::embedded().map(|(font, info)| (BaseFont::Embedded(font), info));
    system.chain(embedded).collect()
});

/// Worlds without extra font folders share one store, so loaded fonts are shared too.
static DEFAULT_FONTS: LazyLock<Arc<FontStore>> = LazyLock::new(|| Arc::new(font_store(Vec::new())));

enum BaseFont {
    Path(PathBuf, u32),
    Embedded(Font),
}

/// Extra fonts come first so they win over system fonts with the same name, like `--font-path` in the CLI.
fn font_store(extra: Vec<(FontPath, FontInfo)>) -> FontStore {
    let mut fonts = FontStore::new();
    fonts.extend(extra);
    for (font, info) in BASE_FONTS.iter() {
        match font {
            BaseFont::Path(path, index) => fonts.push((FontPath { path: path.clone(), index: *index }, info.clone())),
            BaseFont::Embedded(font) => fonts.push((font.clone(), info.clone())),
        }
    }
    fonts
}

static PACKAGES: LazyLock<SystemPackages> =
    LazyLock::new(|| SystemPackages::new(SystemDownloader::new(concat!("typewright/", env!("CARGO_PKG_VERSION")))));

pub struct TWWorld {
    root: FsRoot,
    main: Option<FileId>,
    overlays: HashMap<FileId, String>,
    slots: Mutex<HashMap<FileId, Slot>>,
    time: Time,
    fonts: Arc<FontStore>,
    /// The fonts found in the world's extra font folders, to skip rebuilding when nothing changed.
    extra_fonts: Vec<(PathBuf, u32)>,
    /// SVGs of the last compile's pages by layout hash, so unchanged pages aren't rendered again.
    svg_pages: Mutex<HashMap<u128, Arc<str>>>,
    /// solveng's report from the last compile that produced a document, see `solveng_report`.
    solveng: Mutex<String>,
}

impl TWWorld {
    fn id(path: &str) -> Option<FileId> {
        Some(RootedPath::new(VirtualRoot::Project, VirtualPath::new(path).ok()?).intern())
    }

    fn invalidate(&mut self, id: FileId) {
        if let Some(slot) = self.slots.get_mut().get_mut(&id) {
            slot.invalidate();
        }
    }

    fn load(&self, id: FileId) -> FileResult<Bytes> {
        if let Some(text) = self.overlays.get(&id) {
            return Ok(Bytes::from_string(text.clone()));
        }
        match id.root() {
            VirtualRoot::Project => self.root.load(id.vpath()),
            VirtualRoot::Package(spec) => PACKAGES.obtain(spec)?.load(id.vpath()),
        }
    }

    fn compile(&mut self, format: TWFormat) -> (Option<Vec<u8>>, Vec<SourceDiagnostic>) {
        self.time.reset();
        let world: &TWWorld = self;
        let result = std::thread::scope(|scope| {
            std::thread::Builder::new()
                .stack_size(STACK_SIZE)
                .spawn_scoped(scope, || world.export(format))
                .expect("spawn compile thread")
                .join()
        });
        // Keep the memoization cache bounded, like `typst watch`.
        typst::comemo::evict(10);
        result.unwrap_or_else(|panic| {
            let message = panic
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "unknown panic".into());
            (None, vec![SourceDiagnostic::error(typst::syntax::Span::detached(), format!("typst crashed: {message}"))])
        })
    }

    fn export(&self, format: TWFormat) -> (Option<Vec<u8>>, Vec<SourceDiagnostic>) {
        if self.main.is_none() {
            return (None, vec![SourceDiagnostic::error(typst::syntax::Span::detached(), "no main file")]);
        }
        fn finish<T>(
            Warned { output, warnings }: Warned<typst::diag::SourceResult<T>>,
            export: impl FnOnce(&T) -> typst::diag::SourceResult<Vec<u8>>,
        ) -> (Option<Vec<u8>>, Vec<SourceDiagnostic>) {
            let mut diags: Vec<_> = warnings.into_iter().collect();
            match output.and_then(|doc| export(&doc)) {
                Ok(data) => (Some(data), diags),
                Err(errors) => {
                    diags.splice(0..0, errors);
                    (None, diags)
                }
            }
        }
        match format {
            TWFormat::Pdf => finish(typst::compile::<PagedDocument>(self), |doc| {
                *self.solveng.lock() = solveng_report(self, &**doc.introspector());
                typst_pdf::pdf(doc, &PdfOptions::default())
            }),
            TWFormat::Html => finish(typst::compile::<HtmlDocument>(self), |doc| {
                *self.solveng.lock() = solveng_report(self, &**doc.introspector());
                typst_html::html(doc, &HtmlOptions::default()).map(String::into_bytes)
            }),
            TWFormat::Svg => finish(typst::compile::<PagedDocument>(self), |doc| {
                *self.solveng.lock() = solveng_report(self, &**doc.introspector());
                Ok(self.svg(doc))
            }),
            TWFormat::Check => finish(typst::compile::<PagedDocument>(self), |doc| {
                *self.solveng.lock() = solveng_report(self, &**doc.introspector());
                Ok(Vec::new())
            }),
        }
    }

    fn svg(&self, doc: &PagedDocument) -> Vec<u8> {
        svg_pages(&self.svg_pages, doc)
    }
}

impl World for TWWorld {
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
        slot.source = Some(result.clone());
        result
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        let mut slots = self.slots.lock();
        let slot = slots.entry(id).or_default();
        if let Some(result) = &slot.file {
            return result.clone();
        }
        let result = self.load(id);
        slot.file = Some(result.clone());
        result
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.font(index)
    }

    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.time.today(offset)
    }
}

// MARK: - C interface

#[repr(u8)]
#[derive(Clone, Copy)]
pub enum TWFormat {
    Pdf = 0,
    Html = 1,
    Svg = 2,
    /// Lays out without exporting, for solveng's report on a file the editor shows.
    Check = 3,
}

#[repr(C)]
pub struct TWResult {
    data: *mut u8,
    len: usize,
    diagnostics: *mut c_char,
}

unsafe fn str<'a>(ptr: *const c_char) -> &'a str {
    unsafe { CStr::from_ptr(ptr) }.to_str().unwrap_or_default()
}

#[unsafe(no_mangle)]
pub extern "C" fn tw_version() -> *const c_char {
    static VERSION: LazyLock<CString> = LazyLock::new(|| CString::new(typst_version()).unwrap());
    VERSION.as_ptr()
}

#[unsafe(no_mangle)]
pub extern "C" fn tw_warm_up() {
    LazyLock::force(&LIBRARY);
    LazyLock::force(&DEFAULT_FONTS);
}

/// # Safety
/// `root` must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_new(root: *const c_char) -> *mut TWWorld {
    let root = PathBuf::from(unsafe { str(root) });
    Box::into_raw(Box::new(TWWorld {
        root: FsRoot::new(root),
        main: None,
        overlays: HashMap::new(),
        slots: Mutex::new(HashMap::new()),
        time: Time::system(),
        fonts: DEFAULT_FONTS.clone(),
        extra_fonts: Vec::new(),
        svg_pages: Mutex::new(HashMap::new()),
        solveng: Mutex::new("{}".into()),
    }))
}

/// Rescans the world's extra font folders; returns whether its fonts changed.
///
/// # Safety
/// `world` must be valid and `paths` point to `count` valid C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_set_font_paths(world: *mut TWWorld, paths: *const *const c_char, count: usize) -> bool {
    let world = unsafe { &mut *world };
    let paths = if count == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(paths, count) } };
    let extra: Vec<_> = paths
        .iter()
        .flat_map(|&path| typst_kit::fonts::scan(std::path::Path::new(unsafe { str(path) })))
        .collect();
    let found: Vec<_> = extra.iter().map(|(path, _)| (path.path.clone(), path.index)).collect();
    if found == world.extra_fonts {
        return false;
    }
    world.fonts = if extra.is_empty() { DEFAULT_FONTS.clone() } else { Arc::new(font_store(extra)) };
    world.extra_fonts = found;
    true
}

/// # Safety
/// `world` must come from `tw_world_new` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_free(world: *mut TWWorld) {
    drop(unsafe { Box::from_raw(world) });
}

/// # Safety
/// `world` must be valid and `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_set_main(world: *mut TWWorld, path: *const c_char) {
    let world = unsafe { &mut *world };
    world.main = TWWorld::id(unsafe { str(path) });
}

/// # Safety
/// `world` must be valid, `path` a valid C string and `text` point to `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_set_overlay(world: *mut TWWorld, path: *const c_char, text: *const u8, len: usize) {
    let world = unsafe { &mut *world };
    let Some(id) = TWWorld::id(unsafe { str(path) }) else { return };
    let text = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(text, len) }).into_owned();
    if world.overlays.get(&id) == Some(&text) {
        return;
    }
    world.overlays.insert(id, text);
    world.invalidate(id);
}

/// # Safety
/// `world` must be valid and `path` a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_remove_overlay(world: *mut TWWorld, path: *const c_char) {
    let world = unsafe { &mut *world };
    let Some(id) = TWWorld::id(unsafe { str(path) }) else { return };
    if world.overlays.remove(&id).is_some() {
        world.invalidate(id);
    }
}

/// # Safety
/// `world` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_reset(world: *mut TWWorld) {
    let world = unsafe { &mut *world };
    let overlays = &world.overlays;
    // Overlays and downloaded packages can't change on disk under us; local packages and failed downloads can.
    for (id, slot) in world.slots.get_mut().iter_mut() {
        let on_disk = match id.root() {
            VirtualRoot::Project => !overlays.contains_key(id),
            VirtualRoot::Package(spec) => {
                spec.namespace != "preview" || matches!(slot.source, Some(Err(_))) || matches!(slot.file, Some(Err(_)))
            }
        };
        if on_disk {
            slot.invalidate();
        }
    }
}

/// # Safety
/// `world` must be valid. The result must be released with `tw_result_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_compile(world: *mut TWWorld, format: TWFormat) -> TWResult {
    let world = unsafe { &mut *world };
    let (output, diags) = world.compile(format);
    let json: Vec<_> = diags.iter().map(|d| diagnostic(world, d)).collect();
    let diagnostics = CString::new(serde_json::to_string(&json).unwrap_or_else(|_| "[]".into()))
        .unwrap_or_default()
        .into_raw();
    match output {
        Some(data) => {
            let mut data = data.into_boxed_slice();
            let len = data.len();
            let ptr = data.as_mut_ptr();
            std::mem::forget(data);
            TWResult { data: ptr, len, diagnostics }
        }
        None => TWResult { data: std::ptr::null_mut(), len: 0, diagnostics },
    }
}

/// What solveng reported in the last compile that produced a document, as JSON. Free with `tw_string_free`.
///
/// # Safety
/// `world` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_solveng(world: *mut TWWorld) -> *mut c_char {
    let world = unsafe { &*world };
    CString::new(world.solveng.lock().clone()).unwrap_or_default().into_raw()
}

fn bytes<'a>(ptr: *const u8, len: usize) -> std::borrow::Cow<'a, str> {
    if ptr.is_null() || len == 0 {
        return "".into();
    }
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// solveng's editor support, see `solveng::call`. Free with `tw_string_free`.
///
/// # Safety
/// `op` must be a valid C string, `document` and `context` point to their lengths in bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_solveng(
    op: *const c_char,
    document: *const u8,
    document_len: usize,
    context: *const u8,
    context_len: usize,
    offset: u32,
) -> *mut c_char {
    let result = crate::solveng::call(unsafe { str(op) }, &bytes(document, document_len), &bytes(context, context_len), offset);
    CString::new(result).unwrap_or_default().into_raw()
}

/// # Safety
/// `result` must come from `tw_world_compile` and not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_result_free(result: TWResult) {
    if !result.data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(result.data, result.len)) });
    }
    drop(unsafe { CString::from_raw(result.diagnostics) });
}

// MARK: - Highlighting

/// Highlights `text` as markup, or as code when `code` is set. Returns `count` values, three per run:
/// UTF-16 start, UTF-16 length and the tag, with style flags from bit 8 on. Free with `tw_highlight_free`.
///
/// # Safety
/// `text` must point to `len` bytes of UTF-8 and `count` be valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_highlight(text: *const u8, len: usize, code: bool, count: *mut usize) -> *mut u32 {
    let bytes = if len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(text, len) } };
    let text = String::from_utf8_lossy(bytes);
    let runs = highlight_runs(&text, code).into_boxed_slice();
    unsafe { *count = runs.len() };
    Box::into_raw(runs) as *mut u32
}

/// # Safety
/// `runs` and `count` must come from one `tw_highlight` call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_highlight_free(runs: *mut u32, count: usize) {
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(runs, count)) });
}

/// Hidden syntax for the editor; see `conceal_runs`. Free with `tw_highlight_free`.
///
/// # Safety
/// `text` must point to `len` bytes of UTF-8 and `count` be valid for writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_conceal(text: *const u8, len: usize, count: *mut usize) -> *mut u32 {
    let bytes = if len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(text, len) } };
    let runs = crate::conceal_runs(&String::from_utf8_lossy(bytes)).into_boxed_slice();
    unsafe { *count = runs.len() };
    Box::into_raw(runs) as *mut u32
}

// MARK: - Packages

fn obtain_package(spec: &str) -> Result<String, String> {
    use std::str::FromStr;
    use typst::syntax::package::{PackageSpec, VersionlessPackageSpec};
    let spec = match PackageSpec::from_str(spec) {
        Ok(spec) => spec,
        // Without a version the newest one is fetched.
        Err(_) => {
            let versionless = VersionlessPackageSpec::from_str(spec).map_err(|e| e.to_string())?;
            let version = PACKAGES.latest_version(&versionless).map_err(|e| e.to_string())?;
            versionless.at(version)
        }
    };
    PACKAGES.obtain(&spec).map_err(|e| e.to_string())?;
    Ok(spec.to_string())
}

/// Downloads a package like `@preview/cetz:0.3.1` (or the newest `@preview/cetz`) into typst's package cache.
/// Returns `ok:` and the full spec, or `error:` and a message; free with `tw_string_free`.
///
/// # Safety
/// `spec` must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_package_download(spec: *const c_char) -> *mut c_char {
    let spec = unsafe { str(spec) }.trim();
    let result = match obtain_package(spec) {
        Ok(spec) => format!("ok:{spec}"),
        Err(message) => format!("error:{message}"),
    };
    CString::new(result).unwrap_or_default().into_raw()
}

/// # Safety
/// `string` must come from this library and not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_string_free(string: *mut c_char) {
    drop(unsafe { CString::from_raw(string) });
}

// MARK: - Refactoring

/// Runs a refactoring described by a JSON request; see the header. Free the result with `tw_string_free`.
///
/// # Safety
/// `request` must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_refactor(request: *const c_char) -> *mut c_char {
    CString::new(refactor_json(unsafe { str(request) })).unwrap_or_default().into_raw()
}

// MARK: - Markdown

/// # Safety
/// `text` must point to `len` bytes of UTF-8. Free the result with `tw_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_markdown_html(text: *const u8, len: usize) -> *mut c_char {
    let bytes = if len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(text, len) } };
    let html = markdown::to_html(&String::from_utf8_lossy(bytes)).replace('\0', "");
    CString::new(html).unwrap_or_default().into_raw()
}

/// Free the result with `tw_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn tw_markdown_code_css() -> *mut c_char {
    CString::new(markdown::code_css()).unwrap_or_default().into_raw()
}

#[cfg(test)]
mod solveng_tests {
    use super::*;

    unsafe fn compile_report(main: &str) -> serde_json::Value {
        let dir = std::env::temp_dir().join(format!("tw-solveng-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let root = CString::new(dir.to_str().unwrap()).unwrap();
        let path = CString::new("main.typ").unwrap();
        unsafe {
            let world = tw_world_new(root.as_ptr());
            tw_world_set_main(world, path.as_ptr());
            tw_world_set_overlay(world, path.as_ptr(), main.as_ptr(), main.len());
            tw_result_free(tw_world_compile(world, TWFormat::Pdf));
            let report = tw_world_solveng(world);
            let json = serde_json::from_str(CStr::from_ptr(report).to_str().unwrap()).unwrap();
            tw_string_free(report);
            tw_world_free(world);
            json
        }
    }

    #[test]
    fn reports_solveng_metadata() {
        // What solveng's worksheet leaves for each element and block.
        let main = r#"#show math.equation: it => it + context [#metadata((kind: "math", element: it.location(), active: true, integration: "math")) <solveng>]
#metadata((kind: "block", defined: ((name: "a", kind: "value", value: "1"),), units: ())) <solveng>
Text $a = 1$ more."#;
        let report = unsafe { compile_report(main) };
        let element = &report["elements"][0];
        assert_eq!(element["path"], "main.typ");
        assert_eq!(element["text"], "$a = 1$");
        assert_eq!(element["integration"], "math");
        assert_eq!(element["active"], true);
        assert_eq!(element["start"], main.encode_utf16().count() - "$a = 1$ more.".encode_utf16().count());
        assert_eq!(report["defined"][0]["name"], "a");
        assert_eq!(report["blocks"], 1);
    }

    #[test]
    fn compiles_typst_operator_symbol_aliases_without_changing_source_locations() {
        for alias in ["ΛΩ", "Lambda\"\"Omega", "LambdaΩ", "ΛOmega"] {
            let main = format!("#let ΛΩ = math.op(\"tri\")\n#let graph(body) = {{ let op = body.body.children.at(0); assert.eq(op.func(), math.op); assert.eq(op.text.children.at(0).text, \"tri\"); assert.eq(op.text.children.at(1).value, \"ΛΩ\") }}\n#graph($ {alias}(x) $)");
            let root = CString::new(std::env::temp_dir().to_str().unwrap()).unwrap();
            let path = CString::new("main.typ").unwrap();
            unsafe {
                let world = tw_world_new(root.as_ptr());
                tw_world_set_main(world, path.as_ptr());
                tw_world_set_overlay(world, path.as_ptr(), main.as_ptr(), main.len());
                let (_, diagnostics) = (*world).compile(TWFormat::Check);
                assert!(diagnostics.is_empty(), "{alias}: {diagnostics:?}");
                let source = (*world).source((*world).main.unwrap()).unwrap();
                assert_eq!(source.text(), main);
                tw_world_free(world);
            }
        }
    }

    #[test]
    #[ignore = "requires a local solveng package (SOLVENG_ROOT)"]
    fn graph_labels_use_typst_binding_names() {
        let package = std::env::var("SOLVENG_ROOT").expect("SOLVENG_ROOT");
        let main = r#"#import "/src/graph.typ": graph
#let Λ = math.op("tri")
#let ΛΩ = math.op("tri")
#let dreieick = math.op("tri")
#let sqrt = math.op("tri")
#let plain(c) = if c.has("text") and type(c.text) == str { c.text } else if c.has("children") { c.children.map(plain).join() } else { "" }
#show math.op: it => { assert.ne(plain(it.text).trim(), "tri"); it }
#graph($ Lambda(2x) $, errors: "panic", samples: 20)
#graph($ Lambda""Omega(2x) + dreieick(x) $, errors: "panic", samples: 20)
#graph($ dreieick(x) \ Lambda(x) $, errors: "panic", samples: 20)
#graph($ sqrt(x) $, errors: "panic", samples: 20)
"#;
        let root = CString::new(package).unwrap();
        let path = CString::new("operator-label-check.typ").unwrap();
        unsafe {
            let world = tw_world_new(root.as_ptr());
            tw_world_set_main(world, path.as_ptr());
            tw_world_set_overlay(world, path.as_ptr(), main.as_ptr(), main.len());
            let (svg, diagnostics) = (*world).compile(TWFormat::Svg);
            assert!(diagnostics.is_empty(), "{diagnostics:?}");
            let svg = String::from_utf8(svg.expect("graph output")).unwrap();
            let labels: String = svg.split("<text ").skip(1)
                .filter_map(|text| text.split_once('>')?.1.split_once("</text>").map(|(text, _)| text))
                .collect();
            for name in ["Λ", "ΛΩ", "dreieick", "sqrt"] {
                assert!(labels.contains(name), "missing graph label: {name} in {labels}");
            }
            tw_world_free(world);
        }
    }

    #[test]
    fn operator_aliases_do_not_make_other_names_available() {
        let main = "#let dreieick = math.op(\"tri\")\n#graph($ tri(x) $)".replace("#graph", "#box");
        let root = CString::new(std::env::temp_dir().to_str().unwrap()).unwrap();
        let path = CString::new("main.typ").unwrap();
        unsafe {
            let world = tw_world_new(root.as_ptr());
            tw_world_set_main(world, path.as_ptr());
            tw_world_set_overlay(world, path.as_ptr(), main.as_ptr(), main.len());
            let (_, diagnostics) = (*world).compile(TWFormat::Check);
            assert!(diagnostics.iter().any(|d| d.message.contains("unknown variable: tri")));
            let d = diagnostics.iter().find(|d| d.message.contains("unknown variable: tri")).unwrap();
            let json = crate::diagnostic(&*world, d);
            assert_eq!((json.line, json.column), (2, 8));
            tw_world_free(world);
        }
    }

}
