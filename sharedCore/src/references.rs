use crate::text::TextRange;
use crate::utf16::Utf16;

/// A path literal in a Typst file that a move breaks, and what it should say afterwards.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct PathReference {
    /// The literal's contents, without the quotes.
    pub range: TextRange,
    pub line: i32,
    pub old_path: String,
    pub new_path: String,
    /// The path argument of `import`, `include`, `image`, `read` and the like; anything else may only look like a path.
    pub certain: bool,
    /// Inside a comment or raw text, so most likely not a live reference.
    pub in_comment: bool,
}

const PATH_CALLS: &[&str] = &["image", "read", "json", "csv", "yaml", "toml", "xml", "cbor", "bibliography", "plugin"];
const PATH_KEYWORDS: &[&str] = &["import", "include"];

/// Literals in `text`, the Typst file at `file`, that point at `from` or into it, rewritten for its move to `to`.
/// The file itself may move along. Paths are relative to the space root; `exists` checks one before the move,
/// so only literals that point at something count.
pub fn moved_path_references(
    text: &str,
    file: &str,
    from: &str,
    to: &str,
    exists: impl Fn(&str) -> bool,
) -> Vec<PathReference> {
    let t = Utf16::new(text);
    let dir = parent(file);
    let new_dir = parent(&relocate_path(file, from, to)).to_string();
    let mut result = Vec::new();
    let (mut line, mut scanned) = (0, 0);
    for literal in literals(&t) {
        let value = t.slice(literal.start, literal.end);
        // Packages, URLs and escaped strings aren't plain file paths.
        if value.trim().is_empty() || value.starts_with('@') || value.contains("://") || value.contains('\\') {
            continue;
        }
        let absolute = value.starts_with('/');
        let Some(target) = resolve(&value, dir) else { continue };
        if target.is_empty() || !exists(&target) {
            continue;
        }
        let new_target = relocate_path(&target, from, to);
        // Moved together with its file, or not affected at all.
        if resolve(&value, &new_dir).as_deref() == Some(new_target.as_str()) {
            continue;
        }
        let mut replacement = if absolute { format!("/{new_target}") } else { relative_path(&new_dir, &new_target) };
        if value.starts_with("./") && !replacement.starts_with("../") {
            replacement = format!("./{replacement}");
        }
        if value.ends_with('/') && !replacement.ends_with('/') {
            replacement.push('/');
        }
        line += (scanned..literal.start).filter(|&i| t.at(i) == '\n').count() as i32;
        scanned = literal.start;
        result.push(PathReference {
            range: TextRange { location: literal.start as i32, length: (literal.end - literal.start) as i32 },
            line,
            old_path: value,
            new_path: replacement,
            certain: literal.certain,
            in_comment: literal.in_comment,
        });
    }
    result
}

/// Where `path` ends up when `from` moves to `to`.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn relocate_path(path: &str, from: &str, to: &str) -> String {
    if path == from {
        to.to_string()
    } else if path.starts_with(&format!("{from}/")) {
        format!("{to}{}", &path[from.len()..])
    } else {
        path.to_string()
    }
}

/// The path from the folder `dir` to `target`, both relative to the root.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn relative_path(dir: &str, target: &str) -> String {
    let a: Vec<&str> = dir.split('/').filter(|p| !p.is_empty()).collect();
    let b: Vec<&str> = target.split('/').filter(|p| !p.is_empty()).collect();
    let common = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut parts = vec![".."; a.len() - common];
    parts.extend(&b[common..]);
    parts.join("/")
}

/// A literal as typst reads it: from the root with a leading slash, else from the file's folder. None above the root.
fn resolve(value: &str, dir: &str) -> Option<String> {
    let path = match value.strip_prefix('/') {
        Some(rooted) => rooted.to_string(),
        None if dir.is_empty() => value.to_string(),
        None => format!("{dir}/{value}"),
    };
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    Some(parts.join("/"))
}

fn parent(path: &str) -> &str {
    path.rfind('/').map_or("", |i| &path[..i])
}

struct Literal {
    start: usize,
    end: usize,
    certain: bool,
    in_comment: bool,
}

/// String literals with what surrounds them; a light scan of comments, raw text and strings, not a full parse.
fn literals(t: &Utf16) -> Vec<Literal> {
    let mut result = Vec::new();
    let (mut i, mut block_depth, mut line_comment, mut raw_fence) = (0, 0, false, 0);
    let run = |at: usize| (at..t.len()).take_while(|&j| t.at(j) == '`').count();
    while i < t.len() {
        let c = t.at(i);
        if c == '\n' {
            line_comment = false;
        }
        let quiet = raw_fence > 0 || block_depth > 0 || line_comment;
        if raw_fence > 0 && c == '`' {
            let n = run(i);
            if n >= raw_fence {
                raw_fence = 0;
            }
            i += n;
            continue;
        }
        if block_depth > 0 && t.starts_with(i, "*/") {
            block_depth -= 1;
            i += 2;
            continue;
        }
        if raw_fence == 0 && !line_comment && t.starts_with(i, "/*") {
            block_depth += 1;
            i += 2;
            continue;
        }
        if !quiet && t.starts_with(i, "//") && (i == 0 || t.at(i - 1) != ':') {
            line_comment = true;
            i += 2;
            continue;
        }
        if !quiet && c == '\\' {
            i += 2;
            continue;
        }
        if !quiet && c == '`' {
            let n = run(i);
            // Two backticks are an empty raw.
            if n != 2 {
                raw_fence = n;
            }
            i += n;
            continue;
        }
        if c == '"'
            && let Some(end) = string_end(t, i)
        {
            result.push(Literal { start: i + 1, end, certain: !quiet && is_path_argument(t, i), in_comment: quiet });
            i = end + 1;
            continue;
        }
        i += 1;
    }
    result
}

