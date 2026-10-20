//! typst in process, with a world that serves unsaved buffers from memory: `ffi` is the Mac app's C
//! interface over the file system, `web` the browser's, where the page hands over files and packages.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock};

mod markdown;
mod refactor;

#[cfg(not(target_arch = "wasm32"))]
mod ffi;
#[cfg(target_arch = "wasm32")]
mod web;

#[cfg(not(target_arch = "wasm32"))]
pub use ffi::*;
#[cfg(target_arch = "wasm32")]
pub use web::*;

use parking_lot::Mutex;
use serde::Serialize;
use typst::diag::{FileResult, Severity, SourceDiagnostic};
use typst::foundations::Bytes;
use typst::syntax::{FileId, LinkedNode, Lines, Source, SyntaxKind, Tag, VirtualRoot};
use typst::utils::LazyHash;
use typst::{Feature, Library, LibraryExt, World, WorldExt};
use typst_layout::PagedDocument;
use typst_svg::SvgOptions;

pub(crate) static LIBRARY: LazyLock<LazyHash<Library>> =
    LazyLock::new(|| LazyHash::new(Library::builder().with_features([Feature::Html].into_iter().collect()).build()));

/// Cached results for one file; `stale` keeps an old parse so edits are reparsed incrementally.
#[derive(Default)]
pub(crate) struct Slot {
    pub source: Option<FileResult<Source>>,
    pub file: Option<FileResult<Bytes>>,
    pub stale: Option<Source>,
}

impl Slot {
    pub fn invalidate(&mut self) {
        let stale = match self.source.take() {
            Some(Ok(source)) => Some(source),
            _ => self.stale.take(),
        };
        *self = Slot { stale, ..Slot::default() };
    }
}

/// Decodes a file as typst source, reusing the stale parse for incremental reparsing.
pub(crate) fn decode(id: FileId, bytes: FileResult<Bytes>, stale: Option<Source>) -> FileResult<Source> {
    let bytes = bytes?;
    let data = bytes.as_slice();
    let text = std::str::from_utf8(data.strip_prefix(b"\xef\xbb\xbf").unwrap_or(data))
        .map_err(|_| typst::diag::FileError::InvalidUtf8)?;
    Ok(match stale {
        Some(mut source) => {
            source.replace(text);
            source
        }
        None => Source::new(id, text.into()),
    })
}

