//! GitHub flavored Markdown to HTML for the preview.

use std::sync::LazyLock;

use comrak::nodes::{NodeHtmlBlock, NodeValue};
use comrak::options::Plugins;
use comrak::plugins::syntect::SyntectAdapter;
use comrak::{Arena, Options, format_html_with_plugins, parse_document};
use serde::Serialize;
use pulldown_latex::config::DisplayMode;
use pulldown_latex::{Parser, RenderConfig, Storage, push_mathml};

/// Code gets CSS classes, so the page can color it for light and dark mode.
static HIGHLIGHTER: LazyLock<SyntectAdapter> = LazyLock::new(|| SyntectAdapter::new(None));

fn options() -> Options<'static> {
    let mut o = Options::default();
    let e = &mut o.extension;
    e.strikethrough = true;
    e.table = true;
    e.autolink = true;
    e.tasklist = true;
    e.footnotes = true;
    e.alerts = true;
    e.math_dollars = true;
    e.math_code = true;
    e.shortcodes = true;
    e.header_id_prefix = Some(String::new());
    e.front_matter_delimiter = Some("---".into());
    o.render.r#unsafe = true;
    o.render.github_pre_lang = true;
    o.render.tasklist_classes = true;
    o
}

fn mathml(latex: &str, display: bool) -> String {
    let storage = Storage::new();
    let parser = Parser::new(latex, &storage);
    let config = RenderConfig {
        display_mode: if display { DisplayMode::Block } else { DisplayMode::Inline },
        ..RenderConfig::default()
    };
    let mut out = String::new();
    if push_mathml(&mut out, parser, config).is_err() {
        return format!("<code>{}</code>", escape(latex));
    }
    out
}

fn escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Math snippets in older solveng documentation use the editor's token colours.
fn solveng_html(text: &str) -> String {
    const CLASS: [&str; 15] = ["tw-keyword", "tw-string", "tw-comment", "tw-number", "tw-function", "tw-type", "tw-param", "tw-label", "tw-keyword", "tw-unit", "tw-param tw-parameter", "tw-keyword tw-evaluate", "tw-param", "tw-function", "tw-comment"];
    let tokens = solveng_ide::math_tokens_of(text);
    let units: Vec<u16> = text.encode_utf16().collect();
    let piece = |a: usize, b: usize| escape(&String::from_utf16_lossy(&units[a..b]));
    let (mut out, mut at) = (String::new(), 0);
    for t in tokens {
        let (start, end) = (t.start as usize, (t.start + t.length) as usize);
        if start < at || end > units.len() {
            continue;
        }
        out += &piece(at, start);
        out += &format!("<span class=\"{}\">{}</span>", CLASS.get(t.kind as usize).unwrap_or(&""), piece(start, end));
        at = end;
    }
    out + &piece(at, units.len())
}

pub fn to_html(markdown: &str) -> String {
    let arena = Arena::new();
    let options = options();
    let root = parse_document(&arena, markdown, &options);
    transform(root.descendants(), false);
    render(root, &options)
}

fn render<'a>(node: &'a comrak::nodes::AstNode<'a>, options: &Options) -> String {
    let mut plugins = Plugins::default();
    plugins.render.codefence_syntax_highlighter = Some(&*HIGHLIGHTER);
    let mut out = String::new();
    let _ = format_html_with_plugins(node, options, &mut out, &plugins);
    out
}

