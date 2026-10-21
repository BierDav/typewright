//! solveng's editor support (`solveng-ide`, from the solveng repository) for the Mac and web apps: one entry point
//! taking an operation, the document, its context and a UTF-16 offset, answering JSON.

use std::hash::{Hash, Hasher};

use parking_lot::Mutex;
use serde::Deserialize;
use serde_json::json;
use solveng_ide::{Context, ContextFile, Report};

mod hover;

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
    /// The report of compiling the document on its own, for when the compiled file doesn't reach it.
    #[serde(rename = "fileReport")]
    file_report: String,
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
            let report = Report::parse(&e.report);
            // The compiled file's report covers the document only if that compile reached it; else its own does.
            let reached = e.main || report.elements.iter().any(|x| x.path == e.path);
            let (report, main, main_path) = if reached || e.file_report.is_empty() {
                (report, e.main, e.main_path)
            } else {
                (Report::parse(&e.file_report), true, e.path.clone())
            };
            // Only the compiler's report can enable calculations in the editor.
            let c = Context::new(&solveng_ide::with_compiled(&text, 0)).with_files(files).with_report(&report, &e.path, main);
            if main_path.is_empty() { c } else { c.with_main(&main_path) }
        }
        Err(_) => Context::new(raw),
    };
    *cache = Some((key, c.clone()));
    c
}

