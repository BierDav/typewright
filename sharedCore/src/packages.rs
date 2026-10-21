use crate::utf16::Utf16;
use regex_lite::Regex;
use std::collections::HashSet;
use std::sync::LazyLock;

/// A package's name and version from its `typst.toml`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct PackageManifest {
    pub name: String,
    pub version: String,
}

fn is_spec_char(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '_' | '-' | '/' | ':' | '.')
}

/// Where the package spec (`@local/name:1.0.0`) being typed starts, its `@`, when `offset` is inside a `"@…` string, else -1.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn package_spec_start(text: &str, offset: i32) -> i32 {
    let t = Utf16::new(text);
    let mut i = t.clamp(offset);
    while i > 0 && is_spec_char(t.at(i - 1)) {
        i -= 1;
    }
    if i < 2 || t.at(i - 1) != '@' || t.at(i - 2) != '"' { -1 } else { i as i32 - 1 }
}

/// Specs offered for `typed`: every version once a name is complete, else the newest version of each package.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn package_candidates(typed: &str, specs: Vec<String>) -> Vec<String> {
    let name = |spec: &str| spec.split(':').next().unwrap_or_default().to_string();
    if typed.contains(':') {
        let prefix = format!("{}:", name(typed));
        return specs.into_iter().filter(|spec| spec.starts_with(&prefix)).collect();
    }
    let mut seen = HashSet::new();
    specs.into_iter().filter(|spec| seen.insert(name(spec))).collect()
}

static SHORT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$").unwrap());
static GITHUB: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(?:https?://)?(?:www\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)").unwrap());
static URL_SCHEME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[a-z][a-z0-9+.-]*://").unwrap());
static NAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[A-Za-z0-9_-]+$").unwrap());
static VERSION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[0-9]+\.[0-9]+\.[0-9]+$").unwrap());

/// The clone URL for `owner/repo`, a github.com link (also to a tree or `.git`), or any other git URL as is;
/// None when it's none of these.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn package_clone_url(input: &str) -> Option<String> {
    let text = input.trim();
    let text = text.strip_suffix('/').unwrap_or(text);
    if text.is_empty() {
        return None;
    }
    if let Some(m) = SHORT.captures(text).or_else(|| GITHUB.captures(text)) {
        let repo = m[2].strip_suffix(".git").unwrap_or(&m[2]);
        return Some(format!("https://github.com/{}/{repo}.git", &m[1]));
    }
    (text.starts_with("git@") || URL_SCHEME.is_match(text)).then(|| text.to_string())
}

/// The repository's name from its clone URL, e.g. for a namespace made of the whole repository.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn package_repo_name(url: &str) -> String {
    let url = url.strip_suffix('/').unwrap_or(url);
    let name = url.rsplit('/').next().unwrap_or(url);
    let name = name.rsplit(':').next().unwrap_or(name);
    name.strip_suffix(".git").unwrap_or(name).to_string()
}

/// `name` and `version` of the `[package]` table; None when either is missing.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn package_manifest(toml: &str) -> Option<PackageManifest> {
    let (mut in_package, mut name, mut version) = (false, None, None);
    for raw in crate::utf16::lines(toml) {
        let line = raw.split('#').next().unwrap_or_default().trim();
        if line.starts_with('[') {
            in_package = line == "[package]";
            continue;
        }
        if !in_package {
            continue;
        }
        let key = line.split('=').next().unwrap_or_default().trim();
        let value = line.split_once('=').map_or("", |(_, v)| v).trim();
        let value = unquote(unquote(value, '"'), '\'');
        match key {
            "name" => name = Some(value.to_string()),
            "version" => version = Some(value.to_string()),
            _ => {}
        }
    }
    let name = name.filter(|n| NAME.is_match(n))?;
    let version = version.filter(|v| VERSION.is_match(v))?;
    Some(PackageManifest { name, version })
}

fn unquote(text: &str, quote: char) -> &str {
    match text.strip_prefix(quote).and_then(|t| t.strip_suffix(quote)) {
        Some(inner) if text.len() >= 2 => inner,
        _ => text,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_specs_in_import_strings() {
        let text = "#import \"@local/my-pkg:0";
        assert_eq!(9, package_spec_start(text, text.len() as i32));
        assert_eq!(9, package_spec_start("#import \"@", 10));
        assert_eq!(-1, package_spec_start("#import \"local", 14));
        assert_eq!(-1, package_spec_start("see @intro", 10));
    }

    #[test]
    fn offers_newest_versions_until_one_is_typed() {
        // Versions come newest first, as the package library lists them.
        let specs: Vec<String> = ["@local/a:2.0.0", "@local/a:1.0.0", "@local/b:0.1.0"].map(String::from).into();
        assert_eq!(vec!["@local/a:2.0.0", "@local/b:0.1.0"], package_candidates("@lo", specs.clone()));
        assert_eq!(vec!["@local/a:2.0.0", "@local/a:1.0.0"], package_candidates("@local/a:", specs));
    }

    #[test]
    fn turns_github_names_and_links_into_clone_urls() {
        assert_eq!(Some("https://github.com/typst/templates.git".into()), package_clone_url("typst/templates"));
        assert_eq!(Some("https://github.com/a/b.git".into()), package_clone_url("https://github.com/a/b/tree/main/src"));
        assert_eq!(Some("https://github.com/a/b.git".into()), package_clone_url("github.com/a/b.git"));
        assert_eq!(Some("git@gitlab.com:a/b.git".into()), package_clone_url("git@gitlab.com:a/b.git"));
        assert_eq!(None, package_clone_url("not a repo"));
        assert_eq!("b", package_repo_name("git@gitlab.com:a/b.git"));
    }

    #[test]
    fn reads_name_and_version_of_the_package_table() {
        let toml = "[package]\nname = \"my-pkg\" # comment\nversion = \"0.2.1\"\nentrypoint = \"lib.typ\"\n\n[tool.x]\nname = \"other\"";
        let manifest = PackageManifest { name: "my-pkg".into(), version: "0.2.1".into() };
        assert_eq!(Some(manifest), package_manifest(toml));
        assert_eq!(None, package_manifest("[package]\nname = \"x\""));
    }
}
