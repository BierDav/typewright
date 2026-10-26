//! What Enter and Backspace do in the code editor, like IntelliJ: indentation, list items and smart unindent.
use crate::text::{TextEdit, TextRange};
use crate::utf16::Utf16;

/// A key's change: replace `edit`, then put the caret at `caret`.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct Typing {
    pub from: i32,
    pub to: i32,
    pub insert: String,
    pub caret: i32,
}

impl Typing {
    pub fn edit(&self) -> TextEdit {
        TextEdit { range: TextRange { location: self.from, length: self.to - self.from }, new_text: self.insert.clone() }
    }
}

const OPENERS: [char; 3] = ['(', '[', '{'];

fn closer(c: char) -> Option<char> {
    match c {
        '(' => Some(')'),
        '[' => Some(']'),
        '{' => Some('}'),
        _ => None,
    }
}

fn line_start(t: &Utf16, at: usize) -> usize {
    (0..at).rev().find(|&i| matches!(t.at(i), '\n' | '\r')).map_or(0, |i| i + 1)
}

fn line_end(t: &Utf16, at: usize) -> usize {
    (at..t.len()).find(|&i| matches!(t.at(i), '\n' | '\r')).unwrap_or(t.len())
}

fn is_blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

/// The leading spaces and tabs of the line starting at `start`, up to `limit`.
fn indent_end(t: &Utf16, start: usize, limit: usize) -> usize {
    (start..limit).find(|&i| !is_blank(t.at(i))).unwrap_or(limit)
}

/// One level of indentation, a tab where the file indents with tabs.
fn unit(indent: &str) -> &'static str {
    if indent.contains('\t') { "\t" } else { "  " }
}

/// Enter with `from..to` selected; `syntax` is `"typst"`, `"markdown"` or anything else for plain text.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn newline(text: &str, from: i32, to: i32, syntax: &str) -> Typing {
    let t = Utf16::new(text);
    let (from, mut to) = (t.clamp(from.min(to)), t.clamp(from.max(to)));
    let start = line_start(&t, from);
    let indent_to = indent_end(&t, start, from);
    let indent = t.slice(start, indent_to);
    let before = t.slice(start, from);
    // What moves to the new line loses its leading spaces.
    while to < t.len() && is_blank(t.at(to)) {
        to += 1;
    }
    let after = t.slice(to, line_end(&t, to));
    let typing = |from: usize, insert: String, caret: usize| Typing {
        from: from as i32,
        to: to as i32,
        caret: (from + crate::utf16::len(&insert) as usize - caret) as i32,
        insert,
    };
    // A line of only spaces is left empty.
    let edit_from = if before.trim().is_empty() { start } else { from };
    let lists = syntax == "typst" && mode_at(&t, start) == Mode::Markup || syntax == "markdown" && !in_fence(&t, start);
    if lists && let Some(item) = list_item(&before, syntax) {
        if before.len() == item.marker_end && after.trim().is_empty() {
            // Enter on an empty item outdents it, or ends the list at the top level.
            let removed = indent.chars().last().map_or(0, |c| if c == '\t' { 1 } else { indent.len().min(2) });
            return if indent.is_empty() {
                Typing { from: start as i32, to: to as i32, insert: String::new(), caret: start as i32 }
            } else {
                let kept = &indent[..indent.len() - removed];
                let marker = &before[item.indent_end..];
                let insert = format!("{kept}{marker}");
                let caret = start + crate::utf16::len(&insert) as usize;
                Typing { from: start as i32, to: to as i32, insert, caret: caret as i32 }
            };
        }
        let insert = format!("\n{}{}", &before[..item.indent_end], item.next);
        return typing(from, insert, 0);
    }
    let previous = before.trim_end().chars().last();
    let next = after.chars().next();
    if syntax != "markdown" && let Some(open) = previous.filter(|c| OPENERS.contains(c)) {
        let inner = format!("{indent}{}", unit(&indent));
        // Between a pair the closer goes on a line of its own.
        if next == closer(open) {
            let insert = format!("\n{inner}\n{indent}");
            return typing(from, insert, crate::utf16::len(&indent) as usize + 1);
        }
        return typing(from, format!("\n{inner}"), 0);
    }
    typing(edit_from, format!("\n{indent}"), 0)
}