/// Math becomes MathML, which WebKit draws natively; Mermaid is left for its script. The editor keeps the TeX of
/// inline math, so it can write it back.
fn transform<'a>(nodes: impl Iterator<Item = &'a comrak::nodes::AstNode<'a>>, editor: bool) {
    for node in nodes {
        let replacement = match &node.data().value {
            NodeValue::Math(math) if editor => Some(NodeValue::HtmlInline(format!(
                "<span class=\"tw-math\" contenteditable=\"false\" data-tex=\"{}\"{}>{}</span>",
                attribute(&math.literal),
                if math.display_math { " data-display=\"\"" } else { "" },
                mathml(&math.literal, math.display_math)
            ))),
            NodeValue::Math(math) => Some(NodeValue::HtmlInline(mathml(&math.literal, math.display_math))),
            NodeValue::FootnoteReference(r) if editor => Some(NodeValue::HtmlInline(format!(
                "<sup class=\"tw-atom\" contenteditable=\"false\" data-md=\"[^{}]\">{}</sup>",
                attribute(&r.name),
                escape(&r.name)
            ))),
            NodeValue::CodeBlock(code) if code.info.trim() == "math" => Some(NodeValue::HtmlBlock(NodeHtmlBlock {
                block_type: 6,
                literal: format!("<div class=\"math-display\">{}</div>\n", mathml(&code.literal, true)),
            })),
            NodeValue::CodeBlock(code) if code.info.split_whitespace().next() == Some("solveng") => Some(NodeValue::HtmlBlock(NodeHtmlBlock {
                block_type: 6,
                literal: format!("<pre><code class=\"language-solveng\">{}</code></pre>\n", solveng_html(code.literal.trim_end())),
            })),
            NodeValue::CodeBlock(code) if code.info.trim() == "mermaid" => Some(NodeValue::HtmlBlock(NodeHtmlBlock {
                block_type: 6,
                literal: format!("<pre class=\"mermaid\">{}</pre>\n", escape(&code.literal)),
            })),
            _ => None,
        };
        if let Some(value) = replacement {
            node.data_mut().value = value;
        }
    }
}

fn attribute(text: &str) -> String {
    escape(text).replace('"', "&quot;")
}

// MARK: - Editor

/// One top-level block of the Markdown editor: a UTF-16 range of whole lines and what it shows. Text kinds
/// (`paragraph`, `heading`, `item`, `quote`, `callout`) carry their inline content as HTML after `prefix`, the
/// source before it on the first line; `code`, `math`, `solveng` and `mermaid` carry their source; everything else
/// is `raw`, shown rendered and edited as Markdown.
#[derive(Serialize, Default)]
pub struct Block {
    start: usize,
    end: usize,
    kind: &'static str,
    #[serde(skip_serializing_if = "String::is_empty")]
    html: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    prefix: String,
    #[serde(skip_serializing_if = "is_zero")]
    level: usize,
    #[serde(skip_serializing_if = "is_zero")]
    depth: usize,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    ordered: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    checked: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    alert: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    lang: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<String>,
    /// The closing fence of fenced code.
    #[serde(skip_serializing_if = "String::is_empty")]
    fence: String,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

/// Line starts in bytes and UTF-16 units, to turn comrak's line and byte column into UTF-16 offsets.
struct Lines<'t> {
    text: &'t str,
    starts: Vec<usize>,
    starts16: Vec<usize>,
}

impl<'t> Lines<'t> {
    fn new(text: &'t str) -> Self {
        let mut starts = vec![0];
        let mut starts16 = vec![0];
        let mut units = 0;
        for (i, c) in text.char_indices() {
            units += c.len_utf16();
            if c == '\n' {
                starts.push(i + 1);
                starts16.push(units);
            }
        }
        Lines { text, starts, starts16 }
    }

    fn start(&self, line: usize) -> usize {
        self.starts[(line.max(1) - 1).min(self.starts.len() - 1)]
    }

    /// The end of the line, before its line break.
    fn end(&self, line: usize) -> usize {
        let end = self.starts.get(line).map_or(self.text.len(), |next| next - 1);
        if end > self.start(line) && self.text.as_bytes()[end - 1] == b'\r' { end - 1 } else { end }
    }

    fn byte(&self, at: comrak::nodes::LineColumn) -> usize {
        (self.start(at.line) + at.column.max(1) - 1).min(self.end(at.line))
    }

    fn utf16(&self, byte: usize) -> usize {
        let line = self.starts.partition_point(|&s| s <= byte) - 1;
        let from = self.starts[line];
        let byte = (from..=byte).rev().find(|&b| self.text.is_char_boundary(b)).unwrap_or(from);
        self.starts16[line] + self.text[from..byte].encode_utf16().count()
    }
}

fn editor_options() -> Options<'static> {
    let mut o = options();
    o.extension.header_id_prefix = None;
    o.parse.escaped_char_spans = true;
    o.render.escaped_char_spans = true;
    o
}

