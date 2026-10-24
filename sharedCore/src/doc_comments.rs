//! Docs of functions that take their parameters through `..args`, like a package's override of `grid`, read from
//! their tidy-style `///` comments. tinymist only documents the parameters a signature names, so it drops these.

/// One `- name (types): …` item of a doc comment.
#[derive(Clone, Debug, PartialEq)]
struct Parameter {
    name: String,
    /// `auto | int`.
    types: String,
    default: Option<String>,
    positional: bool,
    variadic: bool,
    /// Paragraphs, without the `Default:` and `This parameter is …` sentences.
    docs: Vec<String>,
}

#[derive(Debug, PartialEq)]
struct Documented {
    name: String,
    description: String,
    parameters: Vec<Parameter>,
    returns: Option<String>,
}

/// The function defined on `line` (zero-based) of `source` as tinymist's hover shows functions: a `let name(…)`
/// signature, the description and a section per parameter. None unless its doc comment documents parameters
/// its signature doesn't name.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn overridden_function_docs(source: &str, line: i32) -> Option<String> {
    documented(source, line).map(|f| render(&f))
}

/// One parameter of such a function, for hovering its argument: its signature and docs.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn overridden_parameter_docs(source: &str, line: i32, name: &str) -> Option<String> {
    let f = documented(source, line)?;
    let p = f.parameters.iter().find(|p| p.name == name)?;
    Some(format!("```typc\n{}\n```\n\n{}", signature_entry(p), p.docs.join("\n\n")).trim_end().to_string())
}

/// tinymist's hover after it failed to evaluate a doc comment as typst (an example like `#show: f(…)` in a plain
/// `//` comment): its error block goes, the raw comment stays, with lines starting with `#` shown as code.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn repair_unparsed_docs(markdown: &str) -> String {
    const ERROR: &str = "```\nfailed to parse docs:";
    let Some(start) = markdown.find(ERROR) else { return markdown.to_string() };
    let Some(error_end) = markdown[start + ERROR.len()..].find("\n```\n").map(|i| start + ERROR.len() + i + 5) else {
        return markdown.to_string();
    };
    let rest = &markdown[error_end..];
    let raw = rest.trim_start_matches('\n');
    let Some(body) = raw.strip_prefix("```typ\n") else {
        return format!("{}{}", &markdown[..start], raw);
    };
    let Some(close) = body.find("\n```") else { return markdown.to_string() };
    let mut out = String::new();
    let mut in_code = false;
    for line in body[..close].lines() {
        let code = line.trim_start().starts_with('#');
        if code != in_code {
            out.push_str(if code { "\n```typ\n" } else { "```\n\n" });
            in_code = code;
        }
        out.push_str(line);
        out.push('\n');
    }
    if in_code {
        out.push_str("```\n");
    }
    format!("{}{}{}", &markdown[..start], out.trim_start_matches('\n'), &body[close + 4..])
}

fn documented(source: &str, line: i32) -> Option<Documented> {
    let lines: Vec<&str> = crate::utf16::lines(source).collect();
    let line = usize::try_from(line).ok()?;
    let (name, named) = signature(&lines, line)?;
    let comment: Vec<&str> = lines[..line]
        .iter()
        .rev()
        .map_while(|l| l.trim_start().strip_prefix("///"))
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .map(|l| l.strip_prefix(' ').unwrap_or(l))
        .collect();
    let f = parse(name, &comment);
    f.parameters.iter().any(|p| !named.contains(&p.name)).then_some(f)
}

/// The name and parameter names of the `let name(…)` starting on `line`, without rest parameters.
fn signature(lines: &[&str], line: usize) -> Option<(String, Vec<String>)> {
    let first = lines.get(line)?;
    let at = first.find("let ")?;
    let rest = first[at + 4..].trim_start();
    let paren = rest.find('(')?;
    let name = rest[..paren].trim();
    if name.is_empty() || !name.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-') {
        return None;
    }
    // Up to the closing parenthesis, which may be lines further down.
    let mut text = rest[paren + 1..].to_string();
    for next in lines.iter().skip(line + 1).take(50) {
        text.push('\n');
        text.push_str(next);
    }
    let (mut depth, mut end) = (0, None);
    for (i, c) in text.char_indices() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' if depth == 0 => {
                end = Some(i);
                break;
            }
            ')' | ']' | '}' => depth -= 1,
            _ => {}
        }
    }
    let names = split_top(&text[..end?])
        .into_iter()
        .map(|p| p.split(':').next().unwrap_or("").trim().to_string())
        .filter(|p| !p.is_empty() && !p.starts_with(".."))
        .collect();
    Some((name.to_string(), names))
}

