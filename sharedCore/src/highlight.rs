//! Highlighting for code embedded in Typst raw blocks and Markdown fences.
use crate::utf16::Utf16;
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

/// Token kinds of `code_tokens`; the Swift and web sides mirror these values.
pub mod kind {
    pub const KEYWORD: i32 = 0;
    pub const STRING: i32 = 1;
    pub const COMMENT: i32 = 2;
    pub const NUMBER: i32 = 3;
    pub const FUNCTION: i32 = 4;
    pub const TYPE: i32 = 5;
    pub const VARIABLE: i32 = 6;
    pub const ANNOTATION: i32 = 7;
    pub const OPERATOR: i32 = 8;
    pub const UNIT: i32 = 9;
}

const ALIASES: &[(&str, &str)] = &[
    ("sql", "sql"),
    ("bash", "bash"),
    ("sh", "bash"),
    ("shell", "bash"),
    ("zsh", "bash"),
    ("console", "bash"),
    ("javascript", "javascript"),
    ("js", "javascript"),
    ("jsx", "javascript"),
    ("mjs", "javascript"),
    ("cjs", "javascript"),
    ("typescript", "typescript"),
    ("ts", "typescript"),
    ("tsx", "typescript"),
    ("kotlin", "kotlin"),
    ("kt", "kotlin"),
    ("kts", "kotlin"),
    ("java", "java"),
    ("python", "python"),
    ("py", "python"),
    ("python3", "python"),
    ("csharp", "csharp"),
    ("cs", "csharp"),
    ("c#", "csharp"),
    ("markdown", "markdown"),
    ("md", "markdown"),
    ("typst", "typst"),
    ("typ", "typst"),
    ("typc", "typc"),
    ("mermaid", "mermaid"),
    ("mmd", "mermaid"),
    // Highlighted by solveng's own editor support (solveng-ide, in the typst bridge).
    ("solveng", "solveng"),
];

/// Canonical languages, for completing fence tags.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn code_languages() -> Vec<String> {
    let mut seen = HashSet::new();
    ALIASES.iter().filter(|(_, lang)| seen.insert(*lang)).map(|(_, lang)| lang.to_string()).collect()
}

/// The canonical language for a fence tag (`py` → `python`), or None for unsupported ones.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn code_language(tag: &str) -> Option<String> {
    let tag = tag.trim().to_lowercase();
    ALIASES.iter().find(|(alias, _)| *alias == tag).map(|(_, lang)| lang.to_string())
}

/// Splits a Typst raw block (```` ```lang body``` ````) into its language tag and body.
/// Returns UTF-16 `[tag_start, tag_end, body_start, body_end]`, or nothing without a tag.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn raw_block_parts(raw: &str) -> Vec<i32> {
    let r = Utf16::new(raw);
    let ticks = (0..r.len()).take_while(|&i| r.at(i) == '`').count();
    if ticks < 3 {
        return vec![];
    }
    let mut tag_end = ticks;
    while tag_end < r.len() && r.at(tag_end) != '`' && !r.at(tag_end).is_whitespace() {
        tag_end += 1;
    }
    if tag_end == ticks {
        return vec![];
    }
    let (mut body_end, mut closing) = (r.len(), 0);
    while closing < ticks && body_end > tag_end && r.at(body_end - 1) == '`' {
        body_end -= 1;
        closing += 1;
    }
    [ticks, tag_end, tag_end, body_end].map(|i| i as i32).into()
}

/// Tokens of `code` in a canonical `language`, as flat UTF-16 `(start, length, kind)` triples with
/// kinds from [`kind`]. Empty for languages without a tokenizer (Markdown, Typst, unknown).
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn code_tokens(language: &str, code: &str) -> Vec<i32> {
    let Some(lang) = LANGUAGES.get(language) else { return vec![] };
    let s = Utf16::new(code);
    let mut scanner = Scanner { lang, s: &s, out: Vec::new() };
    scanner.scan(0, s.len(), 0);
    scanner.out
}

