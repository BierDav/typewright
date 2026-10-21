use regex_lite::Regex;
use std::sync::LazyLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Enum))]
pub enum Severity {
    Error,
    Warning,
}

/// A compiler message at a one-based line and UTF-16 column.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct Diagnostic {
    pub path: String,
    pub line: i32,
    pub column: i32,
    pub severity: Severity,
    pub message: String,
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
impl Diagnostic {
    /// Package paths look like `@preview/name:1.0.0/lib.typ`.
    pub fn is_from_package(&self) -> bool {
        self.path.starts_with('@')
    }
}

static PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(.+?):([0-9]+):([0-9]+): (error|warning): (.*)$").unwrap());
static DURATION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"in ([0-9.]+) ?(µs|ms|s)\b").unwrap());

/// Parses typst's `--diagnostic-format short` output.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn parse_diagnostics(output: &str) -> Vec<Diagnostic> {
    crate::utf16::lines(output)
        .filter_map(|line| {
            let m = PATTERN.captures(line.trim_end_matches('\r'))?;
            Some(Diagnostic {
                path: m[1].to_string(),
                line: m[2].parse().unwrap_or(1),
                column: m[3].parse().unwrap_or(1),
                severity: if &m[4] == "warning" { Severity::Warning } else { Severity::Error },
                message: m[5].to_string(),
            })
        })
        .collect()
}

/// Seconds from `typst watch`'s `compiled successfully in 15.81 ms`.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn compile_duration(status: &str) -> Option<f64> {
    let m = DURATION.captures(status)?;
    let value: f64 = m[1].parse().ok()?;
    Some(match &m[2] {
        "µs" => value / 1_000_000.0,
        "ms" => value / 1000.0,
        _ => value,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_short_format() {
        let out = "main.typ:2:3: error: cannot access fields on type integer\n\
            @preview/icons:0.1.0/index.typ:8:21: warning: no whitespace before raw text\n\
            garbage line";
        let d = parse_diagnostics(out);
        assert_eq!(2, d.len());
        let first = Diagnostic {
            path: "main.typ".into(),
            line: 2,
            column: 3,
            severity: Severity::Error,
            message: "cannot access fields on type integer".into(),
        };
        assert_eq!(first, d[0]);
        assert!(!d[0].is_from_package());
        assert!(d[1].is_from_package());
        assert_eq!(Severity::Warning, d[1].severity);
    }

    #[test]
    fn parses_watch_duration() {
        let ms = compile_duration("[11:18:33] compiled successfully in 15.81 ms").unwrap();
        assert!((ms - 0.01581).abs() < 1e-9);
        assert_eq!(Some(1.5), compile_duration("[11:18:33] compiled with warnings in 1.5 s"));
        assert_eq!(None, compile_duration("[11:18:35] compiled with errors"));
    }
}
