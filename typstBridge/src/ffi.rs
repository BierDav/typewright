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

use crate::{LIBRARY, Slot, decode, highlight_runs, markdown, refactor_json, solveng_report, svg_pages, typst_version};

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
    pdf_preview: Mutex<Vec<(u128, Arc<[u8]>)>>,
    pdf_pages: Mutex<HashMap<u128, Arc<[u8]>>>,
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
            TWFormat::PdfPages => finish(typst::compile::<PagedDocument>(self), |doc| {
                *self.solveng.lock() = solveng_report(self, &**doc.introspector());
                // Page-range exports omit links into other pages; preserve their document-wide destinations.
                fn internal_links(frame: &typst::layout::Frame) -> bool {
                    frame.items().any(|(_, item)| match item {
                        typst::layout::FrameItem::Link(destination, _) => !matches!(destination, typst::model::Destination::Url(_)),
                        typst::layout::FrameItem::Group(group) => internal_links(&group.frame),
                        _ => false,
                    })
                }
                if doc.pages().iter().any(|page| internal_links(&page.frame)) {
                    return typst_pdf::pdf(doc, &PdfOptions::default());
                }
                *self.pdf_preview.lock() = self.preview_pages(doc)?;
                Ok(Vec::new())
            }),
            TWFormat::Check => finish(typst::compile::<PagedDocument>(self), |doc| {
                *self.solveng.lock() = solveng_report(self, &**doc.introspector());
                Ok(Vec::new())
            }),
        }
    }

    fn preview_pages(&self, doc: &PagedDocument) -> typst::diag::SourceResult<Vec<(u128, Arc<[u8]>)>> {
        let mut cache = self.pdf_pages.lock();
        let mut next = HashMap::with_capacity(doc.pages().len());
        let mut pages = Vec::with_capacity(doc.pages().len());
        for (index, page) in doc.pages().iter().enumerate() {
            let hash = typst::utils::hash128(page);
            let pdf = match cache.get(&hash).or_else(|| next.get(&hash)) {
                Some(pdf) => Arc::clone(pdf),
                None => {
                    let number = std::num::NonZeroUsize::new(index + 1);
                    let options = PdfOptions {
                        page_ranges: Some(typst::layout::PageRanges::new(vec![number..=number])),
                        tagged: false,
                        ..PdfOptions::default()
                    };
                    Arc::from(typst_pdf::pdf(doc, &options)?)
                }
            };
            pages.push((hash, Arc::clone(&pdf)));
            next.insert(hash, pdf);
        }
        *cache = next;
        Ok(pages)
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
    PdfPages = 4,
}

#[repr(C)]
pub struct TWPreviewPage {
    pub data: *const u8,
    pub len: usize,
    pub hash_high: u64,
    pub hash_low: u64,
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
        pdf_preview: Mutex::new(Vec::new()),
        pdf_pages: Mutex::new(HashMap::new()),
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
    let fallback = diags.iter().map(|d| crate::diagnostic(world, d)).collect();
    let json = std::thread::scope(|scope| {
        std::thread::Builder::new().stack_size(STACK_SIZE)
            .spawn_scoped(scope, || crate::diagnostics::collect(world, diags, output.is_none() && world.main.is_some()))
            .expect("spawn diagnostics thread").join().unwrap_or(fallback)
    });
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
/// `world` must be valid and not concurrently accessed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_preview_page_count(world: *const TWWorld) -> usize {
    unsafe { &*world }.pdf_preview.lock().len()
}

