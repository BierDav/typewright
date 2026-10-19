//! Extract variable and inline variable on typst's syntax tree.

use std::ops::Range;

use serde::Serialize;
use typst::syntax::ast;
use typst::syntax::{LinkedNode, Side, SyntaxKind, SyntaxNode};

#[derive(Serialize)]
pub struct Edit {
    start: usize,
    length: usize,
    text: String,
}

#[derive(Serialize, Default)]
pub struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    /// Expressions at the caret to pick from, inner to outer.
    candidates: Vec<Edit>,
    edits: Vec<Edit>,
    /// The new variable's name after the edits: its declaration first, then its uses.
    names: Vec<[usize; 2]>,
    /// Occurrences of the extracted expression, or uses of the inlined variable.
    count: usize,
    /// For `symbol`: "variable" or "function".
    #[serde(skip_serializing_if = "Option::is_none")]
    kind: Option<&'static str>,
}

fn error(message: &str) -> Response {
    Response { error: Some(message.into()), ..Response::default() }
}

/// UTF-16 offsets as NSString counts them.
struct Offsets<'a>(&'a str);

impl Offsets<'_> {
    fn byte(&self, utf16: usize) -> usize {
        let mut units = 0;
        for (i, c) in self.0.char_indices() {
            if units >= utf16 {
                return i;
            }
            units += c.len_utf16();
        }
        self.0.len()
    }

    fn utf16(&self, byte: usize) -> usize {
        self.0[..byte.min(self.0.len())].encode_utf16().count()
    }

    fn edit(&self, range: Range<usize>, text: String) -> Edit {
        let start = self.utf16(range.start);
        Edit { start, length: self.utf16(range.end) - start, text }
    }
}

/// Code positions where an expression stands on its own; markup only counts after a `#`.
fn in_code(node: &LinkedNode) -> bool {
    match node.parent_kind() {
        Some(SyntaxKind::Markup | SyntaxKind::Math) => node.prev_sibling_kind() == Some(SyntaxKind::Hash),
        Some(SyntaxKind::Named) => node.index() > 0,
        Some(SyntaxKind::Params | SyntaxKind::Destructuring | SyntaxKind::ImportItems) => false,
        Some(SyntaxKind::FieldAccess) => node.prev_sibling().is_none(),
        Some(SyntaxKind::LetBinding) => node.prev_sibling_kind() == Some(SyntaxKind::Eq),
        _ => true,
    }
}

fn is_assignment(node: &LinkedNode) -> bool {
    node.get().cast::<ast::Binary>().is_some_and(|b| {
        matches!(
            b.op(),
            ast::BinOp::Assign
                | ast::BinOp::AddAssign
                | ast::BinOp::SubAssign
                | ast::BinOp::MulAssign
                | ast::BinOp::DivAssign
        )
    })
}

fn extractable(node: &LinkedNode) -> bool {
    use SyntaxKind::*;
    matches!(
        node.kind(),
        None | Auto | Bool | Int | Float | Numeric | Str | CodeBlock | ContentBlock | Parenthesized | Array | Dict
            | Unary | Binary | FieldAccess | FuncCall | Closure | Conditional | Contextual | Equation
    ) && in_code(node)
        && !is_assignment(node)
        && !node.parent().is_some_and(|p| is_assignment(p) && node.prev_sibling().is_none())
}

/// Needs no parentheses wherever an expression goes.
fn atomic(kind: SyntaxKind) -> bool {
    use SyntaxKind::*;
    matches!(
        kind,
        Ident | None | Auto | Bool | Int | Float | Numeric | Str | CodeBlock | ContentBlock | Parenthesized | Array
            | Dict | FieldAccess | FuncCall | Equation
    )
}

fn ancestors<'a>(node: &LinkedNode<'a>) -> impl Iterator<Item = LinkedNode<'a>> {
    std::iter::successors(Some(node.clone()), |n| n.parent().cloned())
}

/// The statement holding `node`: the ancestor directly inside markup or a code block.
fn statement<'a>(node: &LinkedNode<'a>) -> Option<LinkedNode<'a>> {
    ancestors(node).find(|n| matches!(n.parent_kind(), Some(SyntaxKind::Markup | SyntaxKind::Code)))
}

/// Where a statement starts, its `#` included.
fn statement_start(stmt: &LinkedNode) -> usize {
    match stmt.prev_sibling() {
        Some(hash) if hash.kind() == SyntaxKind::Hash && hash.range().end == stmt.offset() => hash.offset(),
        _ => stmt.offset(),
    }
}

fn line_start(text: &str, at: usize) -> usize {
    text[..at].rfind('\n').map_or(0, |i| i + 1)
}

fn line_end(text: &str, at: usize) -> usize {
    text[at..].find('\n').map_or(text.len(), |i| at + i)
}

fn descendants<'a>(node: &LinkedNode<'a>, out: &mut Vec<LinkedNode<'a>>) {
    for child in node.children() {
        out.push(child.clone());
        descendants(&child, out);
    }
}