/// `op` on `document`: `tokens` (of solveng code), `pretty` (`{text, tokens}`: the code as documentation shows it, the context its own units, comma separated),
/// `documentTokens`, `conceals` (flat UTF-16 triples and
/// quintuples), `highlight` (`{tokens, plain}`, plain as start/end pairs), `complete`, `hover`, `definition`
/// (an object or null), `conversions`, `diagnostics`, `usages`, `references` (arrays), `renameTarget` (an object or
/// null), `rename:<new name>` (edits) and `version`.
pub(crate) fn call(op: &str, document: &str, raw_context: &str, offset: u32) -> String {
    let value = match op {
        "tokens" => json!(solveng_ide::tokens(document).iter().flat_map(|t| [t.start, t.length, t.kind as u32]).collect::<Vec<_>>()),
        "pretty" => {
            // the context is the document's own units, comma separated
            let units: Vec<String> = raw_context.split(',').map(str::trim).filter(|u| !u.is_empty()).map(String::from).collect();
            let (text, tokens) = solveng_ide::pretty(document, &units);
            json!({ "text": text, "tokens": tokens.iter().flat_map(|t| [t.start, t.length, t.kind as u32]).collect::<Vec<_>>() })
        }
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
                "hover" => json!(hover::hover(document, &c, offset)),
                "conversions" => json!(solveng_ide::conversions(document, &c, offset)),
                "diagnostics" => json!(solveng_ide::diagnostics(document, &c)),
                "definition" => json!(solveng_ide::definition(document, &c, offset)),
                "usages" => json!(solveng_ide::usages(document, &c, offset)),
                "renameTarget" => json!(solveng_ide::rename_target(document, &c, offset)),
                _ => match op.strip_prefix("rename:") {
                    Some(name) => json!(solveng_ide::rename(document, &c, offset, name)),
                    None => serde_json::Value::Null,
                },
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
    fn bundles_solveng_one() {
        assert_eq!(call("version", "", "", 0), "\"1.0.0\"");
    }

    #[test]
    fn documents_glued_names() {
        let doc = "#show: worksheet\n$ Sigma\"\"r := 1 + x + y^2 $\n$ Σ\"\"r -> $";
        let at = doc[..doc.rfind('Σ').unwrap()].encode_utf16().count() as u32;
        let hover: Value = serde_json::from_str(&call("hover", doc, "", at)).unwrap();
        assert_eq!(hover["start"], at);
        assert_eq!(hover["end"], at + 4);
        let markdown = hover["markdown"].as_str().unwrap();
        assert!(markdown.contains("Σr = 1 + x + y^2"), "{markdown}");
        assert!(markdown.contains("### Depends on\n\n- `x` (undefined)\n- `y` (undefined)"), "{markdown}");
        for offset in at + 1..at + 4 {
            let other: Value = serde_json::from_str(&call("hover", doc, "", offset)).unwrap();
            assert_eq!(other, hover);
        }
    }

    #[test]
    fn documents_transitive_dependencies_without_parameters_or_units() {
        let doc = "#show: worksheet\n$a := 2 A$\n$b := a + 3 A$\n$f(x: A) := b + x$\n$f(1 A) =$";
        let at = doc.rfind("f(").unwrap() as u32;
        let hover: Value = serde_json::from_str(&call("hover", doc, "", at)).unwrap();
        let markdown = hover["markdown"].as_str().unwrap();
        let dependencies = markdown.split("### Depends on\n\n").nth(1).unwrap();
        assert_eq!(dependencies, "- `b`\n- `a`");
    }

    #[test]
    fn documents_code_and_call_string_dependencies() {
        for doc in [
            "#show: worksheet\n```solveng\na := 2\nb := a + a\nf(x) := b + x\nf(1) =\n```",
            "#worksheet(\"a := 2\", \"b := a + a\", \"f(x) := b + x\", \"f(1) =\")",
        ] {
            let at = doc.rfind("f(").unwrap() as u32;
            let hover: Value = serde_json::from_str(&call("hover", doc, "", at)).unwrap();
            let markdown = hover["markdown"].as_str().unwrap();
            assert!(markdown.ends_with("### Depends on\n\n- `b`\n- `a`"), "{markdown}");
        }
    }

    #[test]
    fn dependencies_follow_the_visible_definition() {
        let doc = "#show: worksheet\n$x := 1$\n$y := 2$\n$a := x$\n$a =$\n$a := y$";
        let at = doc.find("a =").unwrap() as u32;
        let hover: Value = serde_json::from_str(&call("hover", doc, "", at)).unwrap();
        let markdown = hover["markdown"].as_str().unwrap();
        assert!(markdown.ends_with("### Depends on\n\n- `x`"), "{markdown}");
    }

    #[test]
    fn documents_dependencies_from_included_files() {
        let main = "#show: worksheet\n$a := 2$\n#include \"part.typ\"\n$b =$";
        let element = |path: &str, source: &str, text: &str| {
            let start = source.find(text).unwrap();
            serde_json::json!({"path": path, "start": start, "end": start + text.len(), "text": text,
                "kind": "math", "active": true, "integration": "math"})
        };
        let report = serde_json::json!({"blocks": 1, "elements": [
            element("main.typ", main, "$a := 2$"), element("main.typ", main, "$b =$"),
            element("part.typ", "$b := a + 1$", "$b := a + 1$")
        ]}).to_string();
        let context = serde_json::json!({
            "files": [{"path": "main.typ", "text": main}, {"path": "part.typ", "text": "$b := a + 1$"}],
            "path": "main.typ", "main": true, "mainPath": "main.typ",
            "report": report,
        }).to_string();
        let at = main.rfind("b =").unwrap() as u32;
        let hover: Value = serde_json::from_str(&call("hover", main, &context, at)).unwrap();
        let markdown = hover["markdown"].as_str().unwrap();
        assert!(markdown.ends_with("### Depends on\n\n- `a`"), "{markdown}");
    }

    #[test]
    fn reads_the_editor_context() {
        // A chapter included inside the main file's worksheet sees its definitions.
        let context = serde_json::json!({
            "files": [{"path": "main.typ", "text": "#show: worksheet\n#worksheet(\"U := 5 V\")\n#include \"ch.typ\""}],
            "report": "", "path": "ch.typ", "main": false, "mainPath": "main.typ",
        })
        .to_string();
        let doc = "```solveng\nP := U * 2 A\nQ := P = [blorps]\n```";
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
        let doc = "#worksheet[```solveng\nx := 1\ny := x\n```]\n#worksheet[```solveng\nx := 2\nz := x\n```]";
        let usages: Value = serde_json::from_str(&call("usages", doc, &context, doc.find("x := 1").unwrap() as u32)).unwrap();
        let starts: Vec<u64> = usages.as_array().unwrap().iter().map(|u| u["start"].as_u64().unwrap()).collect();
        assert_eq!(starts, vec![doc.find("x := 1").unwrap() as u64, doc.find("= x\n").unwrap() as u64 + 2]);
    }

    #[test]
    fn renames_through_the_op() {
        let doc = "#show: worksheet\n$R_\"load\" := 1$\n```solveng\nq := R_load\n```";
        let at = doc.find("R_load\n").unwrap() as u32;
        let target: Value = serde_json::from_str(&call("renameTarget", doc, "", at)).unwrap();
        assert_eq!(target["name"], "R_load");
        let edits: Value = serde_json::from_str(&call("rename:tews", doc, "", at)).unwrap();
        let texts: Vec<&str> = edits.as_array().unwrap().iter().map(|e| e["text"].as_str().unwrap()).collect();
        assert_eq!(texts, ["\"tews\"", "tews"]);
    }

    #[test]
    fn calculates_nothing_the_compile_didnt() {
        // The previewed file calculates its math, but its compile never reaches this one, which has no worksheet.
        let doc = "$Delta_R := 5%$\n$R_max := R + R Delta_R$";
        let context = |file_report: &str| {
            serde_json::json!({
                "files": [{"path": "main.typ", "text": "#show: worksheet"}],
                "report": r#"{"blocks": 1, "elements": [{"path": "main.typ", "kind": "math", "active": true, "integration": "math"}]}"#,
                "path": "other.typ", "main": false, "mainPath": "main.typ", "fileReport": file_report,
            })
            .to_string()
        };
        for file_report in ["", r#"{"blocks": 0}"#] {
            let highlight: Value = serde_json::from_str(&call("highlight", doc, &context(file_report), 0)).unwrap();
            assert!(highlight["tokens"].as_array().unwrap().is_empty(), "{file_report}");
            assert!(highlight["plain"].as_array().unwrap().is_empty(), "{file_report}");
        }
    }
}
