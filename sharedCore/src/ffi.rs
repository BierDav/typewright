//! UniFFI's objects and the functions that take callbacks; plain functions are exported where they live.
use crate::references::PathReference;
use std::sync::RwLock;

/// Answers a yes/no question about a path, like whether it's taken.
#[uniffi::export(callback_interface)]
pub trait PathCheck: Send + Sync {
    fn test(&self, path: String) -> bool;
}

/// The first free name for a new item: `name`, then `name 2` for folders or `name-2` for files.
/// Returns the file name including `ext`.
#[uniffi::export]
pub fn unique_name(name: &str, ext: Option<String>, exists: Box<dyn PathCheck>) -> String {
    crate::files::unique_name(name, ext.as_deref(), |p| exists.test(p.to_string()))
}

/// Literals in `text`, the Typst file at `file`, that point at `from` or into it, rewritten for its move to `to`.
/// Paths are relative to the space root; `exists` checks one before the move.
#[uniffi::export]
pub fn moved_path_references(
    text: &str,
    file: &str,
    from: &str,
    to: &str,
    exists: Box<dyn PathCheck>,
) -> Vec<PathReference> {
    crate::references::moved_path_references(text, file, from, to, |p| exists.test(p.to_string()))
}

/// `.gitignore` matching for a space; see `ignore::IgnoreRules`.
#[derive(uniffi::Object, Default)]
pub struct IgnoreRules(RwLock<crate::ignore::IgnoreRules>);

#[uniffi::export]
impl IgnoreRules {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds the rules of the `.gitignore` in folder `dir` ("" for the root). Add parents before children.
    pub fn add(&self, dir: &str, content: &str) {
        self.0.write().unwrap().add(dir, content);
    }

    /// Whether `path` or one of its folders is ignored.
    pub fn is_ignored(&self, path: &str, is_dir: bool) -> bool {
        self.0.read().unwrap().is_ignored(path, is_dir)
    }

    /// Whether the item itself matches, assuming its folders aren't ignored.
    pub fn matches(&self, path: &str, is_dir: bool) -> bool {
        self.0.read().unwrap().matches(path, is_dir)
    }
}