/// One SVG per page, separated by NUL bytes, which SVG text can't contain. `cache` keeps the last
/// compile's pages by layout hash, so unchanged pages aren't rendered again.
pub(crate) fn svg_pages(cache: &Mutex<HashMap<u128, Arc<str>>>, doc: &PagedDocument) -> Vec<u8> {
    let mut cache = cache.lock();
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
pub(crate) fn display_path(id: FileId) -> String {
    let path = id.vpath().get_without_slash();
    match id.root() {
        VirtualRoot::Project => path.to_string(),
        VirtualRoot::Package(spec) => format!("{spec}/{path}"),
    }
}

fn lines(world: &dyn World, id: FileId) -> Option<Lines<String>> {
    match world.source(id) {
        Ok(source) => Some(source.lines().clone()),
        Err(_) => world.file(id).ok()?.lines().ok(),
    }
}

#[derive(Serialize)]
pub(crate) struct DiagnosticJSON {
    path: String,
    line: usize,
    column: usize,
    severity: &'static str,
    message: String,
}

pub(crate) fn diagnostic(world: &dyn World, diag: &SourceDiagnostic) -> DiagnosticJSON {
    let severity = match diag.severity {
        Severity::Error => "error",
        Severity::Warning => "warning",
    };
    let mut out = DiagnosticJSON { path: String::new(), line: 1, column: 1, severity, message: diag.message.to_string() };
    let Some(id) = diag.span.id() else { return out };
    out.path = display_path(id);
    if let (Some(range), Some(lines)) = (world.range(diag.span), lines(world, id))
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

pub(crate) fn typst_version() -> &'static str {
    // typst-bridge pins typst exactly, so the manifest is the source of truth.
    const MANIFEST: &str = include_str!("../Cargo.toml");
    MANIFEST
        .lines()
        .find_map(|l| l.strip_prefix("typst = \"="))
        .and_then(|l| l.strip_suffix('"'))
        .unwrap_or("unknown")
}

// MARK: - Highlighting

/// Token classes for the editor, typst's highlighting tags plus a few finer ones.
#[repr(u8)]
#[derive(Clone, Copy, PartialEq)]
enum HlTag {
    Plain = 0,
    Comment,
    Punctuation,
    Escape,
    Strong,
    Emph,
    Link,
    Raw,
    Label,
    Ref,
    Heading,
    ListMarker,
    ListTerm,
    MathDelimiter,
    MathOperator,
    Keyword,
    Operator,
    Number,
    String,
    Function,
    Interpolated,
    Error,
    /// A named argument, dictionary key or closure parameter.
    Param,
    /// The unit of a numeric literal, like `mm` in `15mm`.
    Unit,
}

const HL_BOLD: u32 = 1;
const HL_ITALIC: u32 = 2;
const HL_MATH: u32 = 4;

fn hl_tag(tag: Tag) -> HlTag {
    match tag {
        Tag::Comment => HlTag::Comment,
        Tag::Punctuation | Tag::MathGroupingParens => HlTag::Punctuation,
        Tag::Escape => HlTag::Escape,
        Tag::Strong => HlTag::Strong,
        Tag::Emph => HlTag::Emph,
        Tag::Link => HlTag::Link,
        Tag::Raw => HlTag::Raw,
        Tag::Label => HlTag::Label,
        Tag::Ref => HlTag::Ref,
        Tag::Heading => HlTag::Heading,
        Tag::ListMarker => HlTag::ListMarker,
        Tag::ListTerm => HlTag::ListTerm,
        Tag::MathDelimiter => HlTag::MathDelimiter,
        Tag::MathOperator => HlTag::MathOperator,
        Tag::Keyword => HlTag::Keyword,
        Tag::Operator => HlTag::Operator,
        Tag::Number => HlTag::Number,
        Tag::String => HlTag::String,
        Tag::Function => HlTag::Function,
        Tag::Interpolated => HlTag::Interpolated,
        Tag::Error => HlTag::Error,
    }
}

/// Names that typst's highlighter leaves plain: `top` in `(top: 1cm)` and `x` in `(x, y) => …`.
fn is_param(node: &LinkedNode) -> bool {
    if node.kind() != SyntaxKind::Ident {
        return false;
    }
    match node.parent_kind() {
        Some(SyntaxKind::Named) => node.prev_sibling().is_none(),
        Some(SyntaxKind::Params) => true,
        Some(SyntaxKind::Spread) => node.parent().and_then(|p| p.parent_kind()) == Some(SyntaxKind::Params),
        _ => false,
    }
}

/// The innermost tag around a leaf, with bold, italic and math inherited from its ancestors.
fn classify(leaf: &LinkedNode) -> (HlTag, u32) {
    let mut tag = None;
    let mut flags = 0;
    let mut node = Some(leaf.clone());
    while let Some(n) = node {
        if tag.is_none() {
            tag = if is_param(&n) { Some(HlTag::Param) } else { typst::syntax::highlight(&n).map(hl_tag) };
        }
        match n.kind() {
            SyntaxKind::Strong | SyntaxKind::Heading => flags |= HL_BOLD,
            SyntaxKind::Emph => flags |= HL_ITALIC,
            SyntaxKind::Equation => flags |= HL_MATH,
            SyntaxKind::TermItem if tag == Some(HlTag::ListTerm) => flags |= HL_BOLD,
            _ => {}
        }
        node = n.parent().cloned();
    }
    (tag.unwrap_or(HlTag::Plain), flags)
}

pub(crate) fn highlight_runs(text: &str, code: bool) -> Vec<u32> {
    let root = if code { typst::syntax::parse_code(text) } else { typst::syntax::parse(text) };
    let mut runs = Vec::new();
    let mut offset = 0u32;
    let mut push = |runs: &mut Vec<u32>, len: u32, tag: HlTag, flags: u32| {
        if len > 0 && (tag != HlTag::Plain || flags != 0) {
            // Neighbours with the same style merge into one run.
            let n = runs.len();
            let packed = tag as u32 | flags << 8;
            if n >= 3 && runs[n - 1] == packed && runs[n - 3] + runs[n - 2] == offset {
                runs[n - 2] += len;
            } else {
                runs.extend([offset, len, packed]);
            }
        }
        offset += len;
    };
    fn walk(node: LinkedNode, f: &mut dyn FnMut(&LinkedNode)) {
        if node.get().children().len() == 0 {
            f(&node);
        } else {
            for child in node.children() {
                walk(child, f);
            }
        }
    }
    walk(LinkedNode::new(&root), &mut |leaf| {
        let text = leaf.get().leaf_text().as_str();
        let (tag, flags) = classify(leaf);
        if leaf.kind() == SyntaxKind::Numeric {
            // `15mm` and `50%` show the magnitude and the unit apart.
            let split = text.trim_end_matches(|c: char| c.is_ascii_alphabetic() || c == '%').len();
            push(&mut runs, text[..split].encode_utf16().count() as u32, tag, flags);
            push(&mut runs, text[split..].encode_utf16().count() as u32, HlTag::Unit, flags);
        } else {
            push(&mut runs, text.encode_utf16().count() as u32, tag, flags);
        }
    });
    runs
}

// MARK: - Refactoring

#[derive(serde::Deserialize)]
struct RefactorRequest {
    op: String,
    text: String,
    start: usize,
    #[serde(default)]
    length: usize,
    #[serde(default)]
    all: bool,
    /// UTF-16 start of the scope to put an extracted function in.
    scope: Option<usize>,
}

/// Runs a refactoring described by a JSON request and answers in JSON; see the C header.
pub(crate) fn refactor_json(request: &str) -> String {
    match serde_json::from_str::<RefactorRequest>(request) {
        Ok(r) => {
            let taken = |name: &str| LIBRARY.global.scope().get(name).is_some();
            let response = match r.op.as_str() {
                "candidates" => refactor::candidates(&r.text, r.start, r.length),
                "extract" => refactor::extract(&r.text, r.start, r.length, r.all, taken),
                "scopes" => refactor::function_scopes(&r.text, r.start, r.length),
                "function" => refactor::extract_function(&r.text, r.start, r.length, r.scope, taken),
                "symbol" => refactor::symbol(&r.text, r.start),
                "usages" => refactor::usages(&r.text, r.start),
                _ => refactor::inline(&r.text, r.start),
            };
            serde_json::to_string(&response).unwrap_or_default()
        }
        Err(e) => format!("{{\"error\":\"{e}\"}}"),
    }
}
