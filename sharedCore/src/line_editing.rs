use crate::text::{text_difference, TextEdit};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct LineSelection {
    pub anchor: i32,
    pub head: i32,
}

#[derive(Debug)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct LineChange {
    pub edit: TextEdit,
    pub selections: Vec<LineSelection>,
}

struct Lines<'a> {
    bodies: Vec<&'a str>,
    breaks: Vec<&'a str>,
    starts: Vec<i32>,
}

impl<'a> Lines<'a> {
    fn new(text: &'a str) -> Self {
        let mut result = Self { bodies: vec![], breaks: vec![], starts: vec![0] };
        let mut start = 0;
        let mut chars = text.char_indices().peekable();
        while let Some((index, ch)) = chars.next() {
            if ch != '\r' && ch != '\n' {
                continue;
            }
            let mut end = index + 1;
            if ch == '\r' && chars.peek().is_some_and(|(_, c)| *c == '\n') {
                chars.next();
                end += 1;
            }
            result.bodies.push(&text[start..index]);
            result.breaks.push(&text[index..end]);
            result.starts.push(result.starts.last().unwrap() + text[start..end].encode_utf16().count() as i32);
            start = end;
        }
        result.bodies.push(&text[start..]);
        result.breaks.push("");
        result
    }

    fn row(&self, offset: i32) -> usize {
        self.starts.partition_point(|&start| start <= offset.max(0)).saturating_sub(1)
    }

    fn length(&self, row: usize) -> i32 {
        self.bodies[row].encode_utf16().count() as i32
    }

    fn selected(&self, selections: &[LineSelection]) -> Vec<bool> {
        let mut selected = vec![false; self.bodies.len()];
        for selection in selections {
            let start = selection.anchor.min(selection.head);
            let end = selection.anchor.max(selection.head);
            let first = self.row(start);
            let last = self.row(if end > start { end - 1 } else { end });
            selected[first..=last].fill(true);
        }
        selected
    }