/// Names read or bound anywhere; argument names and fields don't count.
fn identifiers(root: &SyntaxNode, out: &mut std::collections::HashSet<String>) {
    if matches!(root.kind(), SyntaxKind::Ident | SyntaxKind::MathIdent) {
        out.insert(root.leaf_text().to_string());
    }
    let skip_first = root.kind() == SyntaxKind::Named;
    let keep_first_only = root.kind() == SyntaxKind::FieldAccess;
    for (i, child) in root.children().filter(|c| !c.kind().is_trivia()).enumerate() {
        if (skip_first && i == 0) || (keep_first_only && i > 0) {
            continue;
        }
        identifiers(child, out);
    }
}

fn named_key(node: &LinkedNode) -> Option<String> {
    if node.parent_kind() != Some(SyntaxKind::Named) {
        return None;
    }
    node.parent()?.children().next().map(|key| key.get().leaf_text().to_string())
}

fn find_node<'a>(root: &LinkedNode<'a>, range: Range<usize>) -> Option<LinkedNode<'a>> {
    let leaf = root.leaf_at(range.start, Side::After)?;
    ancestors(&leaf).find(|n| n.range() == range && extractable(n))
}

pub fn candidates(text: &str, start: usize, length: usize) -> Response {
    let o = Offsets(text);
    let root = typst::syntax::parse(text);
    let root = LinkedNode::new(&root);
    let (from, to) = (o.byte(start), o.byte(start + length));
    if from < to {
        // A selection counts as the expression it spans, give or take surrounding spaces.
        let trimmed = text[from..to].trim();
        let begin = from + (text[from..to].len() - text[from..to].trim_start().len());
        return match find_node(&root, begin..begin + trimmed.len()) {
            Some(node) => Response { candidates: vec![o.edit(node.range(), trimmed.into())], ..Response::default() },
            None => error("The selection isn't an expression."),
        };
    }
    let mut found: Vec<LinkedNode> = Vec::new();
    for side in [Side::Before, Side::After] {
        let Some(leaf) = root.leaf_at(from, side) else { continue };
        for n in ancestors(&leaf) {
            if matches!(n.kind(), SyntaxKind::Markup | SyntaxKind::Code) {
                break;
            }
            if extractable(&n) && !found.iter().any(|f| f.range() == n.range()) {
                found.push(n);
            }
        }
    }
    found.sort_by_key(|n| n.range().len());
    let candidates: Vec<_> = found.iter().map(|n| o.edit(n.range(), text[n.range()].into())).collect();
    if candidates.is_empty() {
        return error("No expression at the caret.");
    }
    Response { candidates, ..Response::default() }
}

/// A name the document doesn't use yet, preferring the argument's name or the called function's.
fn suggest_name(node: &LinkedNode, root: &SyntaxNode, taken_globally: impl Fn(&str) -> bool) -> String {
    let mut used = std::collections::HashSet::new();
    identifiers(root, &mut used);
    let mut wanted = Vec::new();
    if let Some(key) = named_key(node) {
        // `top` in `margin: (top: …)` would hide the alignment, `margin-top` doesn't.
        let outer = node.parent().and_then(|named| ancestors(named).skip(1).find_map(|n| named_key(&n)));
        wanted.push(key.clone());
        wanted.extend(outer.map(|o| format!("{o}-{key}")));
    }
    if let Some(call) = node.get().cast::<ast::FuncCall>() {
        let name = match call.callee() {
            ast::Expr::Ident(id) => Some(id.get().to_string()),
            ast::Expr::FieldAccess(access) => Some(access.field().get().to_string()),
            _ => None,
        };
        wanted.extend(name.map(|n| format!("{n}-value")));
    }
    let free = |n: &str| !used.contains(n) && !taken_globally(n);
    if let Some(name) = wanted.iter().find(|n| free(n)) {
        return name.clone();
    }
    (1..).map(|i| if i == 1 { "value".to_string() } else { format!("value{i}") }).find(|n| free(n)).unwrap()
}