#[derive(Default)]
struct Lang {
    keywords: HashSet<String>,
    types: HashSet<String>,
    line_comments: &'static [&'static str],
    block_comment: Option<(&'static str, &'static str)>,
    quotes: &'static str,
    /// Quote chars that may span lines; the others end at a newline.
    multiline: &'static str,
    /// Quote chars that also open triple-quoted strings.
    triple: &'static str,
    raw_triple: bool,
    /// Quote chars without backslash escapes.
    raw_quotes: &'static str,
    /// String prefixes like Python's `rb` or C#'s `$@`, longest first; ones with a raw char turn escapes off.
    prefixes: Vec<String>,
    raw_prefix_chars: &'static str,
    /// Quote chars whose strings interpolate `${…}`.
    interpolated: &'static str,
    /// `$name` interpolates too, not just `${…}`.
    dollar_names: bool,
    /// `${…}` holds code (Kotlin, JavaScript) rather than a variable expansion (shells).
    brace_code: bool,
    /// `$x` outside strings is a variable.
    variables: bool,
    annotations: bool,
    capital_types: bool,
    case_insensitive: bool,
    /// Shell style: the first word of a command is a function and `#` only comments at a word start.
    commands: bool,
    command_after: HashSet<String>,
    /// Extra identifier chars, also allowed first.
    ident_chars: &'static str,
    /// Extra chars allowed inside identifiers only, like the dash in `apt-get`.
    ident_inner: &'static str,
    /// Runs of these chars, two or more long, are operators (Mermaid arrows).
    operator_chars: &'static str,
}

impl Lang {
    fn new(keywords: &str) -> Self {
        Self { keywords: words(keywords), quotes: "\"'", brace_code: true, ident_chars: "_", ..Self::default() }
    }

    fn types(mut self, types: &str) -> Self {
        self.types = words(types);
        self
    }

    fn prefixes(mut self, prefixes: &str) -> Self {
        let mut list: Vec<String> = words(prefixes).into_iter().collect();
        list.sort_by(|a, b| b.len().cmp(&a.len()).then_with(|| a.cmp(b)));
        self.prefixes = list;
        self
    }

    fn command_after(mut self, words_: &str) -> Self {
        self.command_after = words(words_);
        self
    }

    /// Keywords and types match lowercased in case-insensitive languages.
    fn case_insensitive(mut self) -> Self {
        self.case_insensitive = true;
        self.keywords = self.keywords.iter().map(|w| w.to_lowercase()).collect();
        self.types = self.types.iter().map(|w| w.to_lowercase()).collect();
        self
    }
}

fn words(s: &str) -> HashSet<String> {
    s.split_whitespace().map(str::to_string).collect()
}

const JS_KEYWORDS: &str = "
break case catch class const continue debugger default delete do else export extends finally for function if
import in instanceof let new return super switch this throw try typeof var void while with yield async await of
static from as true false null undefined NaN Infinity";

