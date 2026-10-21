use crate::utf16::Utf16;

/// A UTF-16 range, the unit of NSString, JavaScript strings and LSP.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct TextRange {
    pub location: i32,
    pub length: i32,
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
impl TextRange {
    pub fn end(&self) -> i32 {
        self.location + self.length
    }
}

/// A zero-based LSP position.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct TextPosition {
    pub line: i32,
    pub character: i32,
}

/// A replacement of a UTF-16 range, from formatting or renaming.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct TextEdit {
    pub range: TextRange,
    pub new_text: String,
}

/// Applies edits that don't overlap; later ones first so earlier ranges stay valid.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn apply_text_edits(mut edits: Vec<TextEdit>, text: &str) -> String {
    let mut result: Vec<u16> = text.encode_utf16().collect();
    edits.sort_by_key(|edit| std::cmp::Reverse(edit.range.location));
    for edit in edits {
        let (start, end) = (edit.range.location as i64, edit.range.end() as i64);
        if start < 0 || end > result.len() as i64 || end < start {
            continue;
        }
        result.splice(start as usize..end as usize, edit.new_text.encode_utf16());
    }
    String::from_utf16_lossy(&result)
}

/// The one edit that turns `old` into `new`: everything between their common start and end, never splitting a surrogate pair.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn text_difference(old: &str, new: &str) -> TextEdit {
    let (a, b) = (Utf16::new(old), Utf16::new(new));
    let (a, b) = (a.units(), b.units());
    let mut start = 0;
    while start < a.len() && start < b.len() && a[start] == b[start] {
        start += 1;
    }
    if start > 0 && is_high_surrogate(a[start - 1]) {
        start -= 1;
    }
    let mut end = 0;
    while end < a.len() - start && end < b.len() - start && a[a.len() - 1 - end] == b[b.len() - 1 - end] {
        end += 1;
    }
    if end > 0 && is_low_surrogate(a[a.len() - end]) {
        end -= 1;
    }
    TextEdit {
        range: TextRange { location: start as i32, length: (a.len() - end - start) as i32 },
        new_text: String::from_utf16_lossy(&b[start..b.len() - end]),
    }
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn text_position(offset: i32, text: &str) -> TextPosition {
    let t = Utf16::new(text);
    let end = t.clamp(offset);
    let (mut line, mut line_start) = (0, 0);
    for i in 0..end {
        if t.at(i) == '\n' {
            line += 1;
            line_start = i + 1;
        }
    }
    TextPosition { line, character: (end - line_start) as i32 }
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn text_offset(line: i32, character: i32, text: &str) -> i32 {
    offset_in(&Utf16::new(text), line, character)
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn text_range(start: TextPosition, end: TextPosition, text: &str) -> TextRange {
    let t = Utf16::new(text);
    let a = offset_in(&t, start.line, start.character);
    let b = offset_in(&t, end.line, end.character);
    TextRange { location: a, length: (b - a).max(0) }
}

/// The line's text without its line break.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn line_text(line: i32, text: &str) -> String {
    let t = Utf16::new(text);
    let start = t.clamp(offset_in(&t, line, 0));
    t.slice(start, line_end(&t, start))
}

/// Range of the contents of the string literal around `offset` on its line.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn string_literal_range(offset: i32, text: &str) -> Option<TextRange> {
    let t = Utf16::new(text);
    let clamped = t.clamp(offset);
    let mut index = line_start(&t, clamped);
    let end = line_end(&t, clamped);
    let mut start: Option<usize> = None;
    while index < end {
        match t.at(index) {
            // Skips the escaped character.
            '\\' => {
                index += 2;
                continue;
            }
            '"' => match start {
                Some(s) => {
                    if (s as i64..=index as i64).contains(&(offset as i64)) {
                        return Some(TextRange { location: s as i32, length: (index - s) as i32 });
                    }
                    start = None;
                }
                None => start = Some(index + 1),
            },
            _ => {}
        }
        index += 1;
    }
    None
}

fn offset_in(t: &Utf16, line: i32, character: i32) -> i32 {
    let (mut current, mut index) = (0, 0);
    while current < line && index < t.len() {
        if t.at(index) == '\n' {
            current += 1;
        }
        index += 1;
    }
    (index as i64 + character as i64).min(t.len() as i64) as i32
}

fn line_start(t: &Utf16, offset: usize) -> usize {
    let mut i = offset;
    while i > 0 && !is_break(t.at(i - 1)) {
        i -= 1;
    }
    i
}

fn line_end(t: &Utf16, offset: usize) -> usize {
    let mut i = offset;
    while i < t.len() && !is_break(t.at(i)) {
        i += 1;
    }
    i
}

fn is_break(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

fn is_high_surrogate(unit: u16) -> bool {
    (0xD800..0xDC00).contains(&unit)
}

fn is_low_surrogate(unit: u16) -> bool {
    (0xDC00..0xE000).contains(&unit)
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEXT: &str = "#let a = 1\n😀 \"hi\" \"x\\\"y\"\nlast";

    fn index(needle: &str) -> i32 {
        crate::utf16::len(&TEXT[..TEXT.find(needle).unwrap()])
    }

    fn edit(location: i32, length: i32, new_text: &str) -> TextEdit {
        TextEdit { range: TextRange { location, length }, new_text: new_text.into() }
    }

    #[test]
    fn converts_positions_in_utf16() {
        assert_eq!(TextPosition { line: 1, character: 3 }, text_position(14, TEXT));
        assert_eq!(14, text_offset(1, 3, TEXT));
        assert_eq!(crate::utf16::len(TEXT), text_offset(9, 0, TEXT));
        assert_eq!(TextPosition { line: 2, character: 4 }, text_position(1000, TEXT));
        let range = text_range(TextPosition { line: 1, character: 0 }, TextPosition { line: 1, character: 3 }, TEXT);
        assert_eq!(TextRange { location: 11, length: 3 }, range);
    }

    #[test]
    fn reads_lines() {
        assert_eq!("#let a = 1", line_text(0, TEXT));
        assert_eq!("last", line_text(2, TEXT));
    }

    #[test]
    fn finds_string_literals() {
        let hi = index("hi");
        assert_eq!(Some(TextRange { location: hi, length: 2 }), string_literal_range(hi + 1, TEXT));
        let escaped = index("x\\");
        assert_eq!(Some(TextRange { location: escaped, length: 4 }), string_literal_range(escaped + 3, TEXT));
        assert_eq!(None, string_literal_range(2, TEXT));
    }

    #[test]
    fn applies_edits_back_to_front() {
        let edits = vec![edit(0, 4, "#set"), edit(9, 1, "2"), edit(90, 1, "!")];
        assert_eq!("#set a = 2", apply_text_edits(edits, "#let a = 1"));
    }

    #[test]
    fn difference_is_one_minimal_edit() {
        assert_eq!(edit(4, 0, "X"), text_difference("abcdef", "abcdXef"));
        assert_eq!(edit(1, 2, ""), text_difference("abca", "aa"));
        assert_eq!(edit(4, 0, ""), text_difference("same", "same"));
        // Repeated letters: the edit lands after the common start.
        assert_eq!(edit(2, 0, "a"), text_difference("aa", "aaa"));
        for (old, new) in [("x😀y", "x😁y"), ("ab", ""), ("", "ab")] {
            assert_eq!(new, apply_text_edits(vec![text_difference(old, new)], old));
        }
        // Emoji differing only in the low half are replaced whole.
        assert_eq!(edit(1, 2, "😁"), text_difference("x😀y", "x😁y"));
    }
}
