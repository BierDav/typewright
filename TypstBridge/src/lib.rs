//! C interface to an in-process typst compiler whose world serves unsaved buffers from memory.

use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;
use std::sync::{Arc, LazyLock};

use parking_lot::Mutex;
use serde::Serialize;
use typst::diag::{FileError, FileResult, Severity, SourceDiagnostic, Warned};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, Lines, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook, FontInfo};
use typst::utils::LazyHash;
use typst::{Feature, Library, LibraryExt, World, WorldExt};
use typst_html::{HtmlDocument, HtmlOptions};
use typst_kit::datetime::Time;
use typst_kit::downloader::SystemDownloader;
use typst_kit::files::FsRoot;
use typst_kit::fonts::{FontPath, FontStore};
use typst_kit::packages::SystemPackages;
use typst_layout::PagedDocument;
use typst_pdf::PdfOptions;
use typst_svg::SvgOptions;

/// Typst's deep recursion overflows the small stacks of GCD threads.
const STACK_SIZE: usize = 64 * 1024 * 1024;

// Shared by all worlds: scanning fonts is slow and packages live in the same cache as the CLI's.
static LIBRARY: LazyLock<LazyHash<Library>> =
    LazyLock::new(|| LazyHash::new(Library::builder().with_features([Feature::Html].into_iter().collect()).build()));

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
}

/// Cached results for one file; `stale` keeps an old parse so edits are reparsed incrementally.
#[derive(Default)]
struct Slot {
    source: Option<FileResult<Source>>,
    file: Option<FileResult<Bytes>>,
    stale: Option<Source>,
}

impl Slot {
    fn invalidate(&mut self) {
        let stale = match self.source.take() {
            Some(Ok(source)) => Some(source),
            _ => self.stale.take(),
        };
        *self = Slot { stale, ..Slot::default() };
    }
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

    fn decode(&self, id: FileId, stale: Option<Source>) -> FileResult<Source> {
        let bytes = self.load(id)?;
        let data = bytes.as_slice();
        let text = std::str::from_utf8(data.strip_prefix(b"\xef\xbb\xbf").unwrap_or(data))
            .map_err(|_| FileError::InvalidUtf8)?;
        Ok(match stale {
            Some(mut source) => {
                source.replace(text);
                source
            }
            None => Source::new(id, text.into()),
        })
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
                typst_pdf::pdf(doc, &PdfOptions::default())
            }),
            TWFormat::Html => finish(typst::compile::<HtmlDocument>(self), |doc| {
                typst_html::html(doc, &HtmlOptions::default()).map(String::into_bytes)
            }),
            TWFormat::Svg => finish(typst::compile::<PagedDocument>(self), |doc| Ok(self.svg(doc))),
        }
    }

    /// One SVG per page, separated by NUL bytes, which SVG text can't contain.
    fn svg(&self, doc: &PagedDocument) -> Vec<u8> {
        let mut cache = self.svg_pages.lock();
        let mut next = HashMap::with_capacity(doc.pages().len());
        let mut out = Vec::new();
        for (i, page) in doc.pages().iter().enumerate() {
            let hash = typst::utils::hash128(page);
            let svg = cache
                .remove(&hash)
                .or_else(|| next.get(&hash).cloned())
                .unwrap_or_else(|| Arc::from(typst_svg::svg(page, &SvgOptions::default())));
            if i > 0 {
                out.push(0);
            }
            out.extend_from_slice(svg.as_bytes());
            next.insert(hash, svg);
        }
        *cache = next;
        out
    }

    /// Path as typst's CLI prints it: relative to the root, or prefixed with the package spec.
    fn display_path(id: FileId) -> String {
        let path = id.vpath().get_without_slash();
        match id.root() {
            VirtualRoot::Project => path.to_string(),
            VirtualRoot::Package(spec) => format!("{spec}/{path}"),
        }
    }

    fn lines(&self, id: FileId) -> Option<Lines<String>> {
        match self.source(id) {
            Ok(source) => Some(source.lines().clone()),
            Err(_) => self.file(id).ok()?.lines().ok(),
        }
    }

    fn diagnostic(&self, diag: &SourceDiagnostic) -> DiagnosticJSON {
        let severity = match diag.severity {
            Severity::Error => "error",
            Severity::Warning => "warning",
        };
        let mut out = DiagnosticJSON {
            path: String::new(),
            line: 1,
            column: 1,
            severity,
            message: diag.message.to_string(),
        };
        let Some(id) = diag.span.id() else { return out };
        out.path = Self::display_path(id);
        if let (Some(range), Some(lines)) = (self.range(diag.span), self.lines(id))
            && let Some(line) = lines.byte_to_line(range.start)
            && let Some(start) = lines.line_to_byte(line)
            && let Some(head) = lines.text().get(start..range.start)
        {
            // Columns count UTF-16 units to match NSString offsets.
            out.line = line + 1;
            out.column = head.encode_utf16().count() + 1;
        }
        out
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
        let result = self.decode(id, slot.stale.take());
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

#[derive(Serialize)]
struct DiagnosticJSON {
    path: String,
    line: usize,
    column: usize,
    severity: &'static str,
    message: String,
}

// MARK: - C interface

#[repr(u8)]
#[derive(Clone, Copy)]
pub enum TWFormat {
    Pdf = 0,
    Html = 1,
    Svg = 2,
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

fn typst_version() -> &'static str {
    // typst-bridge pins typst exactly, so the manifest is the source of truth.
    const MANIFEST: &str = include_str!("../Cargo.toml");
    MANIFEST
        .lines()
        .find_map(|l| l.strip_prefix("typst = \"="))
        .and_then(|l| l.strip_suffix('"'))
        .unwrap_or("unknown")
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
    // Overlays and downloaded packages can't change on disk under us.
    for (id, slot) in world.slots.get_mut().iter_mut() {
        if matches!(id.root(), VirtualRoot::Project) && !overlays.contains_key(id) {
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
    let json: Vec<_> = diags.iter().map(|d| world.diagnostic(d)).collect();
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

/// # Safety
/// `result` must come from `tw_world_compile` and not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_result_free(result: TWResult) {
    if !result.data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(result.data, result.len)) });
    }
    drop(unsafe { CString::from_raw(result.diagnostics) });
}