static LANGUAGES: LazyLock<HashMap<&'static str, Lang>> = LazyLock::new(|| {
    HashMap::from([
        (
            "sql",
            Lang {
                line_comments: &["--"],
                block_comment: Some(("/*", "*/")),
                quotes: "'\"`",
                multiline: "'\"`",
                raw_quotes: "'\"`",
                ..Lang::new(
                    "
select from where and or not null is in as on join inner left right outer full cross natural using group by
order having limit offset union all distinct insert into values update set delete create table view index drop
alter add column primary key foreign references constraint unique default check if exists case when then else
end begin commit rollback transaction with recursive returning asc desc like ilike between true false cascade
database schema grant revoke trigger procedure function return returns declare replace temporary temp over
partition window rows range unbounded preceding following current row filter except intersect lateral fetch
first next only top collate escape do nothing conflict",
                )
                .types(
                    "
int integer smallint bigint tinyint serial bigserial decimal numeric real float double precision char varchar
text boolean bool date time timestamp timestamptz interval uuid json jsonb blob bytea money",
                )
            }
            .case_insensitive(),
        ),
        (
            "bash",
            Lang {
                line_comments: &["#"],
                quotes: "'\"`",
                multiline: "'\"`",
                raw_quotes: "'",
                interpolated: "\"",
                dollar_names: true,
                brace_code: false,
                variables: true,
                commands: true,
                ident_inner: "-.",
                ..Lang::new(
                    "
if then else elif fi for while until do done case esac in function select return exit break continue local
export readonly declare typeset unset source alias shift trap eval exec time",
                )
            }
            .command_after("if then else elif while until do time exec"),
        ),
        (
            "javascript",
            Lang {
                line_comments: &["//"],
                block_comment: Some(("/*", "*/")),
                quotes: "'\"`",
                multiline: "`",
                interpolated: "`",
                annotations: true,
                capital_types: true,
                ident_chars: "_$",
                ..Lang::new(JS_KEYWORDS)
            },
        ),
        (
            "typescript",
            Lang {
                line_comments: &["//"],
                block_comment: Some(("/*", "*/")),
                quotes: "'\"`",
                multiline: "`",
                interpolated: "`",
                annotations: true,
                capital_types: true,
                ident_chars: "_$",
                ..Lang::new(&format!(
                    "{JS_KEYWORDS} interface type enum implements namespace declare abstract readonly private \
                     public protected keyof infer is satisfies module"
                ))
                .types("string number boolean any unknown never void object symbol bigint")
            },
        ),
        (
            "kotlin",
            Lang {
                line_comments: &["//"],
                block_comment: Some(("/*", "*/")),
                triple: "\"",
                raw_triple: true,
                interpolated: "\"",
                dollar_names: true,
                annotations: true,
                capital_types: true,
                ..Lang::new(
                    "
package import class interface object fun val var if else when for while do return break continue throw try
catch finally in is as typealias this super null true false constructor init companion data sealed enum
abstract open override private protected public internal inline suspend operator infix lateinit const vararg
reified crossinline noinline by where out annotation inner expect actual external tailrec",
                )
            },
        ),
        (
            "java",
            Lang {
                line_comments: &["//"],
                block_comment: Some(("/*", "*/")),
                triple: "\"",
                annotations: true,
                capital_types: true,
                ident_chars: "_$",
                ..Lang::new(
                    "
abstract assert break case catch class const continue default do else enum extends final finally for goto if
implements import instanceof interface native new package private protected public return static strictfp super
switch synchronized this throw throws transient try volatile while true false null record sealed permits yield
var",
                )
                .types("boolean byte char short int long float double void")
            },
        ),
        (
            "python",
            Lang {
                line_comments: &["#"],
                triple: "\"'",
                raw_prefix_chars: "rR",
                annotations: true,
                capital_types: true,
                ..Lang::new(
                    "
False None True and as assert async await break class continue def del elif else except finally for from
global if import in is lambda nonlocal not or pass raise return try while with yield match case",
                )
                .types("int float str bool bytes list dict set tuple object type complex frozenset bytearray")
                .prefixes("r u b f rb br fr rf")
            },
        ),
        (
            "csharp",
            Lang {
                line_comments: &["//"],
                block_comment: Some(("/*", "*/")),
                triple: "\"",
                raw_triple: true,
                raw_prefix_chars: "@",
                capital_types: true,
                ..Lang::new(
                    "
abstract as base break case catch checked class const continue default delegate do else enum event explicit
extern false finally fixed for foreach goto if implicit in interface internal is lock namespace new null operator
out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch
this throw true try typeof unchecked unsafe using virtual volatile while async await get set init record yield
where when nameof global partial required with var",
                )
                .types(
                    "bool byte sbyte char decimal double float int uint long ulong short ushort object string void dynamic \
                     nint nuint",
                )
                .prefixes("@ $ $@ @$")
            },
        ),
        (
            "mermaid",
            Lang {
                line_comments: &["%%"],
                quotes: "\"",
                raw_quotes: "\"",
                ident_inner: "-",
                operator_chars: "-=.<>",
                ..Lang::new(
                    "
graph flowchart subgraph end direction TB TD BT RL LR sequenceDiagram classDiagram stateDiagram stateDiagram-v2
erDiagram gantt pie journey gitGraph mindmap timeline quadrantChart requirementDiagram participant actor as note
over of left right loop alt else opt par and critical break rect activate deactivate autonumber class classDef
style linkStyle click callback state title section dateFormat axisFormat excludes todayMarker commit branch
checkout merge accTitle accDescr",
                )
            },
        ),
    ])
});

