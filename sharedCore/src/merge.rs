use std::collections::HashMap;

/// A merged text; `conflicts` counts the regions both sides changed differently.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct MergeResult {
    pub text: String,
    pub conflicts: i32,
}

/// Line-based three-way merge of two edits of `base`; conflicting regions get git-style markers.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn merge3(base: &str, local: &str, remote: &str) -> MergeResult {
    let unchanged = |text: &str| MergeResult { text: text.to_string(), conflicts: 0 };
    if local == remote || remote == base {
        return unchanged(local);
    }
    if local == base {
        return unchanged(remote);
    }
    let (o, a, b) = (lines(base), lines(local), lines(remote));
    let (match_a, match_b) = (matches(&o, &a), matches(&o, &b));
    let mut out = String::new();
    let mut conflicts = 0;
    let (mut io, mut ia, mut ib) = (0, 0, 0);
    loop {
        // Lines that are unchanged on both sides from here.
        let mut stable = 0;
        while io + stable < o.len() && match_a[io + stable] == Some(ia + stable) && match_b[io + stable] == Some(ib + stable)
        {
            stable += 1;
        }
        if stable > 0 {
            o[io..io + stable].iter().for_each(|line| out.push_str(line));
            io += stable;
            ia += stable;
            ib += stable;
            continue;
        }
        // The next base line both sides kept ends the changed region.
        let mut next = io;
        while next < o.len() && (match_a[next].is_none() || match_b[next].is_none()) {
            next += 1;
        }
        let end_a = if next < o.len() { match_a[next].unwrap() } else { a.len() };
        let end_b = if next < o.len() { match_b[next].unwrap() } else { b.len() };
        let (chunk_o, chunk_a, chunk_b) = (&o[io..next], &a[ia..end_a], &b[ib..end_b]);
        if chunk_a == chunk_o {
            chunk_b.iter().for_each(|line| out.push_str(line));
        } else if chunk_b == chunk_o || chunk_a == chunk_b {
            chunk_a.iter().for_each(|line| out.push_str(line));
        } else {
            conflicts += 1;
            let push = |out: &mut String, chunk: &[&str]| {
                for line in chunk {
                    out.push_str(line);
                    if !line.ends_with('\n') {
                        out.push('\n');
                    }
                }
            };
            out.push_str("<<<<<<< local\n");
            push(&mut out, chunk_a);
            out.push_str("=======\n");
            push(&mut out, chunk_b);
            out.push_str(">>>>>>> remote\n");
        }
        if next >= o.len() && end_a >= a.len() && end_b >= b.len() {
            break;
        }
        (io, ia, ib) = (next, end_a, end_b);
    }
    MergeResult { text: out, conflicts }
}

/// Lines including their line breaks, so joining them gives the text back.
fn lines(text: &str) -> Vec<&str> {
    text.split_inclusive('\n').collect()
}

/// For each line of `a`, the index of the matching line in `b` along a shortest edit script.
pub(crate) fn matches(a: &[&str], b: &[&str]) -> Vec<Option<usize>> {
    let mut ids = HashMap::new();
    let mut id = |line: &str| {
        let next = ids.len();
        *ids.entry(line.to_string()).or_insert(next)
    };
    let x: Vec<usize> = a.iter().map(|l| id(l)).collect();
    let y: Vec<usize> = b.iter().map(|l| id(l)).collect();
    let (n, m) = (x.len() as isize, y.len() as isize);
    let max = n + m;
    let offset = max + 1;
    let mut v = vec![0isize; (2 * max + 3) as usize];
    let at = |k: isize| (offset + k) as usize;
    let mut trace = Vec::new();
    // Myers' greedy forward search, keeping each round for the backtrack.
    'search: for d in 0..=max {
        trace.push(v.clone());
        let mut k = -d;
        while k <= d {
            let mut i = if k == -d || (k != d && v[at(k - 1)] < v[at(k + 1)]) { v[at(k + 1)] } else { v[at(k - 1)] + 1 };
            let mut j = i - k;
            while i < n && j < m && x[i as usize] == y[j as usize] {
                i += 1;
                j += 1;
            }
            v[at(k)] = i;
            if i >= n && j >= m {
                break 'search;
            }
            k += 2;
        }
    }
    let mut result = vec![None; n as usize];
    let (mut i, mut j) = (n, m);
    for d in (0..trace.len() as isize).rev() {
        let prev = &trace[d as usize];
        let k = i - j;
        let prev_k = if k == -d || (k != d && prev[at(k - 1)] < prev[at(k + 1)]) { k + 1 } else { k - 1 };
        let prev_i = if d == 0 { 0 } else { prev[at(prev_k)] };
        let prev_j = prev_i - prev_k;
        while i > prev_i && j > prev_j {
            i -= 1;
            j -= 1;
            result[i as usize] = Some(j as usize);
        }
        if d > 0 {
            (i, j) = (prev_i, prev_j);
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn merged(text: &str) -> MergeResult {
        MergeResult { text: text.into(), conflicts: 0 }
    }

    #[test]
    fn merges_separate_edits() {
        let result = merge3("a\nb\nc\nd\ne\n", "A\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\nf\n");
        assert_eq!(merged("A\nb\nc\nd\nE\nf\n"), result);
    }

    #[test]
    fn merges_insertions_and_deletions() {
        let result = merge3("one\ntwo\nthree\nfour\n", "zero\none\ntwo\nthree\nfour\n", "one\nthree\nfour");
        assert_eq!(merged("zero\none\nthree\nfour"), result);
    }

    #[test]
    fn marks_conflicts() {
        let result = merge3("x\ny\n", "x\nlocal\n", "x\nremote\n");
        assert_eq!(1, result.conflicts);
        assert_eq!("x\n<<<<<<< local\nlocal\n=======\nremote\n>>>>>>> remote\n", result.text);
    }
}