pub fn extract(text: &str, start: usize, length: usize, all: bool, taken: impl Fn(&str) -> bool) -> Response {
    let o = Offsets(text);
    let parsed = typst::syntax::parse(text);
    let root = LinkedNode::new(&parsed);
    let Some(target) = find_node(&root, o.byte(start)..o.byte(start + length)) else {
        return error("No expression to extract.");
    };
    // An expression-bodied closure has no place for a `let` and its parameters can't leave it.
    for n in ancestors(&target).skip(1) {
        if matches!(n.parent_kind(), Some(SyntaxKind::Markup | SyntaxKind::Code)) {
            break;
        }
        if n.kind() == SyntaxKind::Closure {
            return error("Can't extract from a closure without braces.");
        }
    }
    let Some(stmt) = statement(&target) else { return error("No statement to put the variable before.") };
    let container = stmt.parent().cloned().unwrap();
    let source = &text[target.range()];

    let mut nodes = Vec::new();
    descendants(&container, &mut nodes);
    let mut occurrences: Vec<LinkedNode> = Vec::new();
    for n in nodes {
        if n.kind() == target.kind()
            && &text[n.range()] == source
            && extractable(&n)
            && !occurrences.iter().any(|p| p.range().end > n.offset())
        {
            occurrences.push(n);
        }
    }
    let count = occurrences.len();
    if !all {
        occurrences.retain(|n| n.range() == target.range());
    }
    let first = occurrences.first().cloned().unwrap_or(target.clone());
    let anchor = statement(&first).unwrap_or(stmt);
    let anchor_start = statement_start(&anchor);

    let name = suggest_name(&target, &parsed, taken);
    let markup = container.kind() == SyntaxKind::Markup;
    let decl = format!("{}let {name} = {source}", if markup { "#" } else { "" });
    let ls = line_start(text, anchor_start);
    let prefix = &text[ls..anchor_start];
    // On a line of its own unless that line holds other code the variable must come after.
    let own_line = ls >= container.offset() && (prefix.trim().is_empty() || (markup && !prefix.contains('#')));
    let name_at = decl.find("let ").unwrap() + 4;
    let (at, insert, name_offset) = if own_line {
        let indent: String = text[ls..].chars().take_while(|c| *c == ' ' || *c == '\t').collect();
        (ls, format!("{indent}{decl}\n"), indent.len() + name_at)
    } else {
        (anchor_start, format!("{decl}; "), name_at)
    };

    let mut edits = vec![o.edit(at..at, insert.clone())];
    let mut names = vec![[o.utf16(at) + insert[..name_offset].encode_utf16().count(), name.encode_utf16().count()]];
    // Later positions shift by what came before them.
    let mut shift = insert.encode_utf16().count() as isize;
    for n in &occurrences {
        let r = n.range();
        let e = o.edit(r.clone(), name.clone());
        names.push([(e.start as isize + shift) as usize, name.encode_utf16().count()]);
        shift += name.encode_utf16().count() as isize - e.length as isize;
        edits.push(e);
    }
    Response { edits, names, count, ..Response::default() }
}

fn is_binding_pattern(node: &LinkedNode) -> bool {
    node.parent_kind() == Some(SyntaxKind::LetBinding) && node.prev_sibling_kind() == Some(SyntaxKind::Let)
}

/// Identifiers that read the variable, not keys, fields or new bindings of the same name.
fn is_use(node: &LinkedNode, name: &str) -> bool {
    matches!(node.kind(), SyntaxKind::Ident | SyntaxKind::MathIdent)
        && node.get().leaf_text() == name
        && !is_binding_pattern(node)
        && match node.parent_kind() {
            Some(SyntaxKind::Named) => node.index() > 0,
            Some(SyntaxKind::FieldAccess) => node.prev_sibling().is_none(),
            Some(SyntaxKind::Params | SyntaxKind::Destructuring | SyntaxKind::ImportItems) => false,
            _ => true,
        }
}

pub fn inline(text: &str, offset: usize) -> Response {
    let o = Offsets(text);
    let parsed = typst::syntax::parse(text);
    let root = LinkedNode::new(&parsed);
    let at = o.byte(offset);
    let ident = [Side::After, Side::Before]
        .into_iter()
        .filter_map(|side| root.leaf_at(at, side))
        .find(|n| matches!(n.kind(), SyntaxKind::Ident | SyntaxKind::MathIdent));
    let Some(ident) = ident else { return error("No variable at the caret.") };
    let name = ident.get().leaf_text().to_string();

    // The binding itself, or the closest one before the use whose scope holds it.
    let binding = if is_binding_pattern(&ident) {
        ident.parent().cloned()
    } else {
        let mut nodes = Vec::new();
        descendants(&root, &mut nodes);
        nodes
            .into_iter()
            .filter(|n| {
                n.kind() == SyntaxKind::LetBinding
                    && n.range().end <= ident.offset()
                    && n.children().find(|c| !c.kind().is_trivia() && c.prev_sibling_kind() == Some(SyntaxKind::Let)).is_some_and(|c| {
                        c.kind() == SyntaxKind::Ident && c.get().leaf_text() == name.as_str()
                    })
                    && n.parent().is_some_and(|p| p.range().contains(&ident.offset()))
            })
            .max_by_key(|n| n.offset())
    };
    let Some(binding) = binding else { return error("No local variable to inline here.") };
    let parts: Vec<_> = binding.children().filter(|c| !c.kind().is_trivia()).collect();
    if parts.iter().any(|c| c.kind() == SyntaxKind::Closure) {
        return error("Functions can't be inlined.");
    }
    let Some(init) = parts.iter().find(|c| c.prev_sibling_kind() == Some(SyntaxKind::Eq)) else {
        return error("The variable has no value to inline.");
    };
    let Some(container) = binding.parent().cloned() else { return error("No local variable to inline here.") };
    let value = &text[init.range()];

    // Uses run until a later statement binds the name again; that one's own value still reads the old one.
    let mut nodes = Vec::new();
    descendants(&container, &mut nodes);
    let end = container
        .children()
        .filter(|s| s.offset() > binding.offset() && s.kind() == SyntaxKind::LetBinding)
        .find(|s| s.children().any(|c| is_binding_pattern(&c) && c.get().leaf_text() == name.as_str()))
        .map_or(container.range().end, |s| s.range().end);
    let uses: Vec<_> = nodes
        .into_iter()
        .filter(|n| n.offset() >= binding.range().end && n.offset() < end && is_use(n, &name))
        .collect();
    for u in &uses {
        if u.parent().is_some_and(|p| is_assignment(p) && u.prev_sibling().is_none()) {
            return error("The variable is assigned to later, so it can't be inlined.");
        }
    }

    let mut edits = Vec::new();
    let atom = atomic(init.kind());
    for u in &uses {
        let math = u.kind() == SyntaxKind::MathIdent;
        let embedded = math || u.parent_kind() == Some(SyntaxKind::Markup);
        let safe = matches!(
            u.parent_kind(),
            Some(
                SyntaxKind::Args
                    | SyntaxKind::Named
                    | SyntaxKind::Array
                    | SyntaxKind::Dict
                    | SyntaxKind::Keyed
                    | SyntaxKind::LetBinding
                    | SyntaxKind::Code
                    | SyntaxKind::Parenthesized
            )
        );
        let body = if atom || (safe && !embedded) { value.to_string() } else { format!("({value})") };
        edits.push(o.edit(u.range(), if math { format!("#{body}") } else { body }));
    }

    // The declaration goes with its line when nothing else is on it.
    let start = statement_start(&binding);
    let mut stop = binding.range().end;
    if text[stop..].starts_with(';') {
        stop += 1;
    }
    let (ls, le) = (line_start(text, start), line_end(text, stop));
    let removal = if text[ls..start].trim().is_empty() && text[stop..le].trim().is_empty() {
        ls..(le + 1).min(text.len())
    } else {
        start..stop + (text[stop..le].len() - text[stop..le].trim_start().len())
    };
    edits.push(o.edit(removal, String::new()));
    edits.sort_by_key(|e| e.start);
    Response { edits, count: uses.len(), ..Response::default() }
}

