//! typst in process, with a world that serves unsaved buffers from memory: `ffi` is the Mac app's C
//! interface over the file system, `web` the browser's, where the page hands over files and packages.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock};

mod markdown;
mod refactor;
mod solveng;

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
use typst::foundations::{Bytes, Value};
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
            .unwrap_or_else(|| Arc::from(selectable_svg(page)));
        if i > 0 {
            out.push(0);
        }
        out.extend_from_slice(svg.as_bytes());
        next.insert(hash, svg);
    }
    *cache = next;
    out
}

// MARK: - solveng

#[derive(Serialize, Default)]
struct SolvengReport {
    /// How many `worksheet`s (and resets in them) reported; none means solveng didn't run or predates reports.
    blocks: usize,
    /// Equations and raw elements a `worksheet` saw, by their source.
    elements: Vec<SolvengElement>,
    /// Everything the blocks defined, the later definition of a name winning.
    defined: Vec<SolvengValue>,
    units: Vec<SolvengValue>,
}

#[derive(Serialize)]
struct SolvengElement {
    path: String,
    /// UTF-16 range in the file, and the source there when compiled, to find it again after edits.
    start: usize,
    end: usize,
    text: String,
    kind: String,
    active: bool,
    integration: String,
    evaluate: bool,
}

#[derive(Serialize)]
struct SolvengValue {
    name: String,
    kind: String,
    value: String,
}

/// What solveng's `worksheet`s report as `<solveng>` metadata, as JSON. Each element names the equation or raw
/// element by its location; its span leads back to the source, as clicking in the preview does.
pub(crate) fn solveng_report(world: &dyn World, introspector: &dyn typst::introspection::Introspector) -> String {
    use typst::foundations::{Dict, Label, Selector};
    use typst::introspection::{Location, MetadataElem};
    let mut report = SolvengReport::default();
    let Some(label) = Label::new(typst::utils::PicoStr::intern("solveng")) else { return "{}".into() };
    let text = |d: &Dict, key: &str| match d.get(key) {
        Ok(Value::Str(s)) => s.to_string(),
        _ => String::new(),
    };
    let values = |d: &Dict, key: &str| -> Vec<SolvengValue> {
        let Ok(Value::Array(items)) = d.get(key) else { return Vec::new() };
        items
            .iter()
            .filter_map(|v| match v {
                Value::Dict(e) => Some(SolvengValue { name: text(e, "name"), kind: text(e, "kind"), value: text(e, "value") }),
                _ => None,
            })
            .collect()
    };
    for content in introspector.query(&Selector::Label(label)) {
        let Some(meta) = content.to_packed::<MetadataElem>() else { continue };
        let Value::Dict(d) = &meta.value else { continue };
        let kind = text(d, "kind");
        if kind == "block" {
            report.blocks += 1;
            for v in values(d, "defined") {
                report.defined.retain(|e| e.name != v.name);
                report.defined.push(v);
            }
            for v in values(d, "units") {
                report.units.retain(|e| e.name != v.name);
                report.units.push(v);
            }
            continue;
        }
        let Ok(location) = d.get("element").cloned().and_then(|v| v.cast::<Location>().map_err(|e| e.message().clone()))
        else {
            continue;
        };
        let Some(element) = introspector.query_first(&Selector::Location(location)) else { continue };
        let span = element.span();
        let (Some(id), Some(range)) = (span.id(), world.range(span)) else { continue };
        let Ok(source) = world.source(id) else { continue };
        let Some(code) = source.text().get(range.clone()) else { continue };
        let start = source.text()[..range.start].encode_utf16().count();
        report.elements.push(SolvengElement {
            path: display_path(id),
            start,
            end: start + code.encode_utf16().count(),
            text: code.to_string(),
            kind,
            active: matches!(d.get("active"), Ok(Value::Bool(true))),
            integration: match d.get("evaluate") {
                Ok(Value::Bool(false)) => "none".into(),
                Ok(Value::Bool(true)) => "math".into(),
                _ => text(d, "integration"),
            },
            evaluate: match d.get("evaluate") {
                Ok(Value::Bool(evaluate)) => *evaluate,
                _ => text(d, "integration") != "none",
            },
        });
    }
    serde_json::to_string(&report).unwrap_or_else(|_| "{}".into())
}

