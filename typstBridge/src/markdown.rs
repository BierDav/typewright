//! GitHub flavored Markdown to HTML for the preview.

use std::sync::LazyLock;

use comrak::nodes::{NodeHtmlBlock, NodeValue};
use comrak::options::Plugins;
use comrak::plugins::syntect::SyntectAdapter;
use comrak::{Arena, Options, format_html_with_plugins, parse_document};
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

/// The units of a solveng fence's info: `solveng units=bar,ü`.
fn fence_units(info: &str) -> Vec<String> {
    info.split_whitespace().find_map(|w| w.strip_prefix("units=")).map(|u| u.split(',').filter(|u| !u.is_empty()).map(String::from).collect()).unwrap_or_default()
}

/// solveng code as documentation shows it (A², x₂), coloured with the editor's classes.
fn solveng_html(code: &str, units: &[String]) -> String {
    const CLASS: [&str; 11] = ["tw-keyword", "tw-string", "tw-comment", "tw-number", "tw-function", "tw-type", "tw-param", "tw-label", "tw-keyword", "tw-unit", "tw-param tw-parameter"];
    let (text, tokens) = solveng_ide::pretty(code, units);
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
    // Math becomes MathML, which WebKit draws natively; Mermaid is left for its script.
    for node in root.descendants() {
        let replacement = match &node.data().value {
            NodeValue::Math(math) => Some(NodeValue::HtmlInline(mathml(&math.literal, math.display_math))),
            NodeValue::CodeBlock(code) if code.info.trim() == "math" => Some(NodeValue::HtmlBlock(NodeHtmlBlock {
                block_type: 6,
                literal: format!("<div class=\"math-display\">{}</div>\n", mathml(&code.literal, true)),
            })),
            // ```solveng units=bar,ü: the document's own units
            NodeValue::CodeBlock(code) if code.info.split_whitespace().next() == Some("solveng") => Some(NodeValue::HtmlBlock(NodeHtmlBlock {
                block_type: 6,
                literal: format!("<pre><code class=\"language-solveng\">{}</code></pre>\n", solveng_html(code.literal.trim_end(), &fence_units(&code.info))),
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
    let mut plugins = Plugins::default();
    plugins.render.codefence_syntax_highlighter = Some(&*HIGHLIGHTER);
    let mut out = String::new();
    let _ = format_html_with_plugins(root, &options, &mut out, &plugins);
    out
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
        let html = to_html("```solveng units=über\nU(x: V): A^2 = 2 x_2 * [3 über]\n```\n");
        assert!(html.contains("<span class=\"tw-unit\">über</span>"), "{html}");
        assert!(html.contains("<span class=\"tw-unit\">²</span>") && html.contains("x₂") && html.contains("class=\"tw-function\""), "{html}");
    }
}