// MARK: - Extract function

/// Names a `let` binds: `x`, the parts of `(a, b)`, or the function in `let f(x) = …`.
fn let_names<'a>(binding: &LinkedNode<'a>) -> Vec<LinkedNode<'a>> {
    let Some(target) = binding.children().find(|c| !c.kind().is_trivia() && c.prev_sibling_kind() == Some(SyntaxKind::Let))
    else {
        return Vec::new();
    };
    match target.kind() {
        SyntaxKind::Ident => vec![target],
        SyntaxKind::Closure => target.children().filter(|c| c.kind() == SyntaxKind::Ident).take(1).collect(),
        _ => pattern_names(&target),
    }
}

/// Identifiers a pattern binds; dictionary keys in `(key: name)` don't count.
fn pattern_names<'a>(pattern: &LinkedNode<'a>) -> Vec<LinkedNode<'a>> {
    if pattern.kind() == SyntaxKind::Ident {
        return vec![pattern.clone()];
    }
    let mut all = Vec::new();
    descendants(pattern, &mut all);
    all.into_iter()
        .filter(|n| n.kind() == SyntaxKind::Ident && !(n.parent_kind() == Some(SyntaxKind::Named) && n.index() == 0))
        .collect()
}

fn import_names<'a>(import: &LinkedNode<'a>) -> Vec<LinkedNode<'a>> {
    let mut all = Vec::new();
    descendants(import, &mut all);
    all.into_iter()
        .filter(|n| {
            n.kind() == SyntaxKind::Ident
                && match n.parent_kind() {
                    Some(SyntaxKind::ImportItemPath) => n.next_sibling().is_none(),
                    Some(SyntaxKind::RenamedImportItem) => n.next_sibling().is_none(),
                    Some(SyntaxKind::ModuleImport) => n.prev_sibling_kind() == Some(SyntaxKind::As),
                    _ => false,
                }
        })
        .collect()
}

fn statement_binds(stmt: &LinkedNode, name: &str) -> Option<usize> {
    let names = match stmt.kind() {
        SyntaxKind::LetBinding => let_names(stmt),
        SyntaxKind::ModuleImport => import_names(stmt),
        _ => return None,
    };
    names.iter().find(|n| n.get().leaf_text() == name).map(|n| n.offset())
}

/// Where `name` is bound for a use: the scope node and the binding's offset; None for globals.
fn resolve<'a>(usage: &LinkedNode<'a>, name: &str) -> Option<(LinkedNode<'a>, usize)> {
    let mut child = usage.clone();
    for a in ancestors(usage).skip(1) {
        match a.kind() {
            SyntaxKind::Closure if child.kind() != SyntaxKind::Params => {
                let mut bound: Vec<LinkedNode> = a.children().filter(|c| c.kind() == SyntaxKind::Ident).collect();
                if let Some(params) = a.children().find(|c| c.kind() == SyntaxKind::Params) {
                    for p in params.children() {
                        match p.kind() {
                            SyntaxKind::Named => bound.extend(p.children().find(|c| c.kind() == SyntaxKind::Ident)),
                            _ => bound.extend(pattern_names(&p)),
                        }
                    }
                }
                if let Some(b) = bound.iter().find(|b| b.get().leaf_text() == name) {
                    return Some((a.clone(), b.offset()));
                }
            }
            SyntaxKind::ForLoop => {
                let pattern = a.children().find(|c| !c.kind().is_trivia() && c.prev_sibling_kind() == Some(SyntaxKind::For));
                let in_pattern = pattern.as_ref().is_some_and(|p| p.range().contains(&usage.offset()));
                if !in_pattern && let Some(b) = pattern.iter().flat_map(pattern_names).find(|b| b.get().leaf_text() == name) {
                    return Some((a.clone(), b.offset()));
                }
            }
            SyntaxKind::Markup | SyntaxKind::Code => {
                let found = a
                    .children()
                    .filter(|s| s.range().end <= child.offset())
                    .filter_map(|s| statement_binds(&s, name))
                    .last();
                if let Some(at) = found {
                    return Some((a.clone(), at));
                }
            }
            _ => {}
        }
        child = a;
    }
    None
}

