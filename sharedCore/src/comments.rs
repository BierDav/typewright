use crate::text::TextRange;
use crate::utf16::Utf16;

/// Finds the innermost complete block containing the selection within comment syntax regions.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn enclosing_block_comment(
    selection: TextRange,
    text: &str,
    prefix: &str,
    suffix: &str,
    regions: Vec<TextRange>,
) -> Option<TextRange> {
    if prefix.is_empty() || suffix.is_empty() {
        return None;
    }
    let text = Utf16::new(text);
    let opening = prefix.encode_utf16().count();
    let closing = suffix.encode_utf16().count();
    let mut found: Option<TextRange> = None;
    for region in regions {
        let mut i = text.clamp(region.location);
        let end = text.clamp(region.location.saturating_add(region.length));
        let mut stack = vec![];
        while i < end {
            if stack.is_empty() && prefix == "/*" && text.starts_with(i, "//") {
                while i < end && !matches!(text.at(i), '\r' | '\n') { i += 1; }
                continue;
            }
            if stack.is_empty() && text.at(i) == '`' {
                let count = (i..end).take_while(|&at| text.at(at) == '`').count();
                i += count;
                while i < end && !text.starts_with(i, &"`".repeat(count)) { i += 1; }
                i = (i + count).min(end);
                continue;
            }
            if i + opening <= end && text.starts_with(i, prefix) && (stack.is_empty() || prefix == "/*") {
                stack.push(i);
                i += opening;
            } else if !stack.is_empty() && i + closing <= end && text.starts_with(i, suffix) {
                let start = stack.pop().unwrap();
                i += closing;
                if selection.location >= start as i32 && selection.location < i as i32
                    && selection.end() <= i as i32
                {
                    let range = TextRange { location: start as i32, length: (i - start) as i32 };
                    if found.is_none_or(|previous| range.length < previous.length) {
                        found = Some(range);
                    }
                }
            } else {
                i += 1;
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(text: &str, location: i32, length: i32, prefix: &str, suffix: &str) -> Option<TextRange> {
        enclosing_block_comment(TextRange { location, length }, text, prefix, suffix,
                                vec![TextRange { location: 0, length: text.encode_utf16().count() as i32 }])
    }

    #[test]
    fn finds_multiline_blocks_from_any_line() {
        let text = "/* first\n\nlast */";
        for caret in [0, 3, 9, 12, 16] {
            assert_eq!(block(text, caret, 0, "/*", "*/"), Some(TextRange { location: 0, length: 17 }));
        }
        assert_eq!(block(text, 4, 8, "/*", "*/"), Some(TextRange { location: 0, length: 17 }));
        assert!(block(text, 17, 0, "/*", "*/").is_none());
    }

    #[test]
    fn picks_the_inner_block_and_does_not_combine_adjacent_blocks() {
        let text = "/*a /*b*/ c*//*d*/";
        assert_eq!(block(text, 6, 0, "/*", "*/"), Some(TextRange { location: 4, length: 5 }));
        assert_eq!(block(text, 11, 0, "/*", "*/"), Some(TextRange { location: 0, length: 13 }));
        assert_eq!(block(text, 15, 0, "/*", "*/"), Some(TextRange { location: 13, length: 5 }));
        assert!(block(text, 6, 10, "/*", "*/").is_none());
    }

    #[test]
    fn ignores_unclosed_and_line_comments_and_raw_markdown() {
        assert!(block("/* open", 4, 0, "/*", "*/").is_none());
        assert!(block("// /* example */", 9, 0, "/*", "*/").is_none());
        assert!(block("`<!-- example -->`", 9, 0, "<!--", "-->").is_none());
        assert_eq!(block("<!--\n😀\n-->", 6, 0, "<!--", "-->"), Some(TextRange { location: 0, length: 11 }));
    }
}