fn parse(name: String, comment: &[&str]) -> Documented {
    let mut description: Vec<String> = vec![];
    let mut parameters: Vec<Parameter> = vec![];
    let mut returns = None;
    let mut i = 0;
    while i < comment.len() {
        let line = comment[i];
        if let Some(ty) = line.strip_prefix("->") {
            returns = Some(ty.trim().to_string()).filter(|t| !t.is_empty());
            i += 1;
            continue;
        }
        let Some(item) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) else {
            description.push(line.to_string());
            i += 1;
            continue;
        };
        // The header, whose types may wrap onto further lines, up to `):`.
        let mut header = item.to_string();
        let mut j = i + 1;
        while !header.contains("):") && j < comment.len() && comment[j].starts_with(' ') && j - i < 5 {
            header.push(' ');
            header.push_str(comment[j].trim());
            j += 1;
        }
        let Some((names, types, first)) = item_header(&header) else {
            description.push(line.to_string());
            i += 1;
            continue;
        };
        // Its docs: the rest of the header and every indented or blank line after it.
        let mut body = vec![first];
        while j < comment.len() && (comment[j].trim().is_empty() || comment[j].starts_with(' ')) {
            body.push(comment[j].to_string());
            j += 1;
        }
        let indent = body.iter().skip(1).filter(|l| !l.trim().is_empty()).map(|l| l.len() - l.trim_start().len()).min();
        let body: Vec<&str> = body.iter().enumerate().map(|(k, l)| if k == 0 { l.as_str() } else { l.get(indent.unwrap_or(0)..).unwrap_or("") }).collect();
        let (docs, default, roles) = parameter_docs(&body.join("\n"));
        let variadic = types.trim_end().ends_with("...");
        let types = types.split(',').map(str::trim).filter(|t| !t.is_empty() && *t != "..." && *t != "…").collect::<Vec<_>>().join(" | ");
        for name in names {
            parameters.push(Parameter {
                name,
                types: types.clone(),
                default: default.clone(),
                positional: roles.iter().any(|r| r == "positional") || variadic,
                variadic,
                docs: docs.clone(),
            });
        }
        i = j;
    }
    let description = split_paragraphs(&description.join("\n")).iter().map(|p| unwrap(p)).collect::<Vec<_>>().join("\n\n");
    Documented { name, description, parameters, returns }
}

/// `names (types): rest` split up; names may be a list, like `x, y`.
fn item_header(header: &str) -> Option<(Vec<String>, String, String)> {
    let open = header.find(" (")?;
    let close = open + header[open..].find("):")?;
    let names: Vec<String> = header[..open]
        .split(',')
        .map(|n| n.trim().trim_matches(|c| c == '`' || c == '.').to_string())
        .filter(|n| !n.is_empty())
        .collect();
    if names.is_empty() || names.iter().any(|n| !n.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '-')) {
        return None;
    }
    Some((names, header[open + 2..close].to_string(), header[close + 2..].trim().to_string()))
}