/// What the selection extracts: one expression, or a run of statements or markup in `container`.
struct Selection<'a> {
    container: LinkedNode<'a>,
    range: Range<usize>,
    expr: Option<LinkedNode<'a>>,
}

fn select<'a>(root: &LinkedNode<'a>, text: &str, from: usize, to: usize) -> Result<Selection<'a>, &'static str> {
    let piece = &text[from..to];
    let from = from + (piece.len() - piece.trim_start().len());
    let to = from + piece.trim().len();
    if from >= to {
        return Err("Select an expression, statements or markup.");
    }
    if let Some(expr) = find_node(root, from..to) {
        let container = statement(&expr).and_then(|s| s.parent().cloned()).ok_or("No scope around the selection.")?;
        return Ok(Selection { container, range: from..to, expr: Some(expr) });
    }
    let leaf = root.leaf_at(from, Side::After).ok_or("Nothing selected.")?;
    let node = ancestors(&leaf)
        .find(|n| n.range().start <= from && n.range().end >= to && matches!(n.kind(), SyntaxKind::Markup | SyntaxKind::Code))
        .ok_or("Select an expression, statements or markup.")?;
    let mut from = from;
    for child in node.children() {
        let r = child.range();
        // An embedded expression goes with its `#`.
        if child.kind() == SyntaxKind::Hash && r.end == from {
            from = r.start;
            continue;
        }
        let partial = (r.start < from && r.end > from) || (r.start < to && r.end > to);
        let splittable = matches!(child.kind(), SyntaxKind::Text | SyntaxKind::Space) && node.kind() == SyntaxKind::Markup;
        if partial && !splittable {
            return Err("The selection cuts through an expression.");
        }
    }
    Ok(Selection { container: node, range: from..to, expr: None })
}

/// Markup and code blocks around the selection that the function can go into, inner to outer.
fn scopes<'a>(sel: &Selection<'a>) -> Vec<LinkedNode<'a>> {
    ancestors(&sel.container).filter(|n| matches!(n.kind(), SyntaxKind::Markup | SyntaxKind::Code)).collect()
}

fn scope_label(scope: &LinkedNode, text: &str) -> String {
    let line = text[..scope.offset()].matches('\n').count() + 1;
    let Some(block) = scope.parent() else { return "Top level".into() };
    let owner = block.parent();
    let name_of = |n: &LinkedNode| n.children().find(|c| c.kind() == SyntaxKind::Ident).map(|c| c.get().leaf_text().to_string());
    let what = match owner.map(|o| o.kind()) {
        Some(SyntaxKind::Closure) => match owner.and_then(name_of) {
            Some(name) => format!("Function {name}"),
            None => "Anonymous function".into(),
        },
        Some(SyntaxKind::ForLoop) => "For loop".into(),
        Some(SyntaxKind::WhileLoop) => "While loop".into(),
        Some(SyntaxKind::Conditional) => "If".into(),
        Some(SyntaxKind::Contextual) => "Context".into(),
        Some(SyntaxKind::Args) => match owner.and_then(|a| a.parent().cloned()).and_then(|call| call.children().next()) {
            Some(callee) => format!("{}[…]", text[callee.range()].trim()),
            None => "Block".into(),
        },
        Some(SyntaxKind::LetBinding) => match owner.map(let_names).and_then(|n| n.first().cloned()) {
            Some(name) => format!("let {}", name.get().leaf_text()),
            None => "Block".into(),
        },
        _ if block.kind() == SyntaxKind::CodeBlock => "Code block".into(),
        _ => "Content block".into(),
    };
    format!("{what} (line {line})")
}

pub fn function_scopes(text: &str, start: usize, length: usize) -> Response {
    let o = Offsets(text);
    let parsed = typst::syntax::parse(text);
    let root = LinkedNode::new(&parsed);
    match select(&root, text, o.byte(start), o.byte(start + length)) {
        Ok(sel) => Response {
            candidates: scopes(&sel).iter().map(|s| o.edit(s.range(), scope_label(s, text))).collect(),
            ..Response::default()
        },
        Err(e) => error(e),
    }
}