/// The closing quote of the string opening at `start`, or None if it doesn't close on its line.
fn string_end(t: &Utf16, start: usize) -> Option<usize> {
    let mut i = start + 1;
    while i < t.len() {
        match t.at(i) {
            '\\' => i += 1,
            '"' => return Some(i),
            '\n' => return None,
            _ => {}
        }
        i += 1;
    }
    None
}

/// Whether the string opening at `quote` follows `import`, `include` or opens a call like `image(`.
fn is_path_argument(t: &Utf16, quote: usize) -> bool {
    let blank = |i: usize| matches!(t.at(i), ' ' | '\t');
    let mut i = quote;
    while i > 0 && blank(i - 1) {
        i -= 1;
    }
    let call = i > 0 && t.at(i - 1) == '(';
    if call {
        i -= 1;
        while i > 0 && blank(i - 1) {
            i -= 1;
        }
    }
    let end = i;
    while i > 0 && (t.at(i - 1).is_alphanumeric() || matches!(t.at(i - 1), '-' | '_')) {
        i -= 1;
    }
    // A field access like `image.decode(` is another function.
    if i > 0 && t.at(i - 1) == '.' {
        return false;
    }
    let word = t.slice(i, end);
    if call { PATH_CALLS.contains(&word.as_str()) } else { PATH_KEYWORDS.contains(&word.as_str()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text::{TextEdit, apply_text_edits};

    const FILES: &[&str] = &["main.typ", "chapters/intro.typ", "img/logo.png", "img", "chapters", "refs.bib"];

    fn moved(text: &str, file: &str, from: &str, to: &str) -> Vec<PathReference> {
        moved_path_references(text, file, from, to, |p| FILES.contains(&p))
    }

    fn summary(refs: &[PathReference]) -> Vec<String> {
        refs.iter().map(|r| format!("{}:{}->{}:{}:{}", r.line, r.old_path, r.new_path, r.certain, r.in_comment)).collect()
    }

    #[test]
    fn rewrites_references_to_the_moved_file() {
        let text = "#import \"chapters/intro.typ\": *\n\
            #include \"/chapters/intro.typ\"\n\
            // see \"chapters/intro.typ\"\n\
            #my-chapter(\"./chapters/intro.typ\")\n\
            #image(\"img/logo.png\")";
        let refs = moved(text, "main.typ", "chapters/intro.typ", "parts/intro.typ");
        assert_eq!(
            vec![
                "0:chapters/intro.typ->parts/intro.typ:true:false",
                "1:/chapters/intro.typ->/parts/intro.typ:true:false",
                "2:chapters/intro.typ->parts/intro.typ:false:true",
                "3:./chapters/intro.typ->./parts/intro.typ:false:false",
            ],
            summary(&refs),
        );
        let edits = refs.iter().map(|r| TextEdit { range: r.range, new_text: r.new_path.clone() }).collect();
        assert_eq!("#import \"parts/intro.typ\": *", apply_text_edits(edits, text).lines().next().unwrap());
    }

    #[test]
    fn follows_the_moving_files_own_references() {
        let text = "#image(\"../img/logo.png\")\n#bibliography(\"/refs.bib\")\n#import \"@preview/cetz:0.3.1\"";
        let refs = moved(text, "chapters/intro.typ", "chapters/intro.typ", "intro.typ");
        assert_eq!(vec!["0:../img/logo.png->img/logo.png:true:false"], summary(&refs));
    }

    #[test]
    fn folders_move_with_their_contents() {
        let text = "#image(\"logo.png\")\n#import \"../main.typ\"";
        // A file inside the moved folder keeps references inside it, but one to the outside changes depth.
        let refs = moved(text, "img/a.typ", "img", "assets/img");
        assert_eq!(vec!["1:../main.typ->../../main.typ:true:false"], summary(&refs));
        let outside = moved("#image(\"img/logo.png\")", "main.typ", "img", "assets/img");
        assert_eq!(vec!["0:img/logo.png->assets/img/logo.png:true:false"], summary(&outside));
    }

    #[test]
    fn skips_missing_paths_raw_and_urls() {
        let text = "#link(\"https://x.y/img/logo.png\")\n#image(\"img/missing.png\")\n```\n#image(\"img/logo.png\")\n```\nhttps://example.com \"img/logo.png\"";
        let refs = moved(text, "main.typ", "img/logo.png", "logo.png");
        assert_eq!(vec!["3:img/logo.png->logo.png:false:true", "5:img/logo.png->logo.png:false:false"], summary(&refs));
    }

    #[test]
    fn relative_paths() {
        assert_eq!("../b/c.typ", relative_path("a", "b/c.typ"));
        assert_eq!("c.typ", relative_path("", "c.typ"));
        assert_eq!("../..", relative_path("a/b", ""));
        assert_eq!("x/y.png", relocate_path("img/y.png", "img", "x"));
    }
}