/// Paragraphs of a parameter's docs, with its default and roles (`positional`, `required`) taken out.
fn parameter_docs(body: &str) -> (Vec<String>, Option<String>, Vec<String>) {
    let mut default = None;
    let mut roles = vec![];
    let mut paragraphs = vec![];
    for paragraph in split_paragraphs(body) {
        let mut text = paragraph.as_str();
        let mut kept = String::new();
        let mut changed = false;
        if let Some(rest) = text.strip_prefix("Default: ") {
            if let Some((value, after)) = default_value(rest) {
                default = Some(value);
                text = after;
                changed = true;
            }
        }
        // `This parameter is required, positional.` anywhere in the paragraph.
        while let Some(at) = text.find("This parameter is ") {
            let after = &text[at + 18..];
            let Some(end) = after.find('.') else { break };
            kept.push_str(&text[..at]);
            roles.extend(after[..end].split(',').map(|r| r.trim().trim_start_matches("and ").to_string()));
            text = &after[end + 1..];
            changed = true;
        }
        kept.push_str(text);
        // Lists and code keep their lines unless a sentence was taken out.
        let kept = if changed { kept.split_whitespace().collect::<Vec<_>>().join(" ") } else { unwrap(&paragraph) };
        if !kept.is_empty() {
            paragraphs.push(kept);
        }
    }
    (paragraphs, default, roles)
}

/// `` `value`. `` at the start of `rest`, and what follows.
fn default_value(rest: &str) -> Option<(String, &str)> {
    let ticks = rest.chars().take_while(|&c| c == '`').count();
    if ticks == 0 {
        let end = rest.find(". ").map(|e| e + 1).unwrap_or(rest.len());
        let value = rest[..end].trim_end_matches('.').trim();
        return (!value.is_empty()).then(|| (value.to_string(), &rest[end..]));
    }
    let fence = &rest[..ticks];
    let close = ticks + rest[ticks..].find(fence)?;
    let value = rest[ticks..close].trim().to_string();
    let after = rest[close + ticks..].strip_prefix('.').unwrap_or(&rest[close + ticks..]);
    Some((value, after))
}