/// Backspace at `caret` with nothing selected; None leaves it to the editor. `pairs` lists openers each followed by
/// its closer (`"()[]\"\""`), empty ones going together.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn backspace(text: &str, caret: i32, pairs: &str) -> Option<Typing> {
    let t = Utf16::new(text);
    let at = t.clamp(caret);
    if at == 0 {
        return None;
    }
    let pairs: Vec<char> = pairs.chars().collect();
    if at < t.len() && pairs.chunks_exact(2).any(|p| p[0] == t.at(at - 1) && p[1] == t.at(at)) && (at < 2 || t.at(at - 2) != '\\') {
        return Some(Typing { from: at as i32 - 1, to: at as i32 + 1, insert: String::new(), caret: at as i32 - 1 });
    }
    let start = line_start(&t, at);
    if start == 0 || at == start || indent_end(&t, start, at) != at {
        return None;
    }
    // In the line's indentation: back to where it belongs, then onto the end of the line above.
    let end = line_end(&t, at);
    let rest = t.slice(at, end);
    let proper = proper_indent(&t, start, rest.trim_start().chars().next());
    if at - start > proper {
        return Some(Typing { from: (start + proper) as i32, to: at as i32, insert: String::new(), caret: (start + proper) as i32 });
    }
    if !rest.trim().is_empty() {
        return None;
    }
    let mut join = start - 1;
    if join > 0 && t.at(join) == '\n' && t.at(join - 1) == '\r' {
        join -= 1;
    }
    let content = line_start(&t, join);
    while join > content && is_blank(t.at(join - 1)) {
        join -= 1;
    }
    Some(Typing { from: join as i32, to: end as i32, insert: String::new(), caret: join as i32 })
}

/// The indentation the line starting at `start` should have: the line above's, one deeper after an opener, one
/// shallower before a closer.
fn proper_indent(t: &Utf16, start: usize, first: Option<char>) -> usize {
    let mut line = start;
    while line > 0 {
        let mut gap = line - 1;
        if gap > 0 && t.at(gap) == '\n' && t.at(gap - 1) == '\r' {
            gap -= 1;
        }
        let previous = line_start(t, gap);
        let end = line_end(t, previous);
        let body = t.slice(previous, end);
        if !body.trim().is_empty() {
            let indent = indent_end(t, previous, end) - previous;
            let opens = body.trim_end().chars().last().is_some_and(|c| OPENERS.contains(&c));
            let closes = first.is_some_and(|c| [')', ']', '}'].contains(&c));
            let step = unit(&body[..indent]).len();
            return match (opens, closes) {
                (true, false) => indent + step,
                (false, true) => indent.saturating_sub(step),
                _ => indent,
            };
        }
        line = previous;
    }
    0
}

struct ListItem {
    /// Bytes of the line's indentation.
    indent_end: usize,
    /// Bytes up to the end of the marker and its space.
    marker_end: usize,
    /// The next item's marker.
    next: String,
}

/// The list item the line so far starts, with the marker of the item after it.
fn list_item(line: &str, syntax: &str) -> Option<ListItem> {
    let indent_end = line.len() - line.trim_start_matches([' ', '\t']).len();
    let rest = &line[indent_end..];
    let item = |marker: usize, next: String| Some(ListItem { indent_end, marker_end: indent_end + marker, next });
    let markdown = syntax == "markdown";
    for bullet in if markdown { ["- ", "* ", "+ "].as_slice() } else { ["- ", "+ ", "/ "].as_slice() } {
        if rest.starts_with(bullet) {
            if markdown && let Some(task) = ["[ ] ", "[x] ", "[X] "].iter().find(|t| rest[2..].starts_with(*t)) {
                return item(2 + task.len(), format!("{bullet}[ ] "));
            }
            return item(bullet.len(), bullet.to_string());
        }
    }
    if markdown && rest.starts_with("> ") {
        return item(2, "> ".into());
    }
    let digits = rest.len() - rest.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    if digits > 0 && digits < 10 {
        let after = &rest[digits..];
        for separator in if markdown { [". ", ") "].as_slice() } else { [". "].as_slice() } {
            if after.starts_with(separator) {
                let number: u64 = rest[..digits].parse().ok()?;
                return item(digits + separator.len(), format!("{}{separator}", number + 1));
            }
        }
    }
    None
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    Markup,
    Code,
    /// Code after `#let` and the like, which a line break ends outside brackets.
    CodeLine,
    Math,
    Raw,
}