    fn assemble(&self, order: &[usize]) -> (String, Vec<i32>) {
        let mut text = String::new();
        let mut starts = vec![];
        let mut offset = 0;
        for (position, &row) in order.iter().enumerate() {
            starts.push(offset);
            text.push_str(self.bodies[row]);
            offset += self.length(row);
            if position + 1 < order.len() {
                let separator = self.breaks[position];
                text.push_str(separator);
                offset += separator.encode_utf16().count() as i32;
            }
        }
        (text, starts)
    }
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn current_line_selections(offsets: Vec<i32>, text: &str) -> Vec<LineSelection> {
    let lines = Lines::new(text);
    let mut rows: Vec<_> = offsets.iter().map(|&at| lines.row(at)).collect();
    rows.sort_unstable();
    rows.dedup();
    rows.iter().map(|&row| LineSelection { anchor: lines.starts[row], head: lines.starts.get(row + 1).copied().unwrap_or(lines.starts[row] + lines.length(row)) }).collect()
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn copy_current_lines(offsets: Vec<i32>, text: &str) -> String {
    let lines = Lines::new(text);
    let selections: Vec<_> = offsets.iter().map(|&at| LineSelection { anchor: at, head: at }).collect();
    let selected = lines.selected(&selections);
    let separator = lines.breaks.iter().find(|s| !s.is_empty()).copied().unwrap_or("\n");
    let mut copied = String::new();
    for (row, &selected) in selected.iter().enumerate() {
        if selected {
            copied.push_str(lines.bodies[row]);
            copied.push_str(if lines.breaks[row].is_empty() { separator } else { lines.breaks[row] });
        }
    }
    copied
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn cut_current_lines(offsets: Vec<i32>, text: &str) -> LineChange {
    let lines = Lines::new(text);
    let selections: Vec<_> = offsets.iter().map(|&at| LineSelection { anchor: at, head: at }).collect();
    let selected = lines.selected(&selections);
    let kept: Vec<_> = (0..selected.len()).filter(|&row| !selected[row]).collect();
    let (changed, starts) = lines.assemble(&kept);
    let selections = offsets.iter().map(|&at| {
        let row = lines.row(at);
        let next = kept.partition_point(|&kept| kept < row).min(kept.len().saturating_sub(1));
        let caret = if kept.is_empty() { 0 } else {
            starts[next] + (at - lines.starts[row]).max(0).min(lines.length(kept[next]))
        };
        LineSelection { anchor: caret, head: caret }
    }).collect();
    LineChange { edit: text_difference(text, &changed), selections }
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn move_selected_lines(selections: Vec<LineSelection>, up: bool, text: &str) -> LineChange {
    let lines = Lines::new(text);
    let selected = lines.selected(&selections);
    let mut order: Vec<_> = (0..selected.len()).collect();
    if up {
        for i in 1..order.len() {
            if selected[order[i]] && !selected[order[i - 1]] {
                order.swap(i, i - 1);
            }
        }
    } else {
        for i in (0..order.len().saturating_sub(1)).rev() {
            if selected[order[i]] && !selected[order[i + 1]] {
                order.swap(i, i + 1);
            }
        }
    }
    let (changed, starts) = lines.assemble(&order);
    let mut positions = vec![0; order.len()];
    for (position, &row) in order.iter().enumerate() {
        positions[row] = position;
    }
    let selections = selections.iter().map(|selection| {
        let end = selection.anchor.max(selection.head);
        let map = |at: i32| {
            let mut row = lines.row(at);
            // A selection ending at a line start belongs to the preceding line.
            if selection.anchor != selection.head && at == end && row > 0 && at == lines.starts[row] {
                row -= 1;
                let position = positions[row];
                return starts.get(position + 1).copied().unwrap_or(changed.encode_utf16().count() as i32);
            }
            starts[positions[row]] + (at - lines.starts[row]).max(0).min(lines.length(row))
        };
        LineSelection { anchor: map(selection.anchor), head: map(selection.head) }
    }).collect();
    LineChange { edit: text_difference(text, &changed), selections }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::apply_text_edits;

    fn caret(at: i32) -> LineSelection { LineSelection { anchor: at, head: at } }
    fn result(change: &LineChange, text: &str) -> String { apply_text_edits(vec![change.edit.clone()], text) }

    #[test]
    fn copies_each_row_once_with_a_final_separator() {
        assert_eq!(copy_current_lines(vec![1, 2, 8], "abc\ndef\nx"), "abc\nx\n");
        assert_eq!(copy_current_lines(vec![0, 3], "a\r\nb"), "a\r\nb\r\n");
        assert_eq!(copy_current_lines(vec![2], "a\n"), "\n");
    }

    #[test]
    fn cuts_disjoint_rows_and_clamps_columns() {
        let text = "abc\nx\ndef\nz";
        let change = cut_current_lines(vec![2, 8], text);
        assert_eq!(result(&change, text), "x\nz");
        assert_eq!(change.selections, vec![caret(1), caret(3)]);
        assert_eq!(result(&cut_current_lines(vec![10], text), text), "abc\nx\ndef");
        assert_eq!(result(&cut_current_lines(vec![0, 2], "a\nb"), "a\nb"), "");
    }

    #[test]
    fn moves_adjacent_rows_as_a_block_and_disjoint_rows_independently() {
        let text = "a\nbb\nccc\nd\ne";
        let change = move_selected_lines(vec![caret(3), caret(6), caret(12)], true, text);
        assert_eq!(result(&change, text), "bb\nccc\na\ne\nd");
        assert_eq!(change.selections, vec![caret(1), caret(4), caret(10)]);
        let restored = move_selected_lines(change.selections.clone(), false, &result(&change, text));
        assert_eq!(result(&restored, &result(&change, text)), text);
    }

    #[test]
    fn boundaries_do_not_prevent_other_groups_from_moving() {
        let text = "a\nb\nc\nd";
        let change = move_selected_lines(vec![caret(0), caret(4)], true, text);
        assert_eq!(result(&change, text), "a\nc\nb\nd");
        assert_eq!(change.selections, vec![caret(0), caret(2)]);
    }

    #[test]
    fn preserves_reversed_selections_unicode_and_final_empty_rows() {
        let text = "a\n😀b\nc\n";
        let selection = LineSelection { anchor: 6, head: 2 };
        let change = move_selected_lines(vec![selection, caret(8)], true, text);
        assert_eq!(result(&change, text), "😀b\na\n\nc");
        assert_eq!(change.selections, vec![LineSelection { anchor: 4, head: 0 }, caret(6)]);
        let change = move_selected_lines(vec![caret(3)], true, "a\r\nb\r\nc");
        assert_eq!(result(&change, "a\r\nb\r\nc"), "b\r\na\r\nc");
    }
}