/// A hard-wrapped paragraph on one line; lists, code and headings keep their lines.
fn unwrap(paragraph: &str) -> String {
    if let Some(quote) = block_quote(paragraph) {
        return quote;
    }
    let structured = paragraph.lines().any(|l| {
        let l = l.trim_start();
        l.starts_with("- ") || l.starts_with("* ") || l.starts_with("```") || l.starts_with('#') || l.starts_with('>')
            || l.split_once(". ").is_some_and(|(n, _)| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
    });
    if structured { paragraph.to_string() } else { paragraph.split_whitespace().collect::<Vec<_>>().join(" ") }
}

/// `#quote(block: true)[…]` as a Markdown quote, as tinymist shows it, with typst's `*strong*` as `**strong**`.
fn block_quote(paragraph: &str) -> Option<String> {
    let rest = paragraph.trim().strip_prefix("#quote(")?;
    let close = rest.find(')')?;
    if !rest[..close].split(',').any(|a| a.split_whitespace().collect::<String>() == "block:true") {
        return None;
    }
    let body = rest[close + 1..].trim_start().strip_prefix('[')?.strip_suffix(']')?;
    let text = body.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut out = String::from("> ");
    let (mut code, mut chars) = (false, text.chars().peekable());
    while let Some(c) = chars.next() {
        match c {
            '`' => code = !code,
            '\\' if !code => {
                if let Some(next) = chars.next() {
                    out.push(next);
                }
                continue;
            }
            '*' if !code => {
                out.push_str("**");
                continue;
            }
            _ => {}
        }
        out.push(c);
    }
    Some(out)
}

fn split_paragraphs(body: &str) -> Vec<String> {
    let mut result = vec![];
    let mut current: Vec<&str> = vec![];
    let mut fence = false;
    for line in body.lines() {
        if line.trim_start().starts_with("```") {
            fence = !fence;
        }
        // A block quote after a ` \` line break, the way tinymist keeps it apart in parameter docs.
        if !fence && line.trim_start().starts_with("#quote(") && !current.is_empty() {
            if let Some(last) = current.pop() {
                let last = last.trim_end();
                current.push(last.strip_suffix('\\').unwrap_or(last).trim_end());
            }
            result.push(current.join("\n"));
            current.clear();
        }
        if !fence && line.trim().is_empty() {
            if !current.is_empty() {
                result.push(current.join("\n"));
                current.clear();
            }
        } else {
            current.push(line);
        }
    }
    if !current.is_empty() {
        result.push(current.join("\n"));
    }
    result
}

fn signature_entry(p: &Parameter) -> String {
    let mut entry = format!("{}{}", if p.variadic { ".." } else { "" }, p.name);
    if !p.types.is_empty() {
        entry += &format!(": {}", p.types);
    }
    if let Some(default) = p.default.as_ref().filter(|_| !p.positional) {
        entry += &format!(" = {default}");
    }
    entry
}

fn render(f: &Documented) -> String {
    let mut out = format!("```typc\nlet {}(\n", f.name);
    for p in &f.parameters {
        out += &format!("  {},\n", signature_entry(p));
    }
    out += &format!(") = {};\n```\n\n---\n\n", f.returns.as_deref().unwrap_or("any"));
    if !f.description.is_empty() {
        out += &f.description;
        out += "\n\n";
    }
    let groups: [(&str, fn(&Parameter) -> bool); 3] = [
        ("Positional Parameters", |p| p.positional && !p.variadic),
        ("Rest Parameters", |p| p.variadic),
        ("Named Parameters", |p| !p.positional),
    ];
    for (title, belongs) in groups {
        let group: Vec<&Parameter> = f.parameters.iter().filter(|p| belongs(p)).collect();
        if group.is_empty() {
            continue;
        }
        out += &format!("# {title}\n\n");
        for p in group {
            out += &format!("## {}\n\n```typc\ntype: {}\n```\n\n", p.name, if p.types.is_empty() { "any" } else { &p.types });
            // A summary in one paragraph: the first one and the notes led by a bold label, like `**In HTML:**`.
            let summary: Vec<&str> = p.docs.iter().enumerate().filter(|(k, d)| *k == 0 || d.starts_with("**")).map(|(_, d)| d.as_str()).collect();
            if !summary.is_empty() {
                out += &summary.iter().map(|d| d.split_whitespace().collect::<Vec<_>>().join(" ")).collect::<Vec<_>>().join(" ");
                out += "\n\n";
            }
            // Block quotes stay banners of their own.
            for quote in p.docs.iter().skip(1).filter(|d| d.starts_with("> ")) {
                out += &format!("{quote}\n\n");
            }
        }
    }
    out.trim_end().to_string() + "\n"
}

/// Splits `a, b: (1, 2), c` at the top level.
fn split_top(s: &str) -> Vec<&str> {
    let (mut parts, mut depth, mut start, mut quoted) = (vec![], 0, 0, false);
    for (i, c) in s.char_indices() {
        match c {
            '"' => quoted = !quoted,
            '(' | '[' | '{' if !quoted => depth += 1,
            ')' | ']' | '}' if !quoted => depth -= 1,
            ',' if !quoted && depth == 0 => {
                parts.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    parts.push(&s[start..]);
    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALIGN: &str = "\
// Generated by a script.
/// Aligns content horizontally and vertically.
///
/// **In HTML:** A block that aligns its content with CSS.
///
/// - alignment (alignment): The alignment along both axes.
///
///   Default: `start + top`. This parameter is positional.
///
///   **In HTML:** `left`, `center`, and `right` stay on that side.
///
/// - stroke (none, length, color,
///     function):
///   How to stroke the cells.
///
///   To specify varying strokes, you can:
///
///   - use a single stroke for all cells
///   - use a function
///
///   Default: `(:)`.
///
/// - children (content, ...): The contents.
///
///   This parameter is positional.
///
/// -> content
#let align(..args) = std.align(..args)
";

    fn line_of(source: &str, needle: &str) -> i32 {
        source.lines().position(|l| l.starts_with(needle)).unwrap() as i32
    }

    #[test]
    fn reads_overridden_functions() {
        let f = documented(ALIGN, line_of(ALIGN, "#let")).unwrap();
        assert_eq!("align", f.name);
        assert_eq!(Some("content".into()), f.returns);
        assert_eq!("Aligns content horizontally and vertically.\n\n**In HTML:** A block that aligns its content with CSS.", f.description);
        let [alignment, stroke, children] = &f.parameters[..] else { panic!("{:?}", f.parameters) };
        assert_eq!(("alignment", "alignment", Some("start + top"), true, false), (alignment.name.as_str(), alignment.types.as_str(), alignment.default.as_deref(), alignment.positional, alignment.variadic));
        assert_eq!(vec!["The alignment along both axes.", "**In HTML:** `left`, `center`, and `right` stay on that side."], alignment.docs);
        assert_eq!("none | length | color | function", stroke.types);
        assert_eq!(Some("(:)".into()), stroke.default);
        assert!(!stroke.positional);
        assert_eq!("- use a single stroke for all cells\n- use a function", stroke.docs[2]);
        assert!(children.variadic && children.positional);
        assert_eq!("content", children.types);
    }

    #[test]
    fn renders_like_tinymist() {
        let docs = overridden_function_docs(ALIGN, line_of(ALIGN, "#let")).unwrap();
        assert!(docs.starts_with("```typc\nlet align(\n  alignment: alignment,\n  stroke: none | length | color | function = (:),\n  ..children: content,\n) = content;\n```"), "{docs}");
        assert!(docs.contains("# Positional Parameters\n\n## alignment\n\n```typc\ntype: alignment\n```\n\nThe alignment along both axes. **In HTML:** `left`"), "{docs}");
        assert!(docs.contains("# Rest Parameters\n\n## children"));
        assert!(docs.contains("# Named Parameters\n\n## stroke"));
        assert!(!docs.contains("Generated"));
        let p = overridden_parameter_docs(ALIGN, line_of(ALIGN, "#let"), "stroke").unwrap();
        assert!(p.starts_with("```typc\nstroke: none | length | color | function = (:)\n```\n\nHow to stroke the cells."), "{p}");
    }

    #[test]
    fn leaves_documented_signatures_to_tinymist() {
        let source = "/// Does it.\n///\n/// - body (content): The body.\n/// - css (string): Default `\"\"`. Extra CSS.\n#let f(body, css: \"\") = body\n";
        assert_eq!(None, overridden_function_docs(source, 4));
        assert_eq!(None, overridden_function_docs("#let f(..args) = 1\n", 0));
        assert_eq!(None, overridden_function_docs("/// Hi.\n#let x = 1\n", 1));
    }

    #[test]
    fn shows_block_quotes_as_markdown() {
        let source = "/// Sets the page.\n///\n/// #quote(block: true)[*Note:* Typst's own `page`, and\n/// `show: x.with(*)` works.]\n///\n/// - paper (str): The paper.\n#let page(..args) = std.page(..args)\n";
        let f = documented(source, 6).unwrap();
        assert_eq!("Sets the page.\n\n> **Note:** Typst's own `page`, and `show: x.with(*)` works.", f.description);
        assert_eq!(None, block_quote("#quote[inline]"));
        let source = "/// - fill (color): The fill.\n///\n///   Default: `none`. \\\n///   #quote(block: true)[*Note:* Behind the content.]\n#let page(..args) = 1\n";
        let f = documented(source, 4).unwrap();
        assert_eq!(vec!["The fill.", "> **Note:** Behind the content."], f.parameters[0].docs);
        assert!(render(&f).contains("The fill.\n\n> **Note:** Behind the content.\n"), "{}", render(&f));
    }

    #[test]
    fn repairs_unparsed_docs() {
        let hover = "```typc\nlet html-only(\n  value: any,\n) = any;\n```\n\n---\n\n```\nfailed to parse docs: error: unknown variable: html-only\n  \u{2502}\n4 \u{2502} #show: html-only(page.with(width: auto))\n  = hint: try \\`html - only\\`\n\n\n```\n\n```typ\nOne-target shortcuts. Functions are show rules:\n#show: html-only(page.with(width: auto))\n#show: paged-only(page)\n```\n\n# Positional Parameters\n";
        assert_eq!(
            "```typc\nlet html-only(\n  value: any,\n) = any;\n```\n\n---\n\nOne-target shortcuts. Functions are show rules:\n\n```typ\n#show: html-only(page.with(width: auto))\n#show: paged-only(page)\n```\n\n\n# Positional Parameters\n",
            repair_unparsed_docs(hover)
        );
        assert_eq!("plain", repair_unparsed_docs("plain"));
    }
}