fn alert_name(alert: comrak::nodes::AlertType) -> &'static str {
    use comrak::nodes::AlertType::*;
    match alert {
        Note => "note",
        Tip => "tip",
        Important => "important",
        Warning => "warning",
        Caution => "caution",
    }
}

type Node<'a> = &'a comrak::nodes::AstNode<'a>;

struct Splitter<'t> {
    lines: Lines<'t>,
    options: Options<'static>,
    blocks: Vec<Block>,
}

impl<'t> Splitter<'t> {
    fn range(&self, node: Node) -> (usize, usize) {
        let pos = node.data().sourcepos;
        (self.lines.start(pos.start.line), self.lines.end(pos.end.line.max(pos.start.line)))
    }

    fn push(&mut self, start: usize, end: usize, block: Block) {
        let (start, end) = (self.lines.utf16(start), self.lines.utf16(end));
        self.blocks.push(Block { start, end, ..block });
    }

    fn raw(&mut self, node: Node, wrap: Option<&str>) {
        let (start, end) = self.range(node);
        transform(node.descendants(), false);
        let html = render(node, &self.options);
        let html = match wrap {
            Some(tag) => format!("<{tag}>{html}</{tag}>"),
            None => html,
        };
        self.push(start, end, Block { kind: "raw", html, ..Block::default() });
    }

    /// The inline content of a paragraph or heading, without its own tag.
    fn inline(&self, node: Node) -> String {
        transform(node.descendants(), true);
        let html = render(node, &self.options);
        let html = html.trim_end_matches('\n');
        let open = html.find('>').filter(|_| html.starts_with("<p") || html.starts_with("<h"));
        match open {
            Some(open) => html[open + 1..].rsplit_once("</").map_or(&html[open + 1..], |(inner, _)| inner).to_string(),
            None => html.to_string(),
        }
    }

    /// A text block from the start of `line_of`'s first line to the end of `content`, whose inline content it shows.
    fn text(&mut self, line_of: Node, content: Option<Node>, block: Block) {
        let (start, mut end) = self.range(line_of);
        let (prefix_end, html) = match content {
            Some(p) => {
                end = self.range(p).1;
                let first = p.first_child().map_or(p.data().sourcepos.start, |c| c.data().sourcepos.start);
                (self.lines.byte(first), self.inline(p))
            }
            None => (end, String::new()),
        };
        let prefix = self.lines.text[start..prefix_end.max(start)].to_string();
        self.push(start, end, Block { html, prefix: if block.prefix.is_empty() { prefix } else { block.prefix }, ..block });
    }

    fn blocks(&mut self, parent: Node) {
        for node in parent.children() {
            self.block(node);
        }
    }

    fn block(&mut self, node: Node) {
        let value = node.data().value.clone();
        match value {
            NodeValue::Paragraph => {
                // A paragraph of display math alone is a math block.
                let only = node.first_child().filter(|c| c.next_sibling().is_none());
                if let Some(NodeValue::Math(math)) = only.map(|c| c.data().value.clone())
                    && math.display_math
                {
                    let (start, end) = self.range(node);
                    let code = Some(math.literal.trim().to_string());
                    return self.push(start, end, Block { kind: "math", code, ..Block::default() });
                }
                self.text(node, Some(node), Block { kind: "paragraph", ..Block::default() })
            }
            NodeValue::Heading(h) => {
                let prefix = if h.setext { format!("{} ", "#".repeat(h.level as usize)) } else { String::new() };
                let content = node.first_child().map(|_| node);
                self.text(node, content, Block { kind: "heading", level: h.level as usize, prefix, ..Block::default() })
            }
            NodeValue::ThematicBreak => {
                let (start, end) = self.range(node);
                self.push(start, end, Block { kind: "hr", ..Block::default() })
            }
            NodeValue::CodeBlock(code) if code.fenced => {
                let (start, end) = self.range(node);
                let lang = code.info.trim().to_string();
                let kind = match lang.split_whitespace().next().unwrap_or("") {
                    "solveng" => "solveng",
                    "math" => "math",
                    "mermaid" => "mermaid",
                    _ => "code",
                };
                let fence = format!("{}{}", " ".repeat(code.fence_offset), (code.fence_char as char).to_string().repeat(code.fence_length));
                let prefix = self.lines.text[start..self.lines.end(node.data().sourcepos.start.line)].to_string();
                let literal = code.literal.strip_suffix('\n').unwrap_or(&code.literal).to_string();
                self.push(start, end, Block { kind, lang: Some(lang), code: Some(literal), fence, prefix, ..Block::default() })
            }
            NodeValue::BlockQuote => match single_paragraph(node) {
                Some(p) => self.text(node, Some(p), Block { kind: "quote", ..Block::default() }),
                None => self.raw(node, None),
            },
            NodeValue::Alert(alert) if !alert.multiline => match single_paragraph(node) {
                Some(p) => self.text(node, Some(p), Block { kind: "callout", alert: Some(alert_name(alert.alert_type)), ..Block::default() }),
                None => self.raw(node, None),
            },
            NodeValue::List(list) => {
                let ordered = list.list_type == comrak::nodes::ListType::Ordered;
                let wrap = if ordered { "ol" } else { "ul" };
                for item in node.children() {
                    self.item(item, 0, ordered, wrap);
                }
            }
            _ => self.raw(node, None),
        }
    }

