use crate::merge::matches;

/// How a run of lines differs between two texts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Enum))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
#[cfg_attr(target_arch = "wasm32", serde(rename_all = "lowercase"))]
pub enum DiffKind {
    Same,
    Added,
    Removed,
}

/// Consecutive lines of one kind, without their line breaks.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct DiffHunk {
    pub kind: DiffKind,
    pub lines: Vec<String>,
}

/// Line diff from `old` to `new` along a shortest edit script (Myers); removals come before additions.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn line_diff(old: &str, new: &str) -> Vec<DiffHunk> {
    let (a, b): (Vec<&str>, Vec<&str>) = (old.lines().collect(), new.lines().collect());
    let matched = matches(&a, &b);
    let mut hunks: Vec<DiffHunk> = Vec::new();
    let mut push = |kind: DiffKind, line: &str| match hunks.last_mut() {
        Some(last) if last.kind == kind => last.lines.push(line.to_string()),
        _ => hunks.push(DiffHunk { kind, lines: vec![line.to_string()] }),
    };
    let mut j = 0;
    for (i, line) in a.iter().enumerate() {
        match matched[i] {
            Some(to) => {
                b[j..to].iter().for_each(|added| push(DiffKind::Added, added));
                push(DiffKind::Same, line);
                j = to + 1;
            }
            None => push(DiffKind::Removed, line),
        }
    }
    // Additions only flush before a kept line, so they always follow the removals they replace.
    b[j..].iter().for_each(|added| push(DiffKind::Added, added));
    hunks
}

/// A zero-based, half-open range of lines traced into an older text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct HistoryLines {
    pub start: u32,
    pub end: u32,
    pub changed: bool,
}

/// Tracks whole selected lines backward, including replacements but excluding adjacent insertions.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn trace_history_lines(old: &str, new: &str, start: u32, end: u32) -> HistoryLines {
    let hunks = line_diff(old, new);
    let (start, end) = (start as usize, end as usize);
    let (mut a, mut b, mut i) = (0, 0, 0);
    let (mut first, mut last) = (None, 0);
    let mut changed = false;
    while i < hunks.len() {
        if hunks[i].kind == DiffKind::Same {
            let count = hunks[i].lines.len();
            let (lo, hi) = (start.max(b), end.min(b + count));
            if lo < hi {
                first.get_or_insert(a + lo - b);
                last = a + hi - b;
            }
            a += count;
            b += count;
            i += 1;
        } else {
            let (old_start, new_start) = (a, b);
            while i < hunks.len() && hunks[i].kind != DiffKind::Same {
                match hunks[i].kind {
                    DiffKind::Removed => a += hunks[i].lines.len(),
                    DiffKind::Added => b += hunks[i].lines.len(),
                    _ => {}
                }
                i += 1;
            }
            let overlaps = if b == new_start {
                start < b && b < end
            } else {
                start < b && new_start < end
            };
            if overlaps {
                changed = true;
                first.get_or_insert(old_start);
                last = a;
            }
        }
    }
    HistoryLines { start: first.unwrap_or(a) as u32, end: last.max(first.unwrap_or(a)) as u32, changed }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hunk(kind: DiffKind, lines: &[&str]) -> DiffHunk {
        DiffHunk { kind, lines: lines.iter().map(|l| l.to_string()).collect() }
    }

    #[test]
    fn history_tracks_shifted_lines_without_marking_them_changed() {
        assert_eq!(trace_history_lines("a\nb\nc", "intro\na\nb\nc", 2, 3),
                   HistoryLines { start: 1, end: 2, changed: false });
    }

    #[test]
    fn history_follows_replacements_and_stops_at_creation() {
        assert_eq!(trace_history_lines("a\nold\nc", "a\nnew\nextra\nc", 1, 3),
                   HistoryLines { start: 1, end: 2, changed: true });
        assert_eq!(trace_history_lines("a\nc", "a\nnew\nc", 1, 2),
                   HistoryLines { start: 1, end: 1, changed: true });
    }

    #[test]
    fn history_includes_internal_deletions_but_not_boundary_changes() {
        assert_eq!(trace_history_lines("a\ndeleted\nb", "a\nb", 0, 2),
                   HistoryLines { start: 0, end: 3, changed: true });
        assert_eq!(trace_history_lines("a\ndeleted\nb", "a\nb", 1, 2),
                   HistoryLines { start: 2, end: 3, changed: false });
        assert_eq!(trace_history_lines("a\nb", "a\ninserted\nb", 0, 1),
                   HistoryLines { start: 0, end: 1, changed: false });
    }

    #[test]
    fn equal_texts_are_one_hunk() {
        assert_eq!(vec![hunk(DiffKind::Same, &["a", "b"])], line_diff("a\nb\n", "a\nb"));
        assert!(line_diff("", "").is_empty());
    }

    #[test]
    fn finds_additions_and_removals() {
        let diff = line_diff("a\nb\nc\nd\n", "a\nc\nd\ne\n");
        assert_eq!(
            vec![
                hunk(DiffKind::Same, &["a"]),
                hunk(DiffKind::Removed, &["b"]),
                hunk(DiffKind::Same, &["c", "d"]),
                hunk(DiffKind::Added, &["e"]),
            ],
            diff
        );
    }

    #[test]
    fn replacements_remove_first() {
        let diff = line_diff("x\nold\ny\n", "x\nnew\ny\n");
        assert_eq!(
            vec![
                hunk(DiffKind::Same, &["x"]),
                hunk(DiffKind::Removed, &["old"]),
                hunk(DiffKind::Added, &["new"]),
                hunk(DiffKind::Same, &["y"]),
            ],
            diff
        );
        assert_eq!(vec![hunk(DiffKind::Removed, &["a"]), hunk(DiffKind::Added, &["b", "c"])], line_diff("a", "b\nc"));
    }

    #[test]
    fn from_and_to_empty() {
        assert_eq!(vec![hunk(DiffKind::Added, &["a", "b"])], line_diff("", "a\nb\n"));
        assert_eq!(vec![hunk(DiffKind::Removed, &["a"])], line_diff("a\n", ""));
    }
}