pub fn extract_function(text: &str, start: usize, length: usize, scope: Option<usize>, taken: impl Fn(&str) -> bool) -> Response {
    let o = Offsets(text);
    let parsed = typst::syntax::parse(text);
    let root = LinkedNode::new(&parsed);
    let sel = match select(&root, text, o.byte(start), o.byte(start + length)) {
        Ok(sel) => sel,
        Err(e) => return error(e),
    };
    let all = scopes(&sel);
    let target = match scope.map(|s| o.byte(s)) {
        Some(at) => match all.iter().find(|s| s.offset() == at) {
            Some(s) => s.clone(),
            None => return error("That scope is gone."),
        },
        None => all[0].clone(),
    };
    let range = sel.range.clone();
    let inside = |at: usize| range.start <= at && at < range.end;

    let mut nodes = Vec::new();
    descendants(&sel.container, &mut nodes);
    let selected: Vec<_> = nodes.into_iter().filter(|n| inside(n.offset()) && n.range().end <= range.end).collect();
    let mut params: Vec<String> = Vec::new();
    for n in &selected {
        match n.kind() {
            SyntaxKind::FuncReturn
                if !ancestors(n).any(|a| a.kind() == SyntaxKind::Closure && inside(a.offset())) =>
            {
                return error("The selection returns from the function around it.");
            }
            SyntaxKind::LoopBreak | SyntaxKind::LoopContinue
                if !ancestors(n).any(|a| matches!(a.kind(), SyntaxKind::ForLoop | SyntaxKind::WhileLoop) && inside(a.offset())) =>
            {
                return error("The selection breaks out of a loop around it.");
            }
            _ => {}
        }
        if is_assignment(n)
            && let Some(lhs) = n.children().next()
        {
            // `x.y = 1` changes `x`.
            let base = std::iter::successors(Some(lhs), |x| if x.kind() == SyntaxKind::FieldAccess { x.children().next() } else { None })
                .last()
                .unwrap();
            if base.kind() == SyntaxKind::Ident
                && let Some((_, at)) = resolve(&base, base.get().leaf_text())
                && !inside(at)
            {
                return error("The selection changes a variable from outside, which a function can't.");
            }
        }
        let name = n.get().leaf_text().to_string();
        if !is_use(n, &name) || params.contains(&name) {
            continue;
        }
        if let Some((scope_node, at)) = resolve(n, &name)
            && !inside(at)
            && scope_node.range() != target.range()
            && target.range().start <= scope_node.offset()
            && scope_node.range().end <= target.range().end
        {
            params.push(name);
        }
    }

    // Statements that bind names used after them must stay put.
    if sel.expr.is_none() {
        let bound: Vec<String> = sel
            .container
            .children()
            .filter(|c| inside(c.offset()))
            .flat_map(|c| match c.kind() {
                SyntaxKind::LetBinding => let_names(&c),
                _ => Vec::new(),
            })
            .map(|n| n.get().leaf_text().to_string())
            .collect();
        let mut after = Vec::new();
        descendants(&sel.container, &mut after);
        if let Some(n) = after.iter().find(|n| n.offset() >= range.end && bound.iter().any(|b| is_use(n, b))) {
            return Response { error: Some(format!("“{}” is defined in the selection and used after it.", n.get().leaf_text())), ..Response::default() };
        }
    }

    let mut used = std::collections::HashSet::new();
    identifiers(&parsed, &mut used);
    let name = (1..)
        .map(|i| if i == 1 { "extracted".to_string() } else { format!("extracted{i}") })
        .find(|n| !used.contains(n.as_str()) && !taken(n))
        .unwrap();

    let source = &text[range.clone()];
    let markup_scope = target.kind() == SyntaxKind::Markup;
    let anchor = target.children().find(|c| c.range().end > range.start).unwrap_or(target.clone());
    let anchor_start = if anchor.kind() == SyntaxKind::Markup || anchor.kind() == SyntaxKind::Code {
        range.start
    } else {
        statement_start(&anchor).min(range.start)
    };
    let ls = line_start(text, anchor_start);
    let prefix = &text[ls..anchor_start];
    let own_line = ls >= target.offset() && (prefix.trim().is_empty() || (markup_scope && !prefix.contains('#')));
    let indent: String = if own_line { text[ls..].chars().take_while(|c| *c == ' ' || *c == '\t').collect() } else { String::new() };

    let body = match (&sel.expr, sel.container.kind()) {
        (Some(_), _) => source.to_string(),
        (None, SyntaxKind::Markup) => format!("[{source}]"),
        (None, _) => {
            let column = range.start - line_start(text, range.start);
            let lines: Vec<String> = source
                .lines()
                .enumerate()
                .map(|(i, l)| {
                    let l = if i == 0 { l } else { l.get(column.min(l.len() - l.trim_start().len())..).unwrap_or(l) };
                    format!("{indent}  {l}")
                })
                .collect();
            format!("{{\n{}\n{indent}}}", lines.join("\n"))
        }
    };
    let decl = format!("{}let {name}({}) = {body}", if markup_scope { "#" } else { "" }, params.join(", "));
    let name_at = decl.find("let ").unwrap() + 4;
    let (at, insert, name_offset) = if own_line {
        (ls, format!("{indent}{decl}\n"), indent.len() + name_at)
    } else {
        (anchor_start, format!("{decl}; "), name_at)
    };

    let markup_call = sel.expr.is_none() && sel.container.kind() == SyntaxKind::Markup;
    let next = &text[range.end..];
    let guard = markup_call
        && (next.starts_with(['(', '['])
            || (next.starts_with('.') && next[1..].starts_with(|c: char| c.is_alphabetic())));
    let call = format!("{}{name}({}){}", if markup_call { "#" } else { "" }, params.join(", "), if guard { ";" } else { "" });
    let call_name_offset = if markup_call { 1 } else { 0 };

    let insert_len = insert.encode_utf16().count();
    let call_edit = o.edit(range, call);
    let names = vec![
        [o.utf16(at) + insert[..name_offset].encode_utf16().count(), name.encode_utf16().count()],
        [call_edit.start + insert_len + call_name_offset, name.encode_utf16().count()],
    ];
    Response { edits: vec![o.edit(at..at, insert), call_edit], names, count: params.len(), ..Response::default() }
}