/// # Safety
/// `world` must be valid; the borrowed bytes remain valid until its next PDF-pages compile or destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tw_world_preview_page(world: *const TWWorld, index: usize) -> TWPreviewPage {
    let pages = unsafe { &*world }.pdf_preview.lock();
    match pages.get(index) {
        Some((hash, svg)) => TWPreviewPage {
            data: svg.as_ptr(), len: svg.len(), hash_high: (hash >> 64) as u64, hash_low: *hash as u64,
        },
        None => TWPreviewPage { data: std::ptr::null(), len: 0, hash_high: 0, hash_low: 0 },
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

    #[test]
    fn pdf_preview_reuses_unchanged_buffers() {
        let root = CString::new(std::env::temp_dir().to_str().unwrap()).unwrap();
        let main = CString::new("main.typ").unwrap();
        unsafe {
            let world = tw_world_new(root.as_ptr());
            tw_world_set_main(world, main.as_ptr());
            let compile = |source: &str, format| {
                tw_world_set_overlay(world, main.as_ptr(), source.as_ptr(), source.len());
                let result = tw_world_compile(world, format);
                assert!(!result.data.is_null(), "{}", CStr::from_ptr(result.diagnostics).to_string_lossy());
                result
            };
            let first = compile("One\n#pagebreak()\nTwo", TWFormat::PdfPages);
            assert_eq!(first.len, 0);
            tw_result_free(first);
            assert_eq!(tw_world_preview_page_count(world), 2);
            let unchanged = tw_world_preview_page(world, 0);
            let changed = tw_world_preview_page(world, 1);

            let second = compile("One\n#pagebreak()\nEdited", TWFormat::PdfPages);
            tw_result_free(second);
            let reused = tw_world_preview_page(world, 0);
            let edited = tw_world_preview_page(world, 1);
            assert_eq!((unchanged.hash_high, unchanged.hash_low), (reused.hash_high, reused.hash_low));
            assert_eq!(unchanged.data, reused.data);
            assert_ne!((changed.hash_high, changed.hash_low), (edited.hash_high, edited.hash_low));
            assert!(tw_world_preview_page(world, 2).data.is_null());

            for index in 0..2 {
                let page = tw_world_preview_page(world, index);
                assert!(std::slice::from_raw_parts(page.data, page.len).starts_with(b"%PDF"));
            }
            tw_world_free(world);
        }
    }

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
    fn compiles_current_solveng_when_available() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        if !root.join("solveng/lib.typ").exists() { return; }
        let main = r#"#import "solveng/lib.typ": *
#show: worksheet
$U := 5 "V"$
$U + 2 "s" =$
```solveng
x := U + 3 s =
```
Voltage: #value("U = mV").
Bad: #value("q + 1"), #value($r + 2$).
"#;
        let root = CString::new(root.to_str().unwrap()).unwrap();
        let path = CString::new("main.typ").unwrap();
        unsafe {
            let world = tw_world_new(root.as_ptr());
            tw_world_set_main(world, path.as_ptr());
            tw_world_set_overlay(world, path.as_ptr(), main.as_ptr(), main.len());
            let result = tw_world_compile(world, TWFormat::Check);
            assert!(!result.data.is_null(), "{}", CStr::from_ptr(result.diagnostics).to_string_lossy());
            tw_result_free(result);
            let report = tw_world_solveng(world);
            let raw = CStr::from_ptr(report).to_str().unwrap();
            let context = serde_json::json!({"path": "main.typ", "main": true, "report": raw}).to_string();
            let problems: serde_json::Value = serde_json::from_str(&crate::solveng::call("diagnostics", main, &context, 0)).unwrap();
            // V plus s twice, q and r
            assert_eq!(problems.as_array().unwrap().iter().filter(|p| p["severity"] == "error").count(), 4, "{raw}\n{problems}");
            let source: Vec<u16> = main.encode_utf16().collect();
            for problem in problems.as_array().unwrap() {
                let range = problem["start"].as_u64().unwrap() as usize..problem["end"].as_u64().unwrap() as usize;
                assert!(!String::from_utf16(&source[range]).unwrap().contains('$'));
            }
            tw_string_free(report);
            tw_world_free(world);
        }
    }

    #[test]
    fn reports_solveng_errors_in_elements_and_call_strings() {
        let main = r#"#show math.equation: it => it + context [#metadata((kind: "error", element: it.location(), message: "incompatible units", source: "")) <solveng>]
#metadata((kind: "error", element: none, message: "undefined q", source: "q + 1")) <solveng>
#let value(expr) = []
😀 $1 V + 2 s =$ #value("q + 1")"#;
        let report = unsafe { compile_report(main) };
        assert_eq!(report["elements"].as_array().unwrap().len(), 0);
        let errors = report["errors"].as_array().unwrap();
        assert_eq!(errors.len(), 2);
        let placed = errors.iter().find(|e| e["message"] == "incompatible units").unwrap();
        assert_eq!(placed["path"], "main.typ");
        assert_eq!(placed["text"], "$1 V + 2 s =$");
        assert_eq!(placed["start"], main[..main.rfind("$1 V").unwrap()].encode_utf16().count());
        let context = serde_json::json!({"path": "main.typ", "main": true, "report": report.to_string()}).to_string();
        let problems: serde_json::Value = serde_json::from_str(&crate::solveng::call("diagnostics", main, &context, 0)).unwrap();
        let problems = problems.as_array().unwrap();
        assert_eq!(problems.len(), 2);
        assert!(problems.iter().all(|p| p["severity"] == "error"));
        let edited = main.replace("$1 V + 2 s =$", "$1 V + 2 V =$");
        let problems: serde_json::Value = serde_json::from_str(&crate::solveng::call("diagnostics", &edited, &context, 0)).unwrap();
        assert_eq!(problems.as_array().unwrap().len(), 1);
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

}
