use crate::files::space_relative_path;
use regex_lite::Regex;

/// `.gitignore` matching for a space. Rules of a folder's `.gitignore` apply below that folder; later
/// and deeper rules win, and `!` re-includes. Paths are relative to the space root with `/` separators.
#[derive(Default)]
pub struct IgnoreRules {
    rules: Vec<Rule>,
}

struct Rule {
    base: String,
    regex: Regex,
    negated: bool,
    dir_only: bool,
}

impl IgnoreRules {
    /// Adds the rules of the `.gitignore` in folder `dir` ("" for the root). Add parents before children.
    pub fn add(&mut self, dir: &str, content: &str) {
        let base = dir.trim_matches('/');
        self.rules.extend(crate::utf16::lines(content).filter_map(|raw| parse(base, raw)));
    }

    /// Whether `path` or one of its folders is ignored.
    pub fn is_ignored(&self, path: &str, is_dir: bool) -> bool {
        let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
        (1..parts.len()).any(|i| self.matches(&parts[..i].join("/"), true)) || self.matches(&parts.join("/"), is_dir)
    }

    /// Whether the item itself matches, assuming its folders aren't ignored.
    pub fn matches(&self, path: &str, is_dir: bool) -> bool {
        let name = path.rsplit('/').next().unwrap_or(path);
        if name == ".git" || name == ".DS_Store" {
            return true;
        }
        let mut ignored = false;
        for rule in &self.rules {
            if rule.dir_only && !is_dir {
                continue;
            }
            let relative = if rule.base.is_empty() {
                path.to_string()
            } else {
                match space_relative_path(path, &rule.base) {
                    Some(relative) => relative,
                    None => continue,
                }
            };
            if rule.regex.is_match(&relative) {
                ignored = !rule.negated;
            }
        }
        ignored
    }
}

fn parse(base: &str, raw: &str) -> Option<Rule> {
    let mut line = raw.trim_end_matches('\r');
    // Trailing spaces count only when escaped.
    while line.ends_with(' ') && !line.ends_with("\\ ") {
        line = &line[..line.len() - 1];
    }
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let mut negated = false;
    if let Some(rest) = line.strip_prefix('!') {
        negated = true;
        line = rest;
    } else if line.starts_with("\\!") || line.starts_with("\\#") {
        line = &line[1..];
    }
    let dir_only = line.ends_with('/');
    line = line.trim_end_matches('/');
    if line.is_empty() {
        return None;
    }
    // A slash anywhere but the end anchors the pattern to its folder; otherwise it matches at any depth.
    let anchored = line.contains('/');
    let glob = glob_to_regex(line.trim_start_matches('/'));
    let pattern = if anchored { format!("^(?:{glob})$") } else { format!("^(?:.*/)?(?:{glob})$") };
    // A pattern git would reject matches nothing rather than failing the whole file.
    let regex = Regex::new(&pattern).ok()?;
    Some(Rule { base: base.to_string(), regex, negated, dir_only })
}

fn glob_to_regex(glob: &str) -> String {
    let g: Vec<char> = glob.chars().collect();
    let starts = |i: usize, s: &str| g[i..].iter().copied().take(s.chars().count()).eq(s.chars());
    let mut out = String::new();
    let mut i = 0;
    while i < g.len() {
        let c = g[i];
        if starts(i, "**/") {
            out.push_str("(?:.*/)?");
            i += 3;
            continue;
        }
        if starts(i, "/**") && i + 3 == g.len() {
            out.push_str("/.*");
            i += 3;
            continue;
        }
        if starts(i, "**") {
            out.push_str(".*");
            i += 2;
            continue;
        }
        match c {
            '*' => out.push_str("[^/]*"),
            '?' => out.push_str("[^/]"),
            '[' => match (i + 2..g.len()).find(|&j| g[j] == ']') {
                Some(end) => {
                    let mut set: String = g[i + 1..end].iter().collect();
                    if let Some(rest) = set.strip_prefix('!') {
                        set = format!("^{rest}");
                    }
                    out.push('[');
                    out.push_str(&set.replace('\\', "\\\\"));
                    out.push(']');
                    i = end + 1;
                    continue;
                }
                None => out.push_str("\\["),
            },
            '\\' if i + 1 < g.len() => {
                out.push_str(&regex_lite::escape(&g[i + 1].to_string()));
                i += 2;
                continue;
            }
            _ => out.push_str(&regex_lite::escape(&c.to_string())),
        }
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_gitignore() {
        let mut rules = IgnoreRules::default();
        rules.add("", "# build output\n*.pdf\n!keep.pdf\n/out/\nbuild/\ndocs/**/*.tmp\n\\#literal\n");
        rules.add("sub", "notes.txt\n/local.typ\n");
        let ignored = |path| rules.is_ignored(path, false);
        assert!(ignored("main.pdf"));
        assert!(ignored("sub/deep/x.pdf"));
        assert!(!ignored("keep.pdf"));
        assert!(ignored("out/a.typ"));
        assert!(!ignored("sub/out/a.typ"));
        assert!(ignored("sub/build/a.typ"));
        assert!(!ignored("build"));
        assert!(ignored("docs/a/b/c.tmp"));
        assert!(ignored("#literal"));
        assert!(ignored("sub/notes.txt"));
        assert!(ignored("sub/a/notes.txt"));
        assert!(!ignored("notes.txt"));
        assert!(ignored("sub/local.typ"));
        assert!(!ignored("sub/a/local.typ"));
        assert!(ignored(".git/HEAD"));
        assert!(ignored(".DS_Store"));
    }
}
