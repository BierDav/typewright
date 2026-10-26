//! Named arguments to complete in a call's argument list, for the standard library and the functions a document
//! and its local imports define with `let`. tinymist has none for those, nor for an empty list; typst-ide has them
//! only when the last compile reached the call.

use serde::{Deserialize, Serialize};
use typst::foundations::{CastInfo, Func, Repr, Value};
use typst::syntax::{LinkedNode, Side, Source, SyntaxKind, SyntaxNode, ast, ast::AstNode};

use crate::LIBRARY;

#[derive(Serialize, Debug)]
pub(crate) struct Parameters {
    /// UTF-16 range the items replace: the name typed so far.
    from: usize,
    to: usize,
    items: Vec<Item>,
    /// Whether a positional argument fits here too, so other values make sense next to the names.
    values: bool,
    /// Whether more arguments follow, so an accepted name needs a comma after its value.
    comma: bool,
}

#[derive(Serialize, Debug)]
struct Item {
    label: String,
    /// Snippet: `$0` is the caret.
    insert: String,
    detail: String,
    documentation: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Context {
    files: Vec<File>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct File {
    text: String,
}

struct Param {
    name: String,
    /// Types, and the default after `=`.
    detail: String,
    docs: String,
    positional: bool,
    named: bool,
    variadic: bool,
    settable: bool,
}

/// The parameters to offer at the UTF-16 `offset` of `text`; `context` is the editor's solveng context, whose
/// `files` are the local files the document imports. None outside an argument list's names.
pub(crate) fn complete(text: &str, context: &str, offset: u32) -> Option<Parameters> {
    let source = Source::detached(text);
    let cursor = source.lines().utf16_to_byte(offset as usize)?;
    let root = LinkedNode::new(source.root());
    let leaf = root.leaf_at(cursor, Side::Before)?;
    let parent = leaf.parent()?;
    let parent = if parent.kind() == SyntaxKind::Named { parent.parent()? } else { parent };
    let args = parent.get().cast::<ast::Args>()?;
    let call = parent.parent()?;
    let (callee, set) = match call.get().cast::<ast::Expr>()? {
        ast::Expr::FuncCall(call) => (call.callee(), false),
        ast::Expr::SetRule(rule) => (rule.target(), true),
        _ => return None,
    };
    // Only where a name goes: right after the parenthesis or a comma, maybe with part of a name typed.
    let mut deciding = leaf.clone();
    while !matches!(deciding.kind(), SyntaxKind::LeftParen | SyntaxKind::RightParen | SyntaxKind::Comma | SyntaxKind::Colon) {
        deciding = deciding.prev_leaf()?;
    }
    if !matches!(deciding.kind(), SyntaxKind::LeftParen | SyntaxKind::Comma) {
        return None;
    }
    // Only what's before the caret is the name typed; a name right after it is the next argument's.
    let from = if leaf.kind() == SyntaxKind::Ident && leaf.range().end >= cursor { leaf.range().start } else { cursor };
    let to = cursor;
    let rest = text[to..].trim_start();
    let comma = !(rest.is_empty() || rest.starts_with(')') || rest.starts_with(','));

    let mut existing_positional = 0;
    let mut existing = vec![];
    for arg in args.items() {
        match arg {
            ast::Arg::Pos(expr) if expr.span() != leaf.span() => {
                if parent.find(arg.span()).is_some_and(|node| node.range().end <= from) {
                    existing_positional += 1;
                }
            }
            ast::Arg::Named(named) => existing.push(named.name().as_str().to_string()),
            _ => {}
        }
    }

    let context: Context = serde_json::from_str(context).unwrap_or_default();
    let params = parameters(callee, text, cursor, &context)?;
    let mut positional = 0;
    let mut values = false;
    let mut items = vec![];
    for param in params {
        if set && !param.settable {
            continue;
        }
        if param.positional {
            if param.variadic || positional >= existing_positional {
                values = true;
            }
            positional += 1;
        }
        if !param.named || existing.contains(&param.name) {
            continue;
        }
        let value = if param.name == "caption" { "[$0]" } else { "$0" };
        let separator = if !comma { "" } else if rest.starts_with(['\n', '\r']) || text[to..].starts_with(['\n', '\r']) { "," } else { ", " };
        items.push(Item {
            insert: format!("{}: {value}{separator}", param.name),
            label: param.name,
            detail: param.detail,
            documentation: param.docs,
        });
    }
    let utf16 = |byte| source.lines().byte_to_utf16(byte).unwrap_or(offset as usize);
    Some(Parameters { from: utf16(from), to: utf16(to), items, values, comma })
}

/// A function as found: its parameters and docs.
struct Function {
    name: String,
    params: Vec<Param>,
    docs: String,
}

/// The callee's parameters: a `let` in the document (the closest before the call), in an imported file, or the
/// standard library's.
fn parameters(callee: ast::Expr, text: &str, cursor: usize, context: &Context) -> Option<Vec<Param>> {
    function(callee, text, cursor, context).map(|f| f.params)
}

fn function(callee: ast::Expr, text: &str, cursor: usize, context: &Context) -> Option<Function> {
    let path: Vec<String> = match callee {
        ast::Expr::Ident(ident) => vec![ident.as_str().into()],
        ast::Expr::FieldAccess(access) => {
            let mut path = vec![access.field().as_str().to_string()];
            let mut target = access.target();
            loop {
                match target {
                    ast::Expr::FieldAccess(inner) => {
                        path.insert(0, inner.field().as_str().into());
                        target = inner.target();
                    }
                    ast::Expr::Ident(ident) => {
                        path.insert(0, ident.as_str().into());
                        break;
                    }
                    _ => return None,
                }
            }
            path
        }
        _ => return None,
    };
    let name = path.last()?;
    let local = definitions(text, name).into_iter().filter(|(at, _)| *at < cursor).last().map(|(_, f)| f);
    if let Some(function) = local.or_else(|| context.files.iter().find_map(|f| definitions(&f.text, name).pop().map(|(_, f)| f))) {
        return Some(function);
    }
    let mut value = LIBRARY.global.scope().get(&path[0])?.read().clone();
    for field in &path[1..] {
        value = match &value {
            Value::Module(module) => module.scope().get(field)?.read().clone(),
            Value::Func(func) => func.scope()?.get(field)?.read().clone(),
            Value::Type(ty) => ty.scope().get(field)?.read().clone(),
            _ => return None,
        };
    }
    let func: Func = match value {
        Value::Func(func) => func,
        Value::Type(ty) => ty.constructor().ok()?,
        _ => return None,
    };
    let params = func
        .params()
        .filter_map(|param| param.to_native())
        .map(|param| Param {
            name: param.name.into(),
            detail: describe(&param.input),
            docs: param.docs.into(),
            positional: param.positional,
            named: param.named,
            variadic: param.variadic,
            settable: param.settable,
        })
        .collect();
    Some(Function { name: path.join("."), params, docs: func.docs().unwrap_or_default().into() })
}

/// Docs for hovering the UTF-16 `offset`: the function a name there calls or names, or the parameter an argument's
/// name stands for. Markdown, as tinymist's hovers: a signature, the docs and the parameters.
pub(crate) fn hover(text: &str, context: &str, offset: u32) -> Option<String> {
    let source = Source::detached(text);
    let cursor = source.lines().utf16_to_byte(offset as usize)?;
    let root = LinkedNode::new(source.root());
    let leaf = root.leaf_at(cursor, Side::After).filter(|l| l.kind() == SyntaxKind::Ident).or_else(|| root.leaf_at(cursor, Side::Before))?;
    if leaf.kind() != SyntaxKind::Ident {
        return None;
    }
    let context: Context = serde_json::from_str(context).unwrap_or_default();
    let parent = leaf.parent()?;
    // An argument's name: that parameter's docs.
    if parent.kind() == SyntaxKind::Named
        && parent.children().next().is_some_and(|c| c.span() == leaf.span())
        && let Some(call) = parent.parent().and_then(|args| args.parent())
    {
        let callee = match call.get().cast::<ast::Expr>()? {
            ast::Expr::FuncCall(call) => call.callee(),
            ast::Expr::SetRule(rule) => rule.target(),
            _ => return None,
        };
        let function = function(callee, text, cursor, &context)?;
        let param = function.params.into_iter().find(|p| p.name == leaf.get().full_text().as_str())?;
        return Some(format!("```typc\n{}: {}\n```\n\n{}", param.name, param.detail, param.docs).trim_end().to_string());
    }
    // The whole `calc.round` when on either part.
    let node = if parent.kind() == SyntaxKind::FieldAccess { parent.clone() } else { leaf.clone() };
    let function = function(node.get().cast::<ast::Expr>()?, text, cursor, &context)?;
    Some(render(&function))
}

fn render(function: &Function) -> String {
    let params: Vec<String> = function
        .params
        .iter()
        .map(|p| {
            let dots = if p.variadic { ".." } else { "" };
            if p.detail.is_empty() { format!("{dots}{}", p.name) } else if p.detail.starts_with('=') { format!("{dots}{}: {}", p.name, p.detail.trim_start_matches("= ")) } else { format!("{dots}{}: {}", p.name, p.detail) }
        })
        .collect();
    let signature = if params.iter().map(String::len).sum::<usize>() > 60 {
        format!("{}(\n  {},\n)", function.name, params.join(",\n  "))
    } else {
        format!("{}({})", function.name, params.join(", "))
    };
    let mut out = format!("```typc\n{signature}\n```\n\n{}", function.docs.trim());
    let documented: Vec<&Param> = function.params.iter().filter(|p| !p.docs.is_empty()).collect();
    if !documented.is_empty() {
        out.push_str("\n\n## Parameters");
        for p in documented {
            out.push_str(&format!("\n\n### `{}`\n\n{}", p.name, p.docs.trim()));
        }
    }
    out.trim().to_string()
}

fn describe(info: &CastInfo) -> String {
    match info {
        CastInfo::Any => "any".into(),
        CastInfo::Value(value, _) => value.repr().to_string(),
        CastInfo::Type(ty) => ty.short_name().into(),
        CastInfo::Union(list) => {
            let mut parts: Vec<String> = list.iter().map(describe).collect();
            parts.dedup();
            parts.join(" | ")
        }
    }
}

/// Every `let name(…)` and `let name = (…) => …` in `text`, with where it stands.
fn definitions(text: &str, name: &str) -> Vec<(usize, Function)> {
    let root = typst::syntax::parse(text);
    let mut found = vec![];
    let mut offset = 0;
    visit(&root, &mut offset, &mut |node, at| {
        let Some(binding) = node.cast::<ast::LetBinding>() else { return };
        let closure = match binding.kind() {
            ast::LetBindingKind::Closure(ident) if ident.as_str() == name => binding.init(),
            ast::LetBindingKind::Normal(ast::Pattern::Normal(ast::Expr::Ident(ident))) if ident.as_str() == name => binding.init(),
            _ => None,
        };
        if let Some(ast::Expr::Closure(closure)) = closure {
            let (description, items) = docs_above(text, at);
            found.push((at, Function { name: name.into(), params: closure_params(closure, &items), docs: description }));
        }
    });
    found
}

fn visit(node: &SyntaxNode, offset: &mut usize, f: &mut impl FnMut(&SyntaxNode, usize)) {
    f(node, *offset);
    if node.children().len() == 0 {
        *offset += node.len();
    }
    for child in node.children() {
        visit(child, offset, f);
    }
}

fn closure_params(closure: ast::Closure, docs: &[(String, String, String)]) -> Vec<Param> {
    let doc = |name: &str| docs.iter().find(|(n, _, _)| n == name);
    let mut params = vec![];
    let mut sink = false;
    for param in closure.params().children() {
        let (name, detail, positional, named, variadic) = match param {
            ast::Param::Pos(ast::Pattern::Normal(ast::Expr::Ident(ident))) => (ident.as_str().to_string(), String::new(), true, false, false),
            ast::Param::Named(named) => {
                (named.name().as_str().to_string(), format!("= {}", named.expr().to_untyped().full_text()), false, true, false)
            }
            ast::Param::Spread(spread) => {
                sink = true;
                (spread.sink_ident().map(|i| i.as_str().to_string()).unwrap_or_default(), String::new(), true, false, true)
            }
            _ => (String::new(), String::new(), true, false, false),
        };
        let documented = doc(&name);
        params.push(Param {
            detail: documented.map(|(_, types, _)| types.clone()).filter(|t| !t.is_empty()).map_or(detail.clone(), |t| if detail.is_empty() { t } else { format!("{t} {detail}") }),
            docs: documented.map(|(_, _, d)| d.clone()).unwrap_or_default(),
            name,
            positional,
            named,
            variadic,
            settable: true,
        });
    }
    // A sink passes on what its docs list, like a package's override of `grid`.
    if sink {
        for (name, types, text) in docs {
            if !params.iter().any(|p| &p.name == name) {
                params.push(Param { name: name.clone(), detail: types.clone(), docs: text.clone(), positional: false, named: true, variadic: false, settable: true });
            }
        }
    }
    params
}

/// The `///` comment above the line at byte `at`: its prose and its `- name (types): docs` items.
fn docs_above(text: &str, at: usize) -> (String, Vec<(String, String, String)>) {
    let start = text[..at].rfind('\n').map_or(0, |i| i + 1);
    let lines: Vec<&str> = text[..start].lines().rev().map_while(|l| l.trim_start().strip_prefix("///")).collect();
    let mut items: Vec<(String, String, String)> = vec![];
    let mut prose = String::new();
    for line in lines.into_iter().rev() {
        let line = line.strip_prefix(' ').unwrap_or(line);
        if let Some(item) = line.strip_prefix("- ") {
            let (head, docs) = item.split_once(':').unwrap_or((item, ""));
            let (name, types) = head.split_once('(').map_or((head, ""), |(n, t)| (n, t.trim_end().trim_end_matches(')')));
            if name.trim().chars().all(|c| c.is_alphanumeric() || c == '-' || c == '_') && !name.trim().is_empty() {
                items.push((name.trim().into(), types.trim().into(), docs.trim().into()));
                continue;
            }
        }
        // Indented lines continue the item above.
        if let Some(last) = items.last_mut().filter(|_| line.starts_with(' ')) {
            last.2.push(' ');
            last.2.push_str(line.trim());
        } else if items.is_empty() {
            prose.push_str(line);
            prose.push('\n');
        }
    }
    (prose.trim().to_string(), items)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(text: &str) -> (String, u32) {
        let i = text.find('|').unwrap();
        (text.replace('|', ""), text[..i].encode_utf16().count() as u32)
    }

    fn labels(text: &str) -> Option<(Vec<String>, bool, bool)> {
        let (text, offset) = at(text);
        complete(&text, "", offset).map(|p| (p.items.iter().map(|i| i.label.clone()).collect(), p.values, p.comma))
    }

    #[test]
    fn completes_standard_library_parameters() {
        let (names, values, comma) = labels("#grid(|)").unwrap();
        assert!(names.contains(&"fill".into()) && names.contains(&"columns".into()), "{names:?}");
        assert!(values && !comma);
        let (text, offset) = at("#grid(fi|)");
        let result = complete(&text, "", offset).unwrap();
        assert_eq!((result.from, result.to), (6, 8));
        assert!(result.items.iter().any(|i| i.label == "fill" && i.insert == "fill: $0" && i.detail.contains("color")));
        let (names, _, _) = labels("#grid(fill: red, |)").unwrap();
        assert!(!names.contains(&"fill".into()));
        assert!(labels("#grid(fill: |)").is_none());
        assert!(labels("#grid(fill: r|)").is_none());
        assert!(labels("#grid[|]").is_none());
        let (names, _, _) = labels("#calc.round(|)").unwrap();
        assert_eq!(names, vec!["digits"]);
        let (names, values, _) = labels("#set text(|)").unwrap();
        assert!(names.contains(&"size".into()) && !values);
    }

    #[test]
    fn appends_a_comma_before_other_arguments() {
        let (text, offset) = at("#grid(fi|columns: 2)");
        let result = complete(&text, "", offset).unwrap();
        assert!(result.comma);
        assert_eq!((result.from, result.to), (6, 8));
        assert!(result.items.iter().any(|i| i.insert == "fill: $0, "), "{:?}", result.items);
        let (text, offset) = at("#grid(\n  |\n  columns: 2,\n)");
        let result = complete(&text, "", offset).unwrap();
        assert!(result.items.iter().any(|i| i.insert == "fill: $0,"));
    }

    #[test]
    fn completes_parameters_of_let_functions() {
        let doc = "/// Draws.\n/// - size (length): How big.\n/// - fill (color): The fill.\n#let f(a, size: 2pt, ..rest) = a\n#f(1, |)";
        let (text, offset) = at(doc);
        let result = complete(&text, "", offset).unwrap();
        let names: Vec<_> = result.items.iter().map(|i| i.label.as_str()).collect();
        assert_eq!(names, ["size", "fill"]);
        assert_eq!(result.items[0].detail, "length = 2pt");
        assert_eq!(result.items[1].documentation, "The fill.");
        assert!(result.values, "the sink takes more");
        let (names, values, _) = labels("#let g(x, y: 1) = x\n#g(1, |)").unwrap();
        assert_eq!((names, values), (vec!["y".to_string()], false));
        let context = serde_json::json!({"files": [{"path": "lib.typ", "text": "#let h(z: none) = z"}]}).to_string();
        let (text, offset) = at("#import \"lib.typ\": h\n#h(|)");
        let result = complete(&text, &context, offset).unwrap();
        assert_eq!(result.items[0].label, "z");
        // A document's own `grid` wins.
        let (names, _, _) = labels("#let grid(only: 1) = none\n#grid(|)").unwrap();
        assert_eq!(names, vec!["only"]);
    }

    #[test]
    fn documents_functions_and_parameters() {
        let doc = "/// Draws.\n/// - size (length): How big.\n#let f(a, size: 2pt) = a\n#f(1, size: 3pt)\n#calc.round(1)";
        let hover = |needle: &str| hover(doc, "", doc.rfind(needle).unwrap() as u32 + 1);
        let f = hover("f(1").unwrap();
        assert!(f.starts_with("```typc\nf(a, size: length = 2pt)\n```\n\nDraws."), "{f}");
        assert!(f.contains("### `size`\n\nHow big."));
        assert_eq!(hover("size: 3").unwrap(), "```typc\nsize: length = 2pt\n```\n\nHow big.");
        let round = hover("round").unwrap();
        assert!(round.starts_with("```typc\ncalc.round("), "{round}");
        assert!(hover("1)").is_none());
    }
}