/// The variable or function named at the caret, for naming the rename command.
pub fn symbol(text: &str, offset: usize) -> Response {
    let o = Offsets(text);
    let parsed = typst::syntax::parse(text);
    let root = LinkedNode::new(&parsed);
    let at = o.byte(offset);
    let Some(ident) = [Side::After, Side::Before]
        .into_iter()
        .filter_map(|side| root.leaf_at(at, side))
        .find(|n| matches!(n.kind(), SyntaxKind::Ident | SyntaxKind::MathIdent))
    else {
        return Response::default();
    };
    let name = ident.get().leaf_text().to_string();
    let declares_function = |n: &LinkedNode| {
        n.parent_kind() == Some(SyntaxKind::Closure) && n.parent().is_some_and(|c| c.parent_kind() == Some(SyntaxKind::LetBinding))
    };
    let called = ident.next_leaf().is_some_and(|l| l.kind() == SyntaxKind::LeftParen && l.offset() == ident.range().end);
    let binding_is_function = resolve(&ident, &name).is_some_and(|(_, at)| {
        root.leaf_at(at, Side::After).is_some_and(|b| declares_function(&b))
    });
    let function = declares_function(&ident) || called || binding_is_function;
    let kind = if is_import_item(&ident) { "import" } else if function { "function" } else { "variable" };
    Response { candidates: vec![o.edit(ident.range(), name)], kind: Some(kind), ..Response::default() }
}

/// `shadow` in `#import "…": shadow` or `x` in `… as x`.
fn is_import_item(ident: &LinkedNode) -> bool {
    match ident.parent_kind() {
        Some(SyntaxKind::ImportItemPath | SyntaxKind::RenamedImportItem) => ident.next_sibling().is_none(),
        Some(SyntaxKind::ModuleImport) => ident.prev_sibling_kind() == Some(SyntaxKind::As),
        _ => false,
    }
}

