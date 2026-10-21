use std::collections::HashSet;

use solveng_ide::{Context, Hover, ItemKind, TokenKind as K};

fn slice(text: &str, start: u32, end: u32) -> String {
    let units: Vec<u16> = text.encode_utf16().skip(start as usize).take((end - start) as usize).collect();
    String::from_utf16_lossy(&units)
}

fn key(name: &str) -> String {
    solveng_ide::resolved_name(&name.replace("\"\"", "\0").replace('"', "").replace('\0', "\"\""))
}

pub(super) fn hover(document: &str, context: &Context, offset: u32) -> Option<Hover> {
    let original = solveng_ide::hover(document, context, offset);
    let Some(target) = solveng_ide::rename_target(document, context, offset) else { return original };
    let Some(definition) = solveng_ide::definition(document, context, offset) else { return original };
    let name = key(&target.name);
    let mut hover = if let Some(hover) = original.filter(|h| h.start == target.start && h.end == target.end) {
        hover
    } else {
        let item = solveng_ide::complete(document, context, target.start)?.items.into_iter().find(|item| {
            matches!(item.kind, ItemKind::VARIABLE | ItemKind::FUNCTION)
                && key(item.label.split(['(', ':']).next().unwrap_or_default()) == name
        })?;
        Hover { start: target.start, end: target.end, markdown: format!("```solveng\n{} {}\n```", item.label, item.detail) }
    };
    let mut pending = vec![definition];
    let mut visited = HashSet::new();
    let mut names = HashSet::from([name]);
    let mut dependencies = Vec::new();
    while let Some(location) = pending.pop() {
        if !visited.insert((location.path.clone(), location.start)) { continue; }
        let (source, c) = match location.path.as_deref() {
            Some(path) if path != context.path => {
                let Some(f) = context.files.iter().find(|f| f.path == path) else { continue };
                let mut c = context.clone();
                c.path = path.into();
                (f.text.as_str(), c)
            }
            _ => (document, context.clone()),
        };
        let Some(region) = solveng_ide::regions(source, &c).into_iter()
            .filter(|r| r.kind != "call" && r.start <= location.start && location.end <= r.end)
            .min_by_key(|r| r.end - r.start) else { continue };
        let mut end = region.end;
        if region.kind != "math" {
            let tail = slice(source, location.end, end);
            if let Some(at) = tail.find(['\n', ';']) {
                end = location.end + tail[..at].encode_utf16().count() as u32;
            }
        }
        let tokens = solveng_ide::document_tokens(source, &c);
        let Some(assignment) = tokens.iter().find(|t| {
            t.start >= location.end && t.start < end && t.kind == K::OPERATOR
                && matches!(slice(source, t.start, t.start + t.length).as_str(), ":=" | "≔")
        }) else { continue };
        if let Some(result) = tokens.iter().find(|t| t.start > assignment.start && t.start < end && t.kind == K::EVALUATE) {
            end = result.start;
        }
        for token in tokens.iter().filter(|t| t.start > assignment.start && t.start < end && matches!(t.kind, K::VARIABLE | K::FUNCTION)) {
            let target = solveng_ide::rename_target(source, &c, token.start);
            let name = key(&target.map_or_else(|| slice(source, token.start, token.start + token.length), |t| t.name));
            let definition = solveng_ide::definition(source, &c, token.start);
            if definition.is_none() && token.kind == K::FUNCTION { continue; }
            if names.insert(name.clone()) {
                let value = context.defined.iter().find(|d| d.name == name && !d.value.is_empty());
                dependencies.push(match value {
                    Some(value) => format!("- `{name}` = `{}`", value.value),
                    None if definition.is_none() => format!("- `{name}` (undefined)"),
                    None => format!("- `{name}`"),
                });
            }
            if let Some(mut definition) = definition {
                if definition.path.is_none() { definition.path = location.path.clone(); }
                pending.push(definition);
            }
        }
    }
    hover.markdown.push_str("\n\n### Depends on\n\n");
    hover.markdown.push_str(if dependencies.is_empty() { "None." } else { "" });
    hover.markdown.push_str(&dependencies.join("\n"));
    Some(hover)
}