    /// A list item shows its first paragraph; nested lists follow as items one level deeper. Any other content
    /// makes the item raw.
    fn item(&mut self, item: Node, depth: usize, ordered: bool, wrap: &str) {
        let checked = match &item.data().value {
            NodeValue::TaskItem(task) => Some(task.symbol.is_some_and(|c| c != ' ')),
            _ => None,
        };
        let mut children = item.children().peekable();
        let first = children.next_if(|c| matches!(c.data().value, NodeValue::Paragraph));
        let rest: Vec<_> = children.collect();
        if rest.iter().any(|c| !matches!(c.data().value, NodeValue::List(_))) {
            return self.raw(item, Some(wrap));
        }
        self.text(item, first, Block { kind: "item", depth, ordered, checked, ..Block::default() });
        for list in rest {
            let NodeValue::List(nested) = list.data().value.clone() else { continue };
            let ordered = nested.list_type == comrak::nodes::ListType::Ordered;
            let wrap = if ordered { "ol" } else { "ul" };
            for child in list.children() {
                self.item(child, depth + 1, ordered, wrap);
            }
        }
    }
}

fn single_paragraph(node: Node) -> Option<Node> {
    let first = node.first_child()?;
    (first.next_sibling().is_none() && matches!(first.data().value, NodeValue::Paragraph)).then_some(first)
}

/// The editor's blocks of `markdown`, in order and never overlapping, as JSON.
pub fn blocks(markdown: &str) -> String {
    let arena = Arena::new();
    let options = editor_options();
    let root = parse_document(&arena, markdown, &options);
    let mut splitter = Splitter { lines: Lines::new(markdown), options, blocks: Vec::new() };
    splitter.blocks(root);
    // Blocks sharing a line (lazy continuations, odd nesting) become one raw block.
    let mut blocks: Vec<Block> = Vec::with_capacity(splitter.blocks.len());
    for block in splitter.blocks {
        match blocks.last_mut() {
            Some(last) if block.start < last.end => {
                let (start, end) = (last.start, last.end.max(block.end));
                let units: Vec<u16> = markdown.encode_utf16().collect();
                let source = String::from_utf16_lossy(&units[start..end.min(units.len())]);
                *last = Block { start, end, kind: "raw", html: to_html(&source), ..Block::default() };
            }
            _ => blocks.push(block),
        }
    }
    serde_json::to_string(&blocks).unwrap_or_else(|_| "[]".into())
}

/// One block of Markdown rendered for the editor, as its `blocks` would show it.
pub fn block_html(markdown: &str) -> String {
    let arena = Arena::new();
    let options = editor_options();
    let root = parse_document(&arena, markdown, &options);
    transform(root.descendants(), false);
    render(root, &options)
}

// MARK: - solveng notebooks