/// A single pass over the code; `${…}` interpolations recurse a few levels at most.
struct Scanner<'a> {
    lang: &'a Lang,
    s: &'a Utf16,
    out: Vec<i32>,
}

impl Scanner<'_> {
    fn emit(&mut self, start: usize, end: usize, kind: i32) {
        if end <= start {
            return;
        }
        let (start, end) = (start as i32, end as i32);
        // Neighbours of one kind, like string parts around an escape, merge.
        if let [.., last_start, last_length, last_kind] = self.out[..]
            && last_kind == kind
            && last_start + last_length == start
        {
            let at = self.out.len() - 2;
            self.out[at] = end - last_start;
            return;
        }
        self.out.extend([start, end - start, kind]);
    }

    fn ident_start(&self, c: char) -> bool {
        c.is_alphabetic() || self.lang.ident_chars.contains(c)
    }

    fn ident_part(&self, c: char) -> bool {
        c.is_alphanumeric() || self.lang.ident_chars.contains(c)
    }

    fn at(&self, i: usize) -> char {
        self.s.at(i)
    }

    fn scan(&mut self, from: usize, to: usize, depth: u32) {
        let (lang, s) = (self.lang, self.s);
        let mut i = from;
        let mut command = true;
        while i < to {
            let c = self.at(i);
            if c == '\n' {
                command = true;
                i += 1;
                continue;
            }
            if c.is_whitespace() {
                i += 1;
                continue;
            }
            let line = lang.line_comments.iter().any(|p| s.starts_with(i, p));
            if line && (!lang.commands || i == from || self.at(i - 1).is_whitespace() || self.at(i - 1) == ';') {
                let end = s.find_char('\n', i).filter(|&e| e <= to).unwrap_or(to);
                self.emit(i, end, kind::COMMENT);
                i = end;
                continue;
            }
            if let Some((open, close)) = lang.block_comment.filter(|(open, _)| s.starts_with(i, open)) {
                let close_len = close.len();
                let end = match s.find(close, i + open.len()) {
                    Some(at) if at + close_len <= to => at + close_len,
                    _ => to,
                };
                self.emit(i, end, kind::COMMENT);
                i = end;
                continue;
            }
            if lang.quotes.contains(c) {
                i = self.string(i, i, to, false, depth);
                command = false;
                continue;
            }
            let prefix = lang.prefixes.iter().find(|p| {
                let n = p.len();
                s.starts_with_ignoring_case(i, p) && i + n < to && lang.quotes.contains(self.at(i + n))
            });
            if let Some(prefix) = prefix {
                let raw = prefix.chars().any(|p| lang.raw_prefix_chars.contains(p));
                i = self.string(i, i + prefix.len(), to, raw, depth);
                command = false;
                continue;
            }
            if lang.variables && c == '$' {
                i = self.variable(i, to, depth);
                command = false;
                continue;
            }
            if lang.annotations && c == '@' && i + 1 < to && self.ident_start(self.at(i + 1)) {
                let mut j = i + 2;
                while j < to
                    && (self.ident_part(self.at(j)) || (self.at(j) == '.' && j + 1 < to && self.ident_start(self.at(j + 1))))
                {
                    j += 1;
                }
                self.emit(i, j, kind::ANNOTATION);
                i = j;
                continue;
            }
            if c.is_numeric() || (c == '.' && i + 1 < to && self.at(i + 1).is_numeric()) {
                let end = self.number(i, to);
                self.emit(i, end, kind::NUMBER);
                i = end;
                continue;
            }
            if self.ident_start(c) {
                let mut j = i + 1;
                while j < to
                    && (self.ident_part(self.at(j))
                        || (lang.ident_inner.contains(self.at(j)) && j + 1 < to && self.ident_part(self.at(j + 1))))
                {
                    j += 1;
                }
                let word = s.slice(i, j);
                let key = if lang.case_insensitive { word.to_lowercase() } else { word.clone() };
                let next = (j < to).then(|| self.at(j));
                let token = if lang.keywords.contains(&key) {
                    Some(kind::KEYWORD)
                } else if lang.types.contains(&key) {
                    Some(kind::TYPE)
                } else if lang.commands && next == Some('=') {
                    Some(kind::VARIABLE)
                } else if next == Some('(') || (lang.commands && command) {
                    Some(kind::FUNCTION)
                } else if lang.capital_types && c.is_uppercase() && word.chars().any(char::is_lowercase) {
                    Some(kind::TYPE)
                } else {
                    None
                };
                if let Some(token) = token {
                    self.emit(i, j, token);
                }
                // `FOO=1 cmd` keeps looking for the command; keywords like `then` start a new one.
                command = token == Some(kind::VARIABLE)
                    || (token == Some(kind::KEYWORD) && lang.command_after.contains(&key));
                i = j;
                if token == Some(kind::VARIABLE) {
                    // A plain assigned value isn't a command either.
                    i += 1;
                    while i < to && !self.at(i).is_whitespace() && !";|&\"'`$".contains(self.at(i)) {
                        i += 1;
                    }
                }
                continue;
            }
            if lang.operator_chars.contains(c) {
                let mut j = i + 1;
                while j < to && lang.operator_chars.contains(self.at(j)) {
                    j += 1;
                }
                if j - i >= 2 {
                    self.emit(i, j, kind::OPERATOR);
                }
                i = j;
                continue;
            }
            if "|;&(".contains(c) {
                command = true;
            }
            i += 1;
        }
    }

    fn number(&self, start: usize, to: usize) -> usize {
        let hex = self.s.starts_with_ignoring_case(start, "0x");
        let mut j = start;
        while j < to {
            let c = self.at(j);
            let part = c.is_alphanumeric() || c == '_' || (c == '.' && j + 1 < to && self.at(j + 1).is_numeric());
            let exponent = !hex && (c == '+' || c == '-') && matches!(self.at(j - 1), 'e' | 'E');
            if !part && !exponent {
                break;
            }
            j += 1;
        }
        j
    }

    /// A string from `start` (its prefix) whose quote is at `quote`; returns the end.
    fn string(&mut self, start: usize, quote: usize, to: usize, raw: bool, depth: u32) -> usize {
        let lang = self.lang;
        let q = self.at(quote);
        let triple = lang.triple.contains(q) && quote + 2 < to && self.at(quote + 1) == q && self.at(quote + 2) == q;
        let close_length = if triple { 3 } else { 1 };
        let escapes = !raw && !lang.raw_quotes.contains(q) && !(triple && lang.raw_triple);
        let interpolates = lang.interpolated.contains(q);
        let mut i = quote + close_length;
        let mut part = start;
        while i < to {
            let c = self.at(i);
            if escapes && c == '\\' {
                i += 2;
                continue;
            }
            if c == q && (!triple || (i + 2 < to && self.at(i + 1) == q && self.at(i + 2) == q)) {
                i += close_length;
                // Kotlin's `""""` ends on the last quote.
                while triple && i < to && self.at(i) == q {
                    i += 1;
                }
                self.emit(part, i, kind::STRING);
                return i;
            }
            if c == '\n' && !triple && !lang.multiline.contains(q) {
                break;
            }
            if interpolates && c == '$' && i + 1 < to {
                let next = self.at(i + 1);
                if next == '{' || (lang.dollar_names && (self.ident_start(next) || next.is_numeric())) {
                    self.emit(part, i, kind::STRING);
                    i = self.variable(i, to, depth);
                    part = i;
                    continue;
                }
            }
            i += 1;
        }
        let end = i.min(to);
        self.emit(part, end, kind::STRING);
        end
    }

    /// `$name`, `${…}` or a shell special like `$?` at `start`; returns the end.
    fn variable(&mut self, start: usize, to: usize, depth: u32) -> usize {
        if start + 1 >= to {
            return start + 1;
        }
        let next = self.at(start + 1);
        if next == '{' {
            let (mut j, mut open) = (start + 2, 1);
            while j < to {
                if self.at(j) == '{' {
                    open += 1;
                }
                if self.at(j) == '}' {
                    open -= 1;
                    if open == 0 {
                        break;
                    }
                }
                j += 1;
            }
            let end = (j + 1).min(to);
            if self.lang.brace_code && depth < 4 {
                self.emit(start, start + 2, kind::KEYWORD);
                self.scan(start + 2, j.min(to), depth + 1);
                if j < to {
                    self.emit(j, j + 1, kind::KEYWORD);
                }
            } else {
                self.emit(start, end, kind::VARIABLE);
            }
            return end;
        }
        let mut j = start + 1;
        if self.ident_start(next) || next.is_numeric() {
            while j < to && (self.at(j).is_alphanumeric() || self.at(j) == '_') {
                j += 1;
            }
        } else if self.lang.commands && "@*#?$!-".contains(next) {
            j += 1;
        } else {
            return start + 1;
        }
        self.emit(start, j, kind::VARIABLE);
        j
    }
}

