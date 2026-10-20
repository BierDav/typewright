//! solveng's editor support (`solveng-ide`, from the solveng repository) for the Mac and web apps: one entry point
//! taking an operation, the document, its context and a UTF-16 offset, answering JSON.

use std::hash::{Hash, Hasher};

use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::json;
use solveng_ide::{Context, ContextFile, Report};

/// The editor's context: the files around the document (paths relative to the root), the last compile's report,
/// the document's path and whether it's the compiled file.
#[derive(Deserialize, Default)]
#[serde(default)]
struct EditorContext {
    files: Vec<EditorFile>,
    report: String,
    path: String,
    main: bool,
    /// The compiled file, where the scopes of `definition` and `usages` are followed from.
    #[serde(rename = "mainPath")]
    main_path: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct EditorFile {
    path: String,
    text: String,
}

/// The last parsed context; it changes far less often than the document.
static CONTEXT: Mutex<Option<(u64, Context)>> = Mutex::new(None);

fn context(raw: &str) -> Context {
    if raw.is_empty() {
        return Context::default();
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    raw.hash(&mut hasher);
    let key = hasher.finish();
    let mut cache = CONTEXT.lock();
    if let Some((k, c)) = cache.as_ref()
        && *k == key
    {
        return c.clone();
    }
    let c = match serde_json::from_str::<EditorContext>(raw) {
        Ok(e) => {
            let text = e.files.iter().map(|f| f.text.as_str()).collect::<Vec<_>>().join("\n");
            let files = e.files.into_iter().map(|f| ContextFile { path: f.path, text: f.text }).collect();
            let c = Context::new(&text).with_files(files).with_report(&Report::parse(&e.report), &e.path, e.main);
            if e.main_path.is_empty() { c } else { c.with_main(&e.main_path) }
        }
        Err(_) => Context::new(raw),
    };
    *cache = Some((key, c.clone()));
    c
}

/// `op` on `document`: `tokens` (of solveng code), `documentTokens`, `conceals` (flat UTF-16 triples and
/// quintuples), `highlight` (`{tokens, plain}`, plain as start/end pairs), `complete`, `hover`, `definition`
/// (an object or null), `conversions`, `diagnostics`, `usages`, `references` (arrays) and `version`.
pub(crate) fn call(op: &str, document: &str, raw_context: &str, offset: u32) -> String {
    let value = match op {
        "tokens" => json!(solveng_ide::tokens(document).iter().flat_map(|t| [t.start, t.length, t.kind as u32]).collect::<Vec<_>>()),
        "references" => json!(solveng_ide::references(document)),
        "version" => json!(solveng_ide::VERSION),
        _ => {
            let c = context(raw_context);
            match op {
                "documentTokens" => json!(
                    solveng_ide::document_tokens(document, &c)
                        .iter()
                        .flat_map(|t| [t.start, t.length, t.kind as u32])
                        .collect::<Vec<_>>()
                ),
                // Tokens, and the stretches of calculated code and call strings, which show as plain text under them.
                "highlight" => json!({
                    "tokens": solveng_ide::document_tokens(document, &c)
                        .iter()
                        .flat_map(|t| [t.start, t.length, t.kind as u32])
                        .collect::<Vec<_>>(),
                    "plain": solveng_ide::regions(document, &c)
                        .iter()
                        .filter(|r| r.kind == "code" || r.kind == "string")
                        .flat_map(|r| [r.start, r.end])
                        .collect::<Vec<_>>(),
                }),
                "conceals" => json!(
                    solveng_ide::conceals(document, &c)
                        .iter()
                        .flat_map(|x| [x.start, x.length, x.character, x.element_start, x.element_end])
                        .collect::<Vec<_>>()
                ),
                "complete" => json!(solveng_ide::complete(document, &c, offset)),
                "hover" => json!(solveng_ide::hover(document, &c, offset)),
                "conversions" => json!(solveng_ide::conversions(document, &c, offset)),
                "diagnostics" => json!(solveng_ide::diagnostics(document, &c)),
                "definition" => json!(solveng_ide::definition(document, &c, offset)),
                "usages" => json!(solveng_ide::usages(document, &c, offset)),
                _ => serde_json::Value::Null,
            }
        }
    };
    value.to_string()
}

#[cfg(test)]
mod tests {
    use super::call;
    use serde_json::Value;

    #[test]
    fn reads_the_editor_context() {
        // A chapter included inside the main file's solve-block sees its definitions.
        let context = serde_json::json!({
            "files": [{"path": "main.typ", "text": "#show: solve-block\n#def(\"U = 5 V\")\n#include \"ch.typ\""}],
            "report": "", "path": "ch.typ", "main": false, "mainPath": "main.typ",
        })
        .to_string();
        let doc = "```solveng\nP = U * 2 A\nQ = P -> blorps\n```";
        let at = doc.find("U *").unwrap() as u32;
        let definition: Value = serde_json::from_str(&call("definition", doc, &context, at)).unwrap();
        assert_eq!(definition["path"], "main.typ");
        let usages: Value = serde_json::from_str(&call("usages", doc, &context, at)).unwrap();
        assert_eq!(usages.as_array().unwrap().len(), 2);
        let problems: Value = serde_json::from_str(&call("diagnostics", doc, &context, 0)).unwrap();
        assert!(problems[0]["message"].as_str().unwrap().contains("blorps"));
        assert_eq!(problems[0]["severity"], "warning");
    }

    #[test]
    fn keeps_blocks_apart() {
        let context = serde_json::json!({"files": [], "report": "", "path": "main.typ", "main": true}).to_string();
        let doc = "#solve-block[```solveng\nx = 1\ny = x\n```]\n#solve-block[```solveng\nx = 2\nz = x\n```]";
        let usages: Value = serde_json::from_str(&call("usages", doc, &context, doc.find("x = 1").unwrap() as u32)).unwrap();
        let starts: Vec<u64> = usages.as_array().unwrap().iter().map(|u| u["start"].as_u64().unwrap()).collect();
        assert_eq!(starts, vec![doc.find("x = 1").unwrap() as u64, doc.find("= x\n").unwrap() as u64 + 2]);
    }
}
