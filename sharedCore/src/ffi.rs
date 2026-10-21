//! UniFFI's objects and the functions that take callbacks; plain functions are exported where they live.
use crate::references::PathReference;
use crate::sync::{LocalFile, RemoteEntry, SyncAction};
use std::sync::{Arc, Mutex, RwLock};

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

/// How one space's folder and its replica converge; see `sync::SpaceSync`.
#[derive(uniffi::Object)]
pub struct SpaceSync(Mutex<crate::sync::SpaceSync>);

#[uniffi::export]
impl SpaceSync {
    #[uniffi::constructor(default(lfs_threshold = 1048576.0))]
    pub fn new(lfs_threshold: f64) -> Self {
        Self(Mutex::new(crate::sync::SpaceSync::new(lfs_threshold)))
    }

    pub fn lfs_threshold(&self) -> f64 {
        self.0.lock().unwrap().lfs_threshold
    }

    pub fn set_lfs_threshold(&self, bytes: f64) {
        self.0.lock().unwrap().lfs_threshold = bytes;
    }

    /// Restores the bases saved with `save`.
    pub fn load(&self, state: &str) {
        self.0.lock().unwrap().load(state);
    }

    pub fn save(&self) -> String {
        self.0.lock().unwrap().save()
    }

    pub fn synced_paths(&self) -> Vec<String> {
        self.0.lock().unwrap().synced_paths()
    }

    /// Compares a full scan of the folder (without ignored files) against the bases.
    pub fn scan(&self, files: Vec<LocalFile>, ignore: Arc<IgnoreRules>) -> Vec<SyncAction> {
        self.0.lock().unwrap().scan(&files, &ignore.0.read().unwrap())
    }

    /// A replica change; `local` is the file's current state and `exists` tells which paths are taken on disk.
    pub fn remote(
        &self,
        entry: RemoteEntry,
        local: Option<LocalFile>,
        ignore: Arc<IgnoreRules>,
        exists: Box<dyn PathCheck>,
    ) -> Vec<SyncAction> {
        let ignore = ignore.0.read().unwrap();
        self.0.lock().unwrap().remote(&entry, local.as_ref(), &ignore, |p| exists.test(p.to_string()))
    }

    /// A merge that left conflicts falls back to a conflict copy.
    pub fn merge_failed(&self, path: &str, remote_hash: &str, size: f64, exists: Box<dyn PathCheck>) -> Vec<SyncAction> {
        self.0.lock().unwrap().merge_failed(path, remote_hash, size, |p| exists.test(p.to_string()))
    }

    /// The merged text is on disk.
    pub fn merged(&self, path: &str, remote_hash: &str) {
        self.0.lock().unwrap().merged(path, remote_hash);
    }

    /// A remote version that a live editing session already holds.
    pub fn accepted(&self, path: &str, hash: &str) {
        self.0.lock().unwrap().accepted(path, hash);
    }

    /// A `Write` finished; `ok` false leaves the path as it was.
    pub fn wrote(&self, path: &str, hash: &str, ok: bool) {
        self.0.lock().unwrap().wrote(path, hash, ok);
    }

    /// The replica accepted a `Publish` or `Unpublish`.
    pub fn published(&self, path: &str, hash: &str, deleted: bool) {
        self.0.lock().unwrap().published(path, hash, deleted);
    }
}