#[cfg(test)]
mod tests {
    use super::kind::*;
    use super::*;

    /// Tokens as `text:kind` pairs, easier to read than offsets.
    fn tokens(language: &str, code: &str) -> Vec<String> {
        let units: Vec<u16> = code.encode_utf16().collect();
        code_tokens(language, code)
            .chunks(3)
            .map(|t| {
                let (start, length) = (t[0] as usize, t[1] as usize);
                format!("{}:{}", String::from_utf16_lossy(&units[start..start + length]), t[2])
            })
            .collect()
    }

    fn expect(pairs: &[(&str, i32)]) -> Vec<String> {
        pairs.iter().map(|(text, kind)| format!("{text}:{kind}")).collect()
    }

    #[test]
    fn resolves_aliases() {
        assert_eq!(Some("python".into()), code_language("py"));
        assert_eq!(Some("bash".into()), code_language("ZSH"));
        assert_eq!(Some("csharp".into()), code_language("c#"));
        assert_eq!(Some("typc".into()), code_language("typc"));
        assert_eq!(Some("mermaid".into()), code_language("mmd"));
        assert_eq!(None, code_language("cobol"));
        assert!(code_tokens("markdown", "# hi").is_empty());
        assert_eq!(code_languages()[..3], ["sql", "bash", "javascript"].map(String::from));
    }

