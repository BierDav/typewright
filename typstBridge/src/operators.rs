use typst::{World, WorldExt};
use typst::foundations::{CastInfo, Content, Label, NativeElement, NativeFuncData, NativeFuncPtr, Value};
use typst::introspection::MetadataElem;
use typst::math::OpElem;
use std::sync::LazyLock;
use typst::syntax::{FileId, LinkedNode, RangeMapper, Source, SyntaxKind, SyntaxNode};

pub(crate) static OPERATOR: NativeFuncData = NativeFuncData {
    name: "__op", title: "Source Operator", docs: "", def_site: None, keywords: &[], contextual: false,
    scope: LazyLock::new(&Default::default), params: LazyLock::new(&Vec::new), returns: LazyLock::new(&|| CastInfo::Any),
    function: NativeFuncPtr(&|engine, _, args| {
        let mut text: Content = args.expect("text")?;
        let limits = args.named("limits")?.unwrap_or(false);
        if let Some(id) = args.span.id()
            && let Ok(source) = engine.world.source(id)
            && let Some(range) = engine.world.range(args.span)
        {
            let parsed = typst::syntax::parse(source.text());
            if let Some(name) = binding_name(&LinkedNode::new(&parsed), range.start) {
                text += MetadataElem::new(Value::Str(name.into())).pack()
                    .labelled(Label::new(typst::utils::PicoStr::intern("solveng-operator")).unwrap());
            }
        }
        Ok(Value::Content(OpElem::new(text).with_limits(limits).pack()))
    }),
};

fn binding_name(node: &LinkedNode, at: usize) -> Option<String> {
    if !node.range().contains(&at) { return None; }
    if node.kind() == SyntaxKind::LetBinding {
        return node.children().find(|n| n.kind() == SyntaxKind::Ident).map(|n| n.get().leaf_text().to_string());
    }
    node.children().find_map(|n| binding_name(&n, at))
}

fn operator_callees(node: &LinkedNode, declarations: &[usize], edits: &mut Vec<(usize, usize, String, bool)>) {
    if node.kind() == SyntaxKind::LetBinding
        && node.children().any(|n| n.kind() == SyntaxKind::Ident && declarations.contains(&n.offset()))
        && let Some(call) = node.children().find(|n| n.kind() == SyntaxKind::FuncCall)
        && let Some(callee) = call.children().next()
    {
        edits.push((callee.offset(), callee.range().end, "__op".into(), false));
    }
    for child in node.children() { operator_callees(&child, declarations, edits); }
}

/// Evaluate operator aliases as Typst identifiers while spans still point into the user's source.
pub(crate) fn source(id: FileId, text: &str) -> Option<Source> {
    let edits = solveng_ide::operator_edits(text);
    if edits.is_empty() { return None; }
    let byte = |offset: u32| {
        let mut units = 0;
        text.char_indices().find_map(|(i, c)| {
            if units == offset { Some(i) } else { units += c.len_utf16() as u32; None }
        }).unwrap_or(text.len())
    };
    let mut edits: Vec<_> = edits.into_iter().map(|e| (byte(e.start), byte(e.end), e.name, e.math)).collect();
    let parsed = typst::syntax::parse(text);
    let declarations: Vec<_> = edits.iter().filter(|e| !e.3).map(|e| e.0).collect();
    operator_callees(&LinkedNode::new(&parsed), &declarations, &mut edits);
    edits.sort_by_key(|e| e.0);
    edits.dedup_by_key(|e| e.0);
    let (mut code, mut segments, mut maths, mut cursor) = (String::new(), Vec::new(), Vec::new(), 0);
    for (start, end, name, math) in edits {
        if start < cursor || name.len() > end - start { return None; }
        code.push_str(&text[cursor..start]);
        segments.push(cursor..start);
        let range = code.len()..code.len() + name.len();
        code.push_str(&name);
        if name.len() == end - start { segments.push(start..end); }
        else if !name.is_empty() {
            segments.push(start..start + name.len() - 1);
            segments.push(end - 1..end);
        }
        if math { maths.push(range); }
        cursor = end;
    }
    code.push_str(&text[cursor..]);
    segments.push(cursor..text.len());
    let parsed = typst::syntax::parse(&code);
    let mut root = identifiers(&LinkedNode::new(&parsed), &maths, &code);
    root.synthesize_mapped(id, &RangeMapper::new(segments).ok()?).ok()?;
    Some(Source::with_root(id, text.into(), root))
}

fn identifiers(node: &LinkedNode, maths: &[std::ops::Range<usize>], code: &str) -> SyntaxNode {
    if maths.contains(&node.range()) { return SyntaxNode::leaf(SyntaxKind::MathIdent, &code[node.range()]); }
    let children: Vec<_> = node.children().collect();
    if children.is_empty() { return node.get().clone(); }
    let (mut rebuilt, mut i) = (Vec::new(), 0);
    while i < children.len() {
        if let Some(range) = maths.iter().find(|r| r.start == children[i].offset()) {
            let mut end = i;
            while end < children.len() && children[end].range().end < range.end { end += 1; }
            if end < children.len() && children[end].range().end == range.end {
                rebuilt.push(SyntaxNode::leaf(SyntaxKind::MathIdent, &code[range.clone()]));
                i = end + 1;
                continue;
            }
        }
        rebuilt.push(identifiers(&children[i], maths, code));
        i += 1;
    }
    SyntaxNode::inner(node.kind(), rebuilt)
}

#[cfg(test)]
mod tests {
    use super::*;
    use typst::foundations::Bytes;

    #[test]
    fn removing_an_operator_does_not_incrementally_reparse_a_mapped_tree() {
        let id = Source::detached("").id();
        let first = "#let Λ = math.op(\"tri\")\n$Λ(x)$";
        let first = crate::decode(id, Ok(Bytes::new(first.as_bytes().to_vec())), None).unwrap();
        let next = "#let Λ = 3\n$Λ(x)$";
        let next = crate::decode(id, Ok(Bytes::new(next.as_bytes().to_vec())), Some(first)).unwrap();
        assert_eq!(next.text(), "#let Λ = 3\n$Λ(x)$");
        assert!(matches!(next.root().span().get(), typst::syntax::SpanKind::Number { .. }));
    }
}