/// The names solveng's modules export, for importing what a notebook uses.
static MODULES: LazyLock<Vec<(&'static str, Vec<String>)>> = LazyLock::new(|| {
    ["operations", "units", "constants", "modifiers"]
        .into_iter()
        .map(|module| {
            let doc = format!("#import {module}: ");
            let result: serde_json::Value = serde_json::from_str(&crate::solveng::call("complete", &doc, "", doc.len() as u32)).unwrap_or_default();
            let names = result["items"].as_array().into_iter().flatten().filter_map(|i| i["label"].as_str().map(String::from)).collect();
            (module, names)
        })
        .collect()
});

/// Words of a math line that may name a binding, outside quotes; calls are marked, so they import operations first.
/// Single letters only count with a `#`, like typst reads them.
fn math_words(line: &str) -> Vec<(String, bool)> {
    let (mut words, mut quoted, mut at) = (Vec::new(), false, 0);
    let bytes = line.as_bytes();
    while at < bytes.len() {
        let c = bytes[at];
        if c == b'"' {
            quoted = !quoted;
            at += 1;
        } else if !quoted && c.is_ascii_alphabetic() && (at == 0 || !bytes[at - 1].is_ascii_alphanumeric()) {
            let hashed = at > 0 && bytes[at - 1] == b'#';
            let mut end = at + 1;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || hashed && matches!(bytes[end], b'_' | b'-')) {
                end += 1;
            }
            if end - at > 1 || hashed {
                words.push((line[at..end].to_string(), bytes.get(end) == Some(&b'(')));
            }
            at = end;
        } else {
            at += 1;
        }
    }
    words
}

/// A typst document calculating solveng `cells` in order, a page each, so later cells see earlier definitions, like
/// a notebook. A line is an equation unless it's code (`#import units: V`), a comment or already math; the
/// bindings the math uses are imported. `package` is the solveng to import, `@preview/solveng` by default.
pub fn notebook(cells: &[String], package: &str) -> String {
    let mut imports: Vec<(&str, Vec<&str>)> = Vec::new();
    let mut body = String::new();
    for (i, cell) in cells.iter().enumerate() {
        if i > 0 {
            body += "#pagebreak()\n";
        }
        let mut empty = true;
        for line in cell.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with("//") {
                continue;
            }
            if trimmed.starts_with('#') || trimmed.starts_with('$') {
                body += trimmed;
                body += "\n";
                if trimmed.starts_with('#') {
                    continue;
                }
            } else {
                body += &format!("$ {trimmed} $\n");
            }
            empty = false;
            for (word, call) in math_words(trimmed.trim_matches('$')) {
                let mut found = MODULES.iter().filter(|(_, names)| names.iter().any(|n| *n == word));
                let module = if call { found.next() } else { found.find(|(m, _)| *m != "operations").or_else(|| MODULES.iter().find(|(_, n)| n.iter().any(|n| *n == word))) };
                let Some((module, names)) = module else { continue };
                let name = names.iter().find(|n| **n == word).unwrap().as_str();
                match imports.iter_mut().find(|(m, _)| m == module) {
                    Some((_, list)) if !list.contains(&name) => list.push(name),
                    Some(_) => {}
                    None => imports.push((module, vec![name])),
                }
            }
        }
        if empty {
            body += "#box(height: 1em)\n";
        }
    }
    let package = if package.is_empty() { format!("@preview/solveng:{}", solveng_ide::VERSION) } else { package.to_string() };
    let mut out = format!("#import \"{package}\": *\n");
    for (module, names) in &imports {
        out += &format!("#import {module}: {}\n", names.join(", "));
    }
    out += &format!(
        "#set page(width: auto, height: auto, margin: (x: 1pt, y: 3pt), fill: none)\n#set text(size: 13pt)\n\
         #show math.equation.where(block: true): set align(left)\n#set par(spacing: 0.9em)\n#show: worksheet\n"
    );
    out + &body
}