    #[test]
    fn splits_raw_blocks() {
        assert_eq!(vec![3, 6, 6, 16], raw_block_parts("```sql\nSELECT 1\n```"));
        assert_eq!(vec![4, 6, 6, 10], raw_block_parts("````js x()````"));
        assert!(raw_block_parts("`x`").is_empty());
        assert!(raw_block_parts("```\ncode\n```").is_empty());
    }

    #[test]
    fn highlights_sql_case_insensitively() {
        assert_eq!(
            expect(&[
                ("SELECT", KEYWORD),
                ("count", FUNCTION),
                ("From", KEYWORD),
                ("Where", KEYWORD),
                ("'it''s'", STRING),
                ("-- done", COMMENT),
                ("VARCHAR", TYPE),
                ("255", NUMBER),
            ]),
            tokens("sql", "SELECT count(*) From t Where a = 'it''s' -- done\nVARCHAR(255)"),
        );
    }

    #[test]
    fn highlights_shell_commands_and_variables() {
        assert_eq!(
            expect(&[
                ("FOO", VARIABLE),
                ("BAR", VARIABLE),
                ("apt-get", FUNCTION),
                ("if", KEYWORD),
                ("test", FUNCTION),
                ("\"a ", STRING),
                ("$HOME", VARIABLE),
                ("\"", STRING),
                ("then", KEYWORD),
                ("echo", FUNCTION),
                ("'$x'", STRING),
                ("${y}", VARIABLE),
                ("# c", COMMENT),
                ("fi", KEYWORD),
            ]),
            tokens("bash", "FOO=1 BAR=x apt-get install x#y\nif test \"a $HOME\"; then echo '$x' ${y} # c\nfi"),
        );
    }