/// typst draws glyphs as paths; invisible text over each run lets the preview select and copy it.
fn selectable_svg(page: &typst_layout::Page) -> String {
    let svg = typst_svg::svg(page, &SvgOptions::default());
    let mut layer = String::from(r#"<g class="tw-text">"#);
    text_layer(&page.frame, typst::layout::Transform::identity(), &mut layer);
    layer.push_str("</g>");
    match svg.rfind("</svg>") {
        Some(end) => format!("{}{layer}{}", &svg[..end], &svg[end..]),
        None => svg,
    }
}

fn text_layer(frame: &typst::layout::Frame, ts: typst::layout::Transform, out: &mut String) {
    use std::fmt::Write;
    use typst::layout::{FrameItem, Transform};
    for (pos, item) in frame.items() {
        let ts = ts.pre_concat(Transform::translate(pos.x, pos.y));
        match item {
            FrameItem::Group(group) => text_layer(&group.frame, ts.pre_concat(group.transform), out),
            FrameItem::Text(text) => {
                let width = text.width().to_pt();
                if text.text.trim().is_empty() || width <= 0.0 {
                    continue;
                }
                let escaped = text.text.as_str().replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
                let _ = write!(
                    out,
                    r#"<text transform="matrix({} {} {} {} {} {})" font-size="{}" textLength="{}" lengthAdjust="spacingAndGlyphs">{}</text>"#,
                    ts.sx.get(),
                    ts.ky.get(),
                    ts.kx.get(),
                    ts.sy.get(),
                    ts.tx.to_pt(),
                    ts.ty.to_pt(),
                    text.size.to_pt(),
                    width,
                    escaped,
                );
            }
            _ => {}
        }
    }
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

// MARK: - Hidden syntax

/// Math the editor shows as it renders while the caret is elsewhere: symbol names and shorthands as their symbol,
/// text without its quotes. Five UTF-16 values per entry: start, length, replacement character (0 hides the range),
/// and the start and end of the equation it belongs to.
pub(crate) fn conceal_runs(text: &str) -> Vec<u32> {
    // UTF-16 offset of every byte offset, since the tree counts bytes.
    let mut utf16 = vec![0u32; text.len() + 1];
    let mut count = 0u32;
    for (i, c) in text.char_indices() {
        for b in 0..c.len_utf8() {
            utf16[i + b] = count;
        }
        count += c.len_utf16() as u32;
    }
    utf16[text.len()] = count;
    let root = typst::syntax::parse(text);
    let mut out = Vec::new();
    find_equations(&LinkedNode::new(&root), text, &utf16, &mut out);
    out
}

fn find_equations(node: &LinkedNode, src: &str, utf16: &[u32], out: &mut Vec<u32>) {
    if node.kind() == SyntaxKind::Escape {
        // An escape is its own group, revealed on its own.
        let range = node.range();
        return conceal_escape(node, (utf16[range.start], utf16[range.end]), utf16, out);
    }
    if node.kind() == SyntaxKind::Equation {
        let range = node.range();
        let equation = (utf16[range.start], utf16[range.end]);
        for child in node.children() {
            conceal_math(&child, src, equation, utf16, out);
        }
        return;
    }
    for child in node.children() {
        find_equations(&child, src, utf16, out);
    }
}

fn conceal_math(node: &LinkedNode, src: &str, equation: (u32, u32), utf16: &[u32], out: &mut Vec<u32>) {
    // `#` switches to code, where strings are strings.
    if node.prev_sibling_kind() == Some(SyntaxKind::Hash) || node.kind() == SyntaxKind::Hash {
        return;
    }
    let range = node.range();
    let text = &src[range.clone()];
    let mut push = |start: usize, end: usize, replacement: u32| {
        out.extend([utf16[start], utf16[end] - utf16[start], replacement, equation.0, equation.1]);
    };
    match node.kind() {
        SyntaxKind::Str => {
            if text.len() >= 2 && text.starts_with('"') && text.ends_with('"') && !text.contains(['\n', '\r']) {
                push(range.start, range.start + 1, 0);
                push(range.end - 1, range.end, 0);
            }
        }
        SyntaxKind::MathIdent => {
            if let Some(c) = math_symbol(text, &[]) {
                push(range.start, range.end, c);
            }
        }
        SyntaxKind::Escape => conceal_escape(node, equation, utf16, out),
        SyntaxKind::MathShorthand => {
            // `*` would show as a `∗` that looks just like it.
            if text == "*" {
                return;
            }
            if let Some(shorthand) = node.cast::<typst::syntax::ast::MathShorthand>() {
                let c = shorthand.get() as u32;
                if c <= 0xFFFF {
                    push(range.start, range.end, c);
                }
            }
        }
        SyntaxKind::MathFieldAccess => {
            // `arrow.r.double`: a symbol with modifiers, shown whole or not at all.
            let mut parts = text.split('.');
            let base = parts.next().unwrap_or_default();
            let modifiers: Vec<&str> = parts.collect();
            let simple = node.children().all(|c| {
                matches!(c.kind(), SyntaxKind::MathIdent | SyntaxKind::Dot | SyntaxKind::MathFieldAccess)
            });
            if simple && let Some(c) = math_symbol(base, &modifiers) {
                push(range.start, range.end, c);
            }
        }
        _ => {
            for child in node.children() {
                conceal_math(&child, src, equation, utf16, out);
            }
        }
    }
}

/// `\.` as `.`, `\u{2014}` as `—`: the escaped character in place of its source.
fn conceal_escape(node: &LinkedNode, group: (u32, u32), utf16: &[u32], out: &mut Vec<u32>) {
    let Some(escape) = node.cast::<typst::syntax::ast::Escape>() else { return };
    let c = escape.get() as u32;
    let range = node.range();
    if c <= 0xFFFF && c != 0 {
        out.extend([utf16[range.start], utf16[range.end] - utf16[range.start], c, group.0, group.1]);
    }
}

/// The single BMP character a math symbol name like `Omega` or `arrow` with `["r"]` stands for.
fn math_symbol(name: &str, modifiers: &[&str]) -> Option<u32> {
    let Value::Symbol(symbol) = LIBRARY.math.scope().get(name)?.read() else { return None };
    let mut symbol = symbol.clone();
    for modifier in modifiers {
        symbol = symbol.modified((), modifier).ok()?;
    }
    let mut chars = symbol.get().chars();
    let c = chars.next()? as u32;
    (chars.next().is_none() && c <= 0xFFFF).then_some(c)
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

#[cfg(test)]
mod conceal_tests {
    use super::conceal_runs;

    fn shown(text: &str) -> String {
        let runs = conceal_runs(text);
        let units: Vec<u16> = text.encode_utf16().collect();
        let mut result = Vec::new();
        let mut i = 0;
        for run in runs.chunks(5) {
            let (start, len, c) = (run[0] as usize, run[1] as usize, run[2]);
            result.extend_from_slice(&units[i..start]);
            if c != 0 {
                result.push(c as u16);
            }
            i = start + len;
        }
        result.extend_from_slice(&units[i..]);
        String::from_utf16(&result).unwrap()
    }

    #[test]
    fn conceals_math() {
        assert_eq!(shown(r#"R = $12"k"Omega$ and "k" Omega"#), r#"R = $12kΩ$ and "k" Omega"#);
        assert_eq!(shown("$a -> b != c, arrow.r.double, alpha sqrt(x)$"), "$a → b ≠ c, ⇒, α sqrt(x)$");
        assert_eq!(shown(r#"$#"x" + "y"$"#), r#"$#"x" + y$"#);
        assert_eq!(shown("$cos(pi*t)$"), "$cos(π*t)$");
        assert_eq!(shown(r"1\. Rechenübung \# \u{2014} $a \$ b$ #raw(`\.`) \"), r"1. Rechenübung # — $a $ b$ #raw(`\.`) \");
    }

    #[test]
    fn conceals_empty_strings_after_symbols() {
        let source = "$ Sigma\"\"r := 1 + 3/3x+y^2 $\n$ Σ\"\"r -> $";
        assert_eq!(shown(source), "$ Σr ≔ 1 + 3/3x+y^2 $\n$ Σr → $");
    }

    #[test]
    fn leaves_broken_multiline_math_strings_visible() {
        let source = "$ Σ\"\"r \"-> $\n  $ Σ\"\"r -> $\n  $ Σ\"\"r -> $";
        let shown = shown(source);
        assert!(shown.contains("\"-> $\n"), "{shown}");
        assert!(shown.contains("$ Σ\"\"r -> $"), "{shown}");
    }
}