/// Typst's mode at `end`, from brackets, `#`, `$`, strings, comments and raw text; good enough for list items.
fn mode_at(t: &Utf16, end: usize) -> Mode {
    let mut stack = vec![Mode::Markup];
    let mut i = 0;
    let name = |c: char| c.is_alphanumeric() || c == '_' || c == '-';
    while i < end {
        let c = t.at(i);
        let top = *stack.last().unwrap();
        if top != Mode::Math && t.starts_with(i, "//") && (top != Mode::Markup || i == 0 || t.at(i - 1) != ':') {
            i = line_end(t, i);
            continue;
        }
        if t.starts_with(i, "/*") {
            i = t.find("*/", i + 2).map_or(t.len(), |j| j + 2);
            continue;
        }
        match top {
            Mode::Markup => match c {
                '\\' => i += 1,
                '`' => {
                    let count = (i..t.len()).take_while(|&j| t.at(j) == '`').count();
                    let fence = "`".repeat(count);
                    match t.find(&fence, i + count) {
                        // Two backticks are an empty raw.
                        _ if count == 2 => i += 1,
                        Some(close) if close + count <= end => i = close + count - 1,
                        _ => return Mode::Raw,
                    }
                }
                '[' => stack.push(Mode::Markup),
                ']' if stack.len() > 1 => {
                    stack.pop();
                }
                '$' => stack.push(Mode::Math),
                '#' => {
                    let mut j = i + 1;
                    while j < t.len() && (name(t.at(j)) || t.at(j) == '.' && j + 1 < t.len() && name(t.at(j + 1))) {
                        j += 1;
                    }
                    let keyword = t.slice(i + 1, j);
                    match t.get(j) {
                        Some('(' | '{') => {
                            stack.push(Mode::Code);
                            i = j;
                        }
                        _ if matches!(keyword.as_str(), "let" | "set" | "show" | "import" | "include" | "if" | "for" | "while" | "context" | "return") => {
                            stack.push(Mode::CodeLine);
                            i = j - 1;
                        }
                        _ => i = j.max(i + 1) - 1,
                    }
                }
                _ => {}
            },
            Mode::Code | Mode::CodeLine => match c {
                '"' => {
                    i += 1;
                    while i < end && t.at(i) != '"' {
                        if t.at(i) == '\\' {
                            i += 1;
                        }
                        i += 1;
                    }
                }
                '(' | '{' => stack.push(Mode::Code),
                '[' => stack.push(Mode::Markup),
                ')' | '}' => {
                    if top == Mode::CodeLine {
                        stack.pop();
                    }
                    if stack.len() > 1 {
                        stack.pop();
                    }
                }
                '$' => stack.push(Mode::Math),
                '\n' if top == Mode::CodeLine => {
                    stack.pop();
                }
                _ => {}
            },
            Mode::Math => match c {
                '\\' => i += 1,
                '"' => i = t.find_char('"', i + 1).unwrap_or(t.len()),
                '$' => {
                    stack.pop();
                }
                _ => {}
            },
            Mode::Raw => unreachable!(),
        }
        i += 1;
    }
    match *stack.last().unwrap() {
        Mode::CodeLine => Mode::Code,
        mode => mode,
    }
}

