use crate::text::TextRange;
use crate::utf16::Utf16;

/// Matches next to the caret, excluding parser-provided comment ranges in both directions.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn matching_brackets(caret: i32, text: &str, comments: Vec<TextRange>) -> Vec<TextRange> {
    let text = Utf16::new(text);
    let mut ignored = vec![false; text.len()];
    for range in comments {
        let start = text.clamp(range.location);
        let end = text.clamp(range.location.saturating_add(range.length));
        if start < end {
            ignored[start..end].fill(true);
        }
    }
    for index in [caret.saturating_sub(1), caret] {
        if index < 0 || index as usize >= text.len() || ignored[index as usize] {
            continue;
        }
        let index = index as usize;
        let ch = text.at(index);
        let found = |partner: usize| vec![
            TextRange { location: index as i32, length: 1 },
            TextRange { location: partner as i32, length: 1 },
        ];
        if ch == '"' {
            if let Some(partner) = matching_quote(index, &text, &ignored) {
                return found(partner);
            }
            continue;
        }
        let (partner, step) = match ch {
            '(' => (')', 1), ')' => ('(', -1),
            '[' => (']', 1), ']' => ('[', -1),
            '{' => ('}', 1), '}' => ('{', -1),
            _ => continue,
        };
        let mut depth = 0;
        let mut position = index as i64;
        // Keep distant matches from blocking the editor on very large files.
        for _ in 0..50_000 {
            position += step;
            if position < 0 || position >= text.len() as i64 {
                break;
            }
            let position = position as usize;
            if ignored[position] {
                continue;
            }
            let current = text.at(position);
            if current == ch {
                depth += 1;
            }
            if current == partner {
                if depth == 0 {
                    return found(position);
                }
                depth -= 1;
            }
        }
    }
    vec![]
}

fn matching_quote(index: usize, text: &Utf16, ignored: &[bool]) -> Option<usize> {
    let mut start = index;
    while start > 0 && !matches!(text.at(start - 1), '\r' | '\n') {
        start -= 1;
    }
    let mut quotes = vec![];
    let mut position = start;
    while position < text.len() && !matches!(text.at(position), '\r' | '\n') {
        if ignored[position] {
            position += 1;
            continue;
        }
        match text.at(position) {
            '\\' => { position += 2; continue; }
            '"' => quotes.push(position),
            _ => {}
        }
        position += 1;
    }
    let slot = quotes.iter().position(|&quote| quote == index)?;
    let partner = if slot % 2 == 0 { slot + 1 } else { slot - 1 };
    quotes.get(partner).copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn range(location: i32, length: i32) -> TextRange { TextRange { location, length } }

    #[test]
    fn ignores_comments_in_both_directions_and_at_the_caret() {
        let text = "#grid(\n // a) b)\n [item],\n)";
        let comment = range(8, 8);
        let end = text.encode_utf16().count() as i32 - 1;
        assert_eq!(matching_brackets(6, text, vec![comment]), vec![range(5, 1), range(end, 1)]);
        assert_eq!(matching_brackets(end, text, vec![comment]), vec![range(end, 1), range(5, 1)]);
        assert!(matching_brackets(12, text, vec![comment]).is_empty());
    }

    #[test]
    fn ignores_openers_and_quotes_inside_block_comments() {
        let text = "( /* (( */ value )";
        let end = text.len() as i32 - 1;
        assert_eq!(matching_brackets(end + 1, text, vec![range(2, 8)]), vec![range(end, 1), range(0, 1)]);
        let text = "/* \" */ \"hello\"";
        assert_eq!(matching_brackets(9, text, vec![range(0, 7)]), vec![range(8, 1), range(14, 1)]);
    }

    #[test]
    fn retains_quote_escapes_nesting_and_utf16_offsets() {
        assert_eq!(matching_brackets(4, "😀(())", vec![]), vec![range(3, 1), range(4, 1)]);
        assert_eq!(matching_brackets(1, "\"a\\\"b\"", vec![]), vec![range(0, 1), range(5, 1)]);
        assert!(matching_brackets(1, "(", vec![]).is_empty());
    }
}