/// Stylesheet for the highlighted code, light and dark.
pub fn code_css() -> String {
    use syntect::highlighting::ThemeSet;
    use syntect::html::{ClassStyle, css_for_theme_with_class_style};
    let themes = ThemeSet::load_defaults();
    let light = css_for_theme_with_class_style(&themes.themes["InspiredGitHub"], ClassStyle::Spaced).unwrap_or_default();
    let dark = css_for_theme_with_class_style(&themes.themes["base16-ocean.dark"], ClassStyle::Spaced).unwrap_or_default();
    // Each theme only styles some scopes; unscoped, the light theme's colours would leak into dark mode.
    format!("@media (prefers-color-scheme: light) {{\n{light}\n}}\n@media (prefers-color-scheme: dark) {{\n{dark}\n}}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_github_syntax() {
        let html = to_html(
            "# Title\n\n- [x] done\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n~~old~~ :smile: https://x.y\n\n> [!NOTE]\n> hi\n\n$x^2$\n\n```rust\nfn main() {}\n```\n\nfoot[^1]\n\n[^1]: note\n",
        );
        for needle in ["<h1", "checkbox", "<table", "<del>", "😄", "href=\"https://x.y\"", "markdown-alert", "<math", "<span class=", "footnote"] {
            assert!(html.contains(needle), "{needle} missing in {html}");
        }
        assert!(code_css().contains("prefers-color-scheme: light"));
        let html = to_html("```solveng\nU(x) := x_2^2 =\n```\n");
        assert!(html.contains("</span>_<span") && html.contains("class=\"tw-function\""), "{html}");
        assert!(html.contains("tw-evaluate"), "{html}");
    }

    fn parsed(markdown: &str) -> Vec<serde_json::Value> {
        serde_json::from_str::<Vec<serde_json::Value>>(&blocks(markdown)).unwrap()
    }

    #[test]
    fn splits_blocks_by_lines() {
        let text = "# Tïtle\n\nSome *text*\nwrapped $x^2$ \\*\n\n- one\n  - [x] two\n1. three\n\n> [!TIP]\n> hint\n\n```solveng\nU := 5 #V\n```\n\n| a |\n|---|\n| 1 |\n\n---\n$$\nx\n$$\n";
        let blocks = parsed(text);
        let units: Vec<u16> = text.encode_utf16().collect();
        let source = |b: &serde_json::Value| String::from_utf16(&units[b["start"].as_u64().unwrap() as usize..b["end"].as_u64().unwrap() as usize]).unwrap();
        let kinds: Vec<&str> = blocks.iter().map(|b| b["kind"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["heading", "paragraph", "item", "item", "item", "callout", "solveng", "raw", "hr", "math"]);
        assert_eq!(source(&blocks[0]), "# Tïtle");
        assert_eq!(blocks[0]["prefix"], "# ");
        assert_eq!(source(&blocks[1]), "Some *text*\nwrapped $x^2$ \\*");
        let html = blocks[1]["html"].as_str().unwrap();
        assert!(html.starts_with("Some <em>text</em>") && html.contains("data-tex=\"x^2\"") && html.contains("data-escaped-char"), "{html}");
        assert_eq!((source(&blocks[3]).as_str(), blocks[3]["prefix"].as_str(), &blocks[3]["checked"], &blocks[3]["depth"]), ("  - [x] two", Some("  - [x] "), &serde_json::json!(true), &serde_json::json!(1)));
        assert_eq!(blocks[4]["ordered"], true);
        assert_eq!((blocks[5]["prefix"].as_str(), blocks[5]["alert"].as_str()), (Some("> [!TIP]\n> "), Some("tip")));
        assert_eq!((blocks[6]["code"].as_str(), blocks[6]["fence"].as_str()), (Some("U := 5 #V"), Some("```")));
        assert!(blocks[7]["html"].as_str().unwrap().contains("<table"));
        assert_eq!(blocks[9]["code"], "x");
    }

    #[test]
    fn notebooks_import_what_cells_use() {
        let doc = notebook(&["Q_0 := 3450 mAh\nI := 30 mA".into(), "t := Q_0 / I = #h\nQ_0/2 = I t -> solve(t)".into()], "");
        assert!(doc.contains("#import units: mAh, mA, h"), "{doc}");
        assert!(doc.contains("#import modifiers: solve"), "{doc}");
        assert!(doc.contains("$ t := Q_0 / I = #h $\n"), "{doc}");
        assert_eq!(doc.matches("#pagebreak()").count(), 1);
    }
}