/// Whether `at` is inside a fenced Markdown code block.
fn in_fence(t: &Utf16, at: usize) -> bool {
    let mut inside = false;
    let mut start = 0;
    while start < at {
        let end = line_end(t, start);
        let line = t.slice(start, end);
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            inside = !inside;
        }
        start = end + 1;
    }
    inside
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Applies the change at the `|` of `text` and marks the caret again.
    fn enter(text: &str, syntax: &str) -> String {
        let at = text.find('|').unwrap();
        let text = text.replace('|', "");
        let at = text[..at].encode_utf16().count() as i32;
        show(&text, newline(&text, at, at, syntax))
    }

    fn delete(text: &str) -> Option<String> {
        let at = text.find('|').unwrap();
        let text = text.replace('|', "");
        let at = text[..at].encode_utf16().count() as i32;
        backspace(&text, at, "()[]{}\"\"$$").map(|change| show(&text, change))
    }

    fn show(text: &str, change: Typing) -> String {
        let changed = crate::text::apply_text_edits(vec![change.edit()], text);
        let mut units: Vec<u16> = changed.encode_utf16().collect();
        units.insert(change.caret as usize, '|' as u16);
        String::from_utf16(&units).unwrap()
    }

    #[test]
    fn keeps_and_deepens_indentation() {
        assert_eq!(enter("  a|", "typst"), "  a\n  |");
        assert_eq!(enter("#grid(|)", "typst"), "#grid(\n  |\n)");
        assert_eq!(enter("  #worksheet()[|]", "typst"), "  #worksheet()[\n    |\n  ]");
        assert_eq!(enter("#f(|", "typst"), "#f(\n  |");
        assert_eq!(enter("a|   b", "plain"), "a\n|b");
        assert_eq!(enter("x\n  |", "typst"), "x\n\n  |");
        assert_eq!(enter("\tx|", "plain"), "\tx\n\t|");
    }

    #[test]
    fn continues_typst_lists_in_markup_only() {
        assert_eq!(enter("- one|", "typst"), "- one\n- |");
        assert_eq!(enter("  + one|", "typst"), "  + one\n  + |");
        assert_eq!(enter("9. nine|", "typst"), "9. nine\n10. |");
        assert_eq!(enter("/ Term: one|", "typst"), "/ Term: one\n/ |");
        assert_eq!(enter("- one|two", "typst"), "- one\n- |two");
        assert_eq!(enter("#[\n  - a|\n]", "typst"), "#[\n  - a\n  - |\n]");
        assert_eq!(enter("#let x = (\n- a|", "typst"), "#let x = (\n- a\n|");
        assert_eq!(enter("```\n- a|", "typst"), "```\n- a\n|");
        assert_eq!(enter("$\n- a|", "typst"), "$\n- a\n|");
    }

    #[test]
    fn ends_or_outdents_empty_items() {
        assert_eq!(enter("- a\n- |", "typst"), "- a\n|");
        assert_eq!(enter("- a\n  - |", "typst"), "- a\n- |");
    }

    #[test]
    fn continues_markdown_lists_quotes_and_tasks() {
        assert_eq!(enter("* a|", "markdown"), "* a\n* |");
        assert_eq!(enter("- [x] done|", "markdown"), "- [x] done\n- [ ] |");
        assert_eq!(enter("1) a|", "markdown"), "1) a\n2) |");
        assert_eq!(enter("> quote|", "markdown"), "> quote\n> |");
        assert_eq!(enter("```\n- a|", "markdown"), "```\n- a\n|");
        assert_eq!(enter("- a|", "plain"), "- a\n|");
    }

    #[test]
    fn backspace_takes_the_indentation_and_the_line_break() {
        let worksheet = "#worksheet(scope: \"isolated\")[\n  $F(u) := u^2$\n  |\n]";
        assert_eq!(delete(worksheet).unwrap(), "#worksheet(scope: \"isolated\")[\n  $F(u) := u^2$|\n]");
        assert_eq!(delete("a\n      |").unwrap(), "a\n|");
        assert_eq!(delete("a(\n      |").unwrap(), "a(\n  |");
        assert_eq!(delete("a(\n  |").unwrap(), "a(|");
        assert_eq!(delete("a  \n\n  |").unwrap(), "a  \n\n|");
        assert_eq!(delete("a  \n(\n  |").unwrap(), "a  \n(|");
        assert_eq!(delete("a  \n  \n  |").unwrap(), "a  \n  \n|");
        assert_eq!(delete("a(\n    |)").unwrap(), "a(\n|)");
        assert_eq!(delete("a(\r\n  |").unwrap(), "a(|");
    }

    #[test]
    fn backspace_leaves_text_and_takes_empty_pairs() {
        assert_eq!(delete("a\n  |b").unwrap(), "a\n|b");
        assert_eq!(delete("a(\n  |b"), None);
        assert_eq!(delete("a\n|b"), None);
        assert_eq!(delete("ab|"), None);
        assert_eq!(delete("  |"), None);
        assert_eq!(delete("(|)").unwrap(), "|");
        assert_eq!(delete("\\(|)"), None);
    }

    #[test]
    fn modes() {
        let mode = |text: &str| mode_at(&Utf16::new(text), text.encode_utf16().count());
        assert_eq!(mode("text #grid("), Mode::Code);
        assert_eq!(mode("#grid()[x "), Mode::Markup);
        assert_eq!(mode("#let x = 1\n"), Mode::Markup);
        assert_eq!(mode("#let f(x) = {\n"), Mode::Code);
        assert_eq!(mode("$ a "), Mode::Math);
        assert_eq!(mode("see https://x.y // c\n"), Mode::Markup);
        assert_eq!(mode("#\"(\" "), Mode::Markup);
        assert_eq!(mode("#f(\"(\")\n"), Mode::Markup);
    }
}
