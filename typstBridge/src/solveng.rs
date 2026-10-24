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
            // Before compilation, included chapters inherit the worksheets written around them.
            let uncompiled = e.report.is_empty() && e.file_report.is_empty();
            let fallback = if report.blocks == 0 && (e.main || uncompiled) { text } else { solveng_ide::with_compiled(&text, 0) };
            let c = Context::new(&fallback).with_files(files).with_report(&report, &e.path, main);
            if main_path.is_empty() { c } else { c.with_main(&main_path) }
        }
        Err(_) => Context::new(raw),
    };
    *cache = Some((key, c.clone()));
    c
}

/// Editor operations on a document and its context, with UTF-16 offsets and JSON results.
pub(crate) fn call(op: &str, document: &str, raw_context: &str, offset: u32) -> String {
    let value = match op {
        "mathTokens" => json!(solveng_ide::math_tokens_of(document).iter().flat_map(|t| [t.start, t.length, t.kind as u32]).collect::<Vec<_>>()),
        "references" => json!(solveng_ide::references(document)),
        // the document is the function's name
        "function" => json!(solveng_ide::params::functions().iter().find(|f| f.name == document)),
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
                "fixes" => json!(solveng_ide::unit_fixes(document, &c, offset)),
                "format" => json!(solveng_ide::format(document, &c)),
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
    fn main_worksheet_supports_names_before_a_successful_compile() {
        let doc = r##"#import "@solveng/solveng:1.0.0": *
#worksheet(evaluate: true)[
  $ "pytagoras"(a, b, c) := a^2 + b^2 = c^2 $
  $ "circle"(x, r) := "pytagoras"(x,b,r) -> solve(b) $
  $ x´ := 3 $
  $ r` := 3 $
  $ z := x´ + r` $
  #graph($op("tri")(2x)$, xrange: ($r$, $-r$))
]"##;
        let context = serde_json::json!({"files": [], "report": "", "path": "main.typ", "main": true}).to_string();
        let at = |needle: &str| doc[..doc.rfind(needle).unwrap()].encode_utf16().count() as u32;
        let json = |op, offset| serde_json::from_str::<Value>(&call(op, doc, &context, offset)).unwrap();
        let definition = json("definition", at("\"pytagoras\"") + 2);
        assert_eq!(definition["start"], doc.find("\"pytagoras\"").unwrap());
        assert_eq!(json("usages", at("\"pytagoras\"") + 2).as_array().unwrap().len(), 2);
        assert_eq!(json("rename:hypotenuse", at("\"pytagoras\"") + 2).as_array().unwrap().len(), 2);
        let tokens = json("documentTokens", 0);
        for name in ["x´", "r`"] {
            let offset = at(name);
            assert_eq!(json("renameTarget", offset + 1)["name"], name);
            assert_eq!(json("usages", offset + 1).as_array().unwrap().len(), 2);
            assert_eq!(json("rename:q", offset + 1).as_array().unwrap().len(), 2);
            assert!(tokens.as_array().unwrap().chunks_exact(3).any(|t| t[0] == offset && t[1] == 2 && t[2] == solveng_ide::TokenKind::VARIABLE));
        }
    }

    #[test]
    fn value_supports_editor_features_in_math() {
        for expression in [r#"$U_2 / 2 = mV$"#] {
            let doc = format!("#import units: V, mV\n#show: worksheet\n$U_2 := 5 #V$\nVoltage: #value({expression}).");
            let context = serde_json::json!({"path": "main.typ", "main": true}).to_string();
            let at = doc[..doc.rfind("U_2").unwrap()].encode_utf16().count() as u32;
            let json = |op, offset| serde_json::from_str::<Value>(&call(op, &doc, &context, offset)).unwrap();
            assert_eq!(json("definition", at)["start"], doc.find("U_2").unwrap());
            assert_eq!(json("usages", at).as_array().unwrap().len(), 2);
            assert_eq!(json("rename:U_3", at).as_array().unwrap().len(), 2);
            assert!(json("hover", at)["markdown"].as_str().unwrap().contains("5 V"));
            let items = json("complete", at + 1);
            assert!(items["items"].as_array().unwrap().iter().any(|i| i["insert"] == "U_2"), "{items}");
            let tokens = json("documentTokens", 0);
            let unit = doc[..doc.rfind("mV").unwrap()].encode_utf16().count() as u32;
            assert!(tokens.as_array().unwrap().chunks_exact(3).any(|t| t[0] == unit && t[2] == solveng_ide::TokenKind::UNIT));
        }
        let function: Value = serde_json::from_str(&call("function", "value", "", 0)).unwrap();
        assert_eq!(function["positional"][0]["name"], "expr");
        assert!(function["doc"].as_str().unwrap().contains("expression"));
    }

    #[test]
    fn completes_and_documents_new_calculation_builtins() {
        for name in ["sum", "det", "tr", "integrate"] {
            let doc = format!("#import functions: *\n#value(${name}$)");
            let at = doc.find(name).unwrap() as u32;
            let result: Value = serde_json::from_str(&call("complete", &doc, "", at + name.len() as u32)).unwrap();
            let item = result["items"].as_array().unwrap().iter().find(|i| i["label"] == name).unwrap();
            assert!(item["documentation"].as_str().unwrap().contains("### Parameters"), "{item}");
            let hover: Value = serde_json::from_str(&call("hover", &doc, "", at + 1)).unwrap();
            assert!(hover["markdown"].as_str().unwrap().contains("### Parameters"), "{hover}");
        }
    }

    #[test]
    fn unit_shortcuts_complete_with_hashes_and_conceal_them() {
        let doc = "#import units: s\n#show: worksheet\n$x := 1 #s$";
        let at = doc.rfind("#s").unwrap() as u32;
        let complete: Value = serde_json::from_str(&call("complete", doc, "", at + 2)).unwrap();
        let item = complete["items"].as_array().unwrap().iter().find(|item| item["label"] == "s").unwrap();
        let mut text: Vec<u16> = doc.encode_utf16().collect();
        let from = complete["from"].as_u64().unwrap() as usize;
        let to = complete["to"].as_u64().unwrap_or((at + 2) as u64) as usize;
        text.splice(from..to, item["insert"].as_str().unwrap().encode_utf16());
        assert_eq!(String::from_utf16(&text).unwrap(), doc);
        let conceals: Value = serde_json::from_str(&call("conceals", doc, "", 0)).unwrap();
        assert!(conceals.as_array().unwrap().chunks_exact(5).any(|item| item[0] == at && item[1] == 1 && item[2] == 0));
        let string = "#value(\"x + 1\")";
        assert_eq!(call("complete", string, "", 11), "null");
    }

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
        assert!(markdown.contains("### Depends on\n\n```text\nx // undefined\ny // undefined\n```"), "{markdown}");
        for offset in at + 1..at + 4 {
            let other: Value = serde_json::from_str(&call("hover", doc, "", offset)).unwrap();
            assert_eq!(other, hover);
        }
    }

    #[test]
    fn documents_transitive_dependencies_without_parameters_or_units() {
        let doc = "#import units: A\n#show: worksheet\n$a := 2 #A$\n$b := a + 3 #A$\n$f(x: #A) := b + x$\n$f(1 #A) =$";
        let at = doc.rfind("f(").unwrap() as u32;
        let hover: Value = serde_json::from_str(&call("hover", doc, "", at)).unwrap();
        let markdown = hover["markdown"].as_str().unwrap();
        let dependencies = markdown.split("### Depends on\n\n").nth(1).unwrap();
        assert_eq!(dependencies, "```text\nb = a + 3 A\na: A = 2 A\n```");
    }

    #[test]
    fn documents_equation_and_call_dependencies() {
        for doc in [
            "#show: worksheet\n$a := 2$\n$b := a + a$\n$f(x) := b + x$\n$f(1) =$",
            "#worksheet($a := 2$, $b := a + a$, $f(x) := b + x$, $f(1) =$)",
        ] {
            let at = doc.rfind("f(").unwrap() as u32;
            let hover: Value = serde_json::from_str(&call("hover", doc, "", at)).unwrap();
            let markdown = hover["markdown"].as_str().unwrap();
            assert!(markdown.ends_with("### Depends on\n\n```text\nb = a + a\na = 2\n```"), "{markdown}");
        }
    }

    #[test]
    fn dependencies_follow_the_visible_definition() {
        let doc = "#show: worksheet\n$x := 1$\n$y := 2$\n$a := x$\n$a =$\n$a := y$";
        let at = doc.find("a =").unwrap() as u32;
        let hover: Value = serde_json::from_str(&call("hover", doc, "", at)).unwrap();
        let markdown = hover["markdown"].as_str().unwrap();
        assert!(markdown.ends_with("### Depends on\n\n```text\nx = 1\n```"), "{markdown}");
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
        assert!(markdown.ends_with("### Depends on\n\n```text\na = 2\n```"), "{markdown}");
    }

    #[test]
    fn reads_the_editor_context() {
        // A chapter included inside the main file's worksheet sees its definitions.
        let context = serde_json::json!({
            "files": [{"path": "main.typ", "text": "#show: worksheet\n$U := 5$\n#include \"ch.typ\""}],
            "report": "", "path": "ch.typ", "main": false, "mainPath": "main.typ",
        })
        .to_string();
        let doc = "$P := U * 2$\n$Q := P$\n$P := 3$";
        let at = doc.find("U *").unwrap() as u32;
        let definition: Value = serde_json::from_str(&call("definition", doc, &context, at)).unwrap();
        assert_eq!(definition["path"], "main.typ");
        let usages: Value = serde_json::from_str(&call("usages", doc, &context, at)).unwrap();
        assert_eq!(usages.as_array().unwrap().len(), 2);
        let problems: Value = serde_json::from_str(&call("diagnostics", doc, &context, 0)).unwrap();
        assert!(problems[0]["message"].as_str().unwrap().contains("assigned again"));
        assert_eq!(problems[0]["severity"], "warning");
    }

    #[test]
    fn keeps_blocks_apart() {
        let context = serde_json::json!({"files": [], "report": "", "path": "main.typ", "main": true}).to_string();
        let doc = "#worksheet[$x := 1$ $y := x$]\n#worksheet[$x := 2$ $z := x$]";
        let usages: Value = serde_json::from_str(&call("usages", doc, &context, doc.find("x := 1").unwrap() as u32)).unwrap();
        let starts: Vec<u64> = usages.as_array().unwrap().iter().map(|u| u["start"].as_u64().unwrap()).collect();
        assert_eq!(starts, vec![doc.find("x := 1").unwrap() as u64, doc.find("= x$").unwrap() as u64 + 2]);
    }

    #[test]
    fn renames_through_the_op() {
        let doc = "#show: worksheet\n$R_\"load\" := 1$\n$q := R_\"load\"$";
        let at = doc.rfind("R_\"load\"").unwrap() as u32;
        let target: Value = serde_json::from_str(&call("renameTarget", doc, "", at)).unwrap();
        assert_eq!(target["name"], "R_\"load\"");
        let edits: Value = serde_json::from_str(&call("rename:tews", doc, "", at)).unwrap();
        let texts: Vec<&str> = edits.as_array().unwrap().iter().map(|e| e["text"].as_str().unwrap()).collect();
        assert_eq!(texts, ["\"tews\"", "\"tews\""]);
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