/// Uses of the name bound at the caret (an import item, `let` or parameter) in this file.
pub fn usages(text: &str, offset: usize) -> Response {
    let o = Offsets(text);
    let parsed = typst::syntax::parse(text);
    let root = LinkedNode::new(&parsed);
    let at = o.byte(offset);
    let Some(ident) = [Side::After, Side::Before]
        .into_iter()
        .filter_map(|side| root.leaf_at(at, side))
        .find(|n| n.kind() == SyntaxKind::Ident)
    else {
        return error("No name at the caret.");
    };
    let name = ident.get().leaf_text().to_string();
    let mut all = Vec::new();
    descendants(&root, &mut all);
    let candidates = all
        .iter()
        .filter(|n| is_use(n, &name) && n.offset() != ident.offset())
        .filter(|n| resolve(n, &name).is_some_and(|(_, site)| site == ident.offset()))
        .map(|n| o.edit(n.range(), name.clone()))
        .collect();
    Response { candidates, ..Response::default() }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply(text: &str, r: &Response) -> String {
        let mut units: Vec<u16> = text.encode_utf16().collect();
        for e in r.edits.iter().rev() {
            units.splice(e.start..e.start + e.length, e.text.encode_utf16());
        }
        String::from_utf16(&units).unwrap()
    }

    fn range(text: &str, needle: &str) -> (usize, usize) {
        let o = Offsets(text);
        let b = text.find(needle).unwrap();
        (o.utf16(b), needle.encode_utf16().count())
    }

    #[test]
    fn extracts_with_occurrences() {
        let text = "= Title\n#set page(margin: (top: 15mm, bottom: 15mm))\n";
        let (s, l) = range(text, "15mm");
        let r = extract(text, s, l, true, |_| false);
        assert_eq!(r.count, 2);
        let out = apply(text, &r);
        assert_eq!(out, "= Title\n#let top = 15mm\n#set page(margin: (top: top, bottom: top))\n");
        let global = extract(text, s, l, true, |n| n == "top");
        assert!(apply(text, &global).starts_with("= Title\n#let margin-top = 15mm\n"));
        for [s, l] in &r.names {
            assert_eq!(&out.encode_utf16().collect::<Vec<_>>()[*s..s + l], "top".encode_utf16().collect::<Vec<_>>());
        }
        let one = extract(text, s, l, false, |_| false);
        assert_eq!(apply(text, &one), "= Title\n#let top = 15mm\n#set page(margin: (top: top, bottom: 15mm))\n");
    }

    #[test]
    fn extracts_in_code_blocks() {
        let text = "#{\n  let a = 1\n  foo(a + 1)\n}";
        let (s, l) = range(text, "a + 1");
        let r = extract(text, s, l, true, |n| n == "foo");
        assert_eq!(apply(text, &r), "#{\n  let a = 1\n  let value = a + 1\n  foo(value)\n}");
        let inline_text = "#{ let a = 1; foo(a + 1) }";
        let (s, l) = range(inline_text, "a + 1");
        let r = extract(inline_text, s, l, true, |_| false);
        assert_eq!(apply(inline_text, &r), "#{ let a = 1; let value = a + 1; foo(value) }");
        let call = "#box(fill: rgb(\"fff\"))";
        let (s, l) = range(call, "rgb(\"fff\")");
        let r = extract(call, s, l, true, |n| n == "rgb");
        assert_eq!(apply(call, &r), "#let fill = rgb(\"fff\")\n#box(fill: fill)");
    }

    #[test]
    fn lists_candidates_inner_to_outer() {
        let text = "#text(size: 1em + 2pt)[x]";
        let (s, _) = range(text, "2pt");
        let r = candidates(text, s + 1, 0);
        let texts: Vec<_> = r.candidates.iter().map(|c| c.text.as_str()).collect();
        assert_eq!(texts, ["2pt", "1em + 2pt", "text(size: 1em + 2pt)[x]"]);
    }

    #[test]
    fn inlines_variables() {
        let text = "#let gap = 1em + 2pt\n#v(gap)\n#box(width: gap * 2)\n$gap$\n";
        let (s, _) = range(text, "gap");
        let r = inline(text, s);
        assert_eq!(r.count, 3);
        assert_eq!(apply(text, &r), "#v(1em + 2pt)\n#box(width: (1em + 2pt) * 2)\n$#(1em + 2pt)$\n");
        let text = "#let c = red\nA #c and #text(fill: c)[x]";
        let (s, _) = range(text, "#c and");
        let r = inline(text, s + 1);
        assert_eq!(apply(text, &r), "A #red and #text(fill: red)[x]");
    }

    #[test]
    fn extracts_functions_with_parameters() {
        let text = "#let f(x) = {\n  let y = x * 2\n  y + 1\n}";
        let (s, l) = range(text, "y + 1");
        let r = extract_function(text, s, l, None, |_| false);
        // Inside, `y` is in reach of the new function.
        assert_eq!(apply(text, &r), "#let f(x) = {\n  let y = x * 2\n  let extracted() = y + 1\n  extracted()\n}");
        // At the top, both locals of `f` become parameters.
        let scopes = function_scopes(text, s, l);
        assert_eq!(scopes.candidates.len(), 2);
        let top = scopes.candidates[1].start;
        let r = extract_function(text, s, l, Some(top), |_| false);
        assert_eq!(apply(text, &r), "#let extracted(y) = y + 1\n#let f(x) = {\n  let y = x * 2\n  extracted(y)\n}");
        let out = apply(text, &r);
        let units: Vec<u16> = out.encode_utf16().collect();
        for [s, l] in &r.names {
            assert_eq!(String::from_utf16(&units[*s..s + l]).unwrap(), "extracted");
        }
    }

    #[test]
    fn extracts_statements_and_markup() {
        let text = "#{\n  let a = 1\n  let b = a + 1\n  b\n}";
        let (s, _) = range(text, "let a");
        let (e, l) = range(text, "a + 1");
        assert!(extract_function(text, s, e + l - s, None, |_| false).error.is_some());
        let text = "#let n = 3\nHello *world* #n times.\n";
        let (s, l) = range(text, "*world* #n");
        let r = extract_function(text, s, l, None, |_| false);
        assert_eq!(apply(text, &r), "#let n = 3\n#let extracted() = [*world* #n]\nHello #extracted() times.\n");
        let text = "#for i in range(3) [Item #i\n]";
        let (s, l) = range(text, "Item #i");
        assert_eq!(apply(text, &extract_function(text, s, l, None, |_| false)),
                   "#for i in range(3) [#let extracted() = [Item #i]; #extracted()\n]");
        let top = function_scopes(text, s, l).candidates.last().unwrap().start;
        let r = extract_function(text, s, l, Some(top), |_| false);
        assert_eq!(apply(text, &r), "#let extracted(i) = [Item #i]\n#for i in range(3) [#extracted(i)\n]");
    }

    #[test]
    fn refuses_outer_mutation_and_names_symbols() {
        let text = "#{ let x = 1; x += 1; x }";
        let (s, l) = range(text, "x += 1");
        assert!(extract_function(text, s, l, None, |_| false).error.is_some());
        let text = "#let f(x) = x\n#let v = 1\n#f(v)";
        let (s, _) = range(text, "f(v)");
        assert_eq!(symbol(text, s).kind, Some("function"));
        let (s, _) = range(text, "v)");
        assert_eq!(symbol(text, s).kind, Some("variable"));
    }

    #[test]
    fn finds_uses_of_import_items() {
        let text = "#import \"@preview/shadowed:0.4.0\": shadow\n#shadow[a] #shadow(blur: 2pt)[b]";
        let (s, _) = range(text, "shadow\n");
        assert_eq!(symbol(text, s + 1).kind, Some("import"));
        assert_eq!(usages(text, s + 1).candidates.len(), 2);
    }

    #[test]
    fn refuses_reassigned_variables() {
        let text = "#{ let x = 1; x += 1; x }";
        let (s, _) = range(text, "x =");
        assert!(inline(text, s).error.is_some());
    }
}