    #[test]
    fn highlights_template_literals() {
        assert_eq!(
            expect(&[
                ("const", KEYWORD),
                ("`a ", STRING),
                ("${", KEYWORD),
                ("f", FUNCTION),
                ("2", NUMBER),
                ("}", KEYWORD),
                (" b`", STRING),
                ("// x", COMMENT),
            ]),
            tokens("javascript", "const s = `a ${f(2)} b` // x"),
        );
        let ts: Vec<String> =
            tokens("typescript", "let a: string = new_ as Foo").into_iter().filter(|t| !t.starts_with("as:")).collect();
        assert_eq!(expect(&[("let", KEYWORD), ("string", TYPE), ("Foo", TYPE)]), ts);
    }

    #[test]
    fn highlights_kotlin_strings() {
        assert_eq!(
            expect(&[
                ("@Test", ANNOTATION),
                ("fun", KEYWORD),
                ("f", FUNCTION),
                ("\"\"\"raw \\n ", STRING),
                ("$x", VARIABLE),
                ("\"\"\"\"", STRING),
                ("/* c */", COMMENT),
                ("List", TYPE),
            ]),
            tokens("kotlin", "@Test fun f() = \"\"\"raw \\n $x\"\"\"\" /* c */ List"),
        );
    }

    #[test]
    fn highlights_python_prefixes_and_triple_quotes() {
        assert_eq!(
            expect(&[
                ("@cache", ANNOTATION),
                ("def", KEYWORD),
                ("f", FUNCTION),
                ("rb'\\x'", STRING),
                ("\"\"\"doc\n\"\"\"", STRING),
                ("# end", COMMENT),
                ("None", KEYWORD),
            ]),
            tokens("python", "@cache\ndef f(): rb'\\x' \"\"\"doc\n\"\"\" # end\nNone"),
        );
    }

    #[test]
    fn highlights_java_and_csharp() {
        assert_eq!(
            expect(&[("public", KEYWORD), ("int", TYPE), ("'c'", STRING), ("0x1F", NUMBER), ("1.5e-3", NUMBER)]),
            tokens("java", "public int x = 'c' + 0x1F + 1.5e-3;"),
        );
        assert_eq!(
            expect(&[("var", KEYWORD), ("@\"C:\\\"", STRING), ("$\"{x}\"", STRING), ("\"\"\"a\"b\"\"\"", STRING)]),
            tokens("csharp", "var p = @\"C:\\\" + $\"{x}\" + \"\"\"a\"b\"\"\";"),
        );
    }

    #[test]
    fn highlights_mermaid() {
        assert_eq!(
            expect(&[
                ("flowchart", KEYWORD),
                ("LR", KEYWORD),
                ("-->", OPERATOR),
                ("\"go\"", STRING),
                ("%% note", COMMENT),
                ("stateDiagram-v2", KEYWORD),
            ]),
            tokens("mermaid", "flowchart LR\nA-->B[\"go\"] %% note\nstateDiagram-v2"),
        );
    }

    #[test]
    fn stops_unterminated_constructs_at_the_end() {
        assert!(!tokens("javascript", "`a ${b").is_empty());
        assert_eq!(expect(&[("/* x", COMMENT)]), tokens("java", "/* x"));
        assert_eq!(expect(&[("\"a", STRING), ("b", FUNCTION)]), tokens("python", "\"a\nb()"));
    }

    #[test]
    fn counts_utf16_offsets() {
        assert_eq!(vec![3, 3, 1], code_tokens("python", "😀 'é'"));
    }
}
