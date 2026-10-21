use crate::ignore::IgnoreRules;
use std::collections::{BTreeMap, HashMap, HashSet};

/// How a file syncs: small text files merge concurrent edits; everything else is replaced whole.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Enum))]
pub enum SyncMode {
    Merge,
    Lfs,
}

/// Files above this many bytes switch to LFS mode.
pub const DEFAULT_LFS_THRESHOLD: f64 = 1_048_576.0;

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn default_lfs_threshold() -> f64 {
    DEFAULT_LFS_THRESHOLD
}

/// `is_text` is false for kinds like PDF, Office, images and fonts, and for contents that sniff as binary.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn sync_mode(is_text: bool, size: f64, lfs_threshold: f64) -> SyncMode {
    if is_text && size <= lfs_threshold { SyncMode::Merge } else { SyncMode::Lfs }
}

/// Rejects paths that could leave the space or touch git's own data.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn is_safe_sync_path(path: &str) -> bool {
    if path.is_empty() || path.starts_with('/') || path.contains('\\') || path.contains('\0') {
        return false;
    }
    !path.split('/').any(|p| p.is_empty() || p == "." || p == ".." || p == ".git")
}

/// `dir/name (conflict).ext`, numbered while taken.
pub fn conflict_path(path: &str, exists: impl Fn(&str) -> bool) -> String {
    let (dir, file) = path.rsplit_once('/').unwrap_or(("", path));
    let (stem, ext) = match file.rfind('.') {
        Some(dot) if dot > 0 => file.split_at(dot),
        _ => (file, ""),
    };
    (1..)
        .map(|i| {
            let name = if i == 1 { format!("{stem} (conflict){ext}") } else { format!("{stem} (conflict {i}){ext}") };
            if dir.is_empty() { name } else { format!("{dir}/{name}") }
        })
        .find(|candidate| !exists(candidate))
        .unwrap()
}

/// A file on this device, hashed like blobs are (BLAKE3 hex).
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
#[cfg_attr(target_arch = "wasm32", serde(rename_all = "camelCase"))]
pub struct LocalFile {
    pub path: String,
    pub hash: String,
    pub size: f64,
    pub is_text: bool,
}

/// The newest replica entry of a path; deletions keep their path with `deleted`.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct RemoteEntry {
    pub path: String,
    pub hash: String,
    pub size: f64,
    pub deleted: bool,
}

#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Enum))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
#[cfg_attr(target_arch = "wasm32", serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase"))]
pub enum SyncAction {
    /// Import the local file into the replica.
    Publish { path: String },
    /// Mark the path deleted in the replica.
    Unpublish { path: String },
    /// Replace the local file with the blob; report back with `wrote`.
    Write { path: String, hash: String, size: f64 },
    /// Move the local file to the Trash.
    Trash { path: String },
    /// Merge the local text with the blob `remote_hash`, both edits of `base_hash`; report back with `merged`.
    Merge { path: String, base_hash: String, remote_hash: String },
    /// Save the blob as `copy_path` next to the local file, which stays and wins; no report needed.
    ConflictCopy { path: String, copy_path: String, hash: String, size: f64 },
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
impl SyncAction {
    pub fn path(&self) -> String {
        match self {
            SyncAction::Publish { path }
            | SyncAction::Unpublish { path }
            | SyncAction::Write { path, .. }
            | SyncAction::Trash { path }
            | SyncAction::Merge { path, .. }
            | SyncAction::ConflictCopy { path, .. } => path.clone(),
        }
    }
}

const DELETED: &str = "-";

/// Decides how one space's folder and its replica converge. It remembers the hash each path last had
/// on both sides (the base): a side that differs from it changed, and two changed sides conflict.
pub struct SpaceSync {
    pub lfs_threshold: f64,
    base: BTreeMap<String, String>,
    publishing: HashMap<String, String>,
    writing: HashMap<String, String>,
}

impl Default for SpaceSync {
    fn default() -> Self {
        Self::new(DEFAULT_LFS_THRESHOLD)
    }
}

impl SpaceSync {
    pub fn new(lfs_threshold: f64) -> Self {
        Self { lfs_threshold, base: BTreeMap::new(), publishing: HashMap::new(), writing: HashMap::new() }
    }

    /// Restores the bases saved with `save`.
    pub fn load(&mut self, state: &str) {
        self.base.clear();
        for line in crate::utf16::lines(state) {
            if let Some((hash, path)) = line.split_once('\t').filter(|(hash, _)| !hash.is_empty()) {
                self.base.insert(path.to_string(), hash.to_string());
            }
        }
    }

    pub fn save(&self) -> String {
        self.base.iter().map(|(path, hash)| format!("{hash}\t{path}")).collect::<Vec<_>>().join("\n")
    }

    pub fn synced_paths(&self) -> Vec<String> {
        self.base.keys().cloned().collect()
    }

    /// Compares a full scan of the folder (without ignored files) against the bases.
    pub fn scan(&mut self, files: &[LocalFile], ignore: &IgnoreRules) -> Vec<SyncAction> {
        let mut actions = Vec::new();
        let mut present = HashSet::new();
        for file in files {
            present.insert(file.path.as_str());
            if !is_safe_sync_path(&file.path) {
                continue;
            }
            let known = |map: &HashMap<String, String>| map.get(&file.path) == Some(&file.hash);
            if self.base.get(&file.path) == Some(&file.hash) || known(&self.publishing) || known(&self.writing) {
                continue;
            }
            self.publishing.insert(file.path.clone(), file.hash.clone());
            actions.push(SyncAction::Publish { path: file.path.clone() });
        }
        let gone: Vec<String> = self
            .base
            .keys()
            .filter(|p| !present.contains(p.as_str()) && !self.writing.contains_key(*p))
            .cloned()
            .collect();
        for path in gone {
            // Newly ignored files stop syncing without being deleted elsewhere.
            if ignore.is_ignored(&path, false) {
                self.base.remove(&path);
            } else if self.publishing.get(&path).map(String::as_str) != Some(DELETED) {
                self.publishing.insert(path.clone(), DELETED.to_string());
                actions.push(SyncAction::Unpublish { path });
            }
        }
        actions
    }

    /// A replica change, from another device or found at startup; `local` is the file's current state.
    /// `exists` tells which paths are taken on disk, for naming conflict copies.
    pub fn remote(
        &mut self,
        entry: &RemoteEntry,
        local: Option<&LocalFile>,
        ignore: &IgnoreRules,
        exists: impl Fn(&str) -> bool,
    ) -> Vec<SyncAction> {
        let path = &entry.path;
        if !is_safe_sync_path(path) || ignore.is_ignored(path, false) {
            return vec![];
        }
        let synced = self.base.get(path).cloned();
        let mine = local.map(|l| &l.hash);
        if entry.deleted {
            self.base.remove(path);
            return match mine {
                None => vec![],
                Some(mine) if Some(mine) == synced.as_ref() => vec![SyncAction::Trash { path: path.clone() }],
                // Edited here since: the edit outlives the deletion.
                Some(_) => vec![SyncAction::Publish { path: path.clone() }],
            };
        }
        if mine == Some(&entry.hash) {
            self.base.insert(path.clone(), entry.hash.clone());
            return vec![];
        }
        let Some(local) = local.filter(|_| mine != synced.as_ref()) else {
            self.writing.insert(path.clone(), entry.hash.clone());
            return vec![SyncAction::Write { path: path.clone(), hash: entry.hash.clone(), size: entry.size }];
        };
        // Only this device changed it; the next scan publishes that.
        if Some(&entry.hash) == synced.as_ref() {
            return vec![];
        }
        let mode = sync_mode(local.is_text, local.size.max(entry.size), self.lfs_threshold);
        if let (SyncMode::Merge, Some(base_hash)) = (mode, synced) {
            return vec![SyncAction::Merge { path: path.clone(), base_hash, remote_hash: entry.hash.clone() }];
        }
        self.conflict_copy(path, &entry.hash, entry.size, |p| exists(p) || ignore.is_ignored(p, false))
    }

    /// A merge that left conflicts falls back to a conflict copy.
    pub fn merge_failed(
        &mut self,
        path: &str,
        remote_hash: &str,
        size: f64,
        exists: impl Fn(&str) -> bool,
    ) -> Vec<SyncAction> {
        self.conflict_copy(path, remote_hash, size, exists)
    }

    /// The merged text is on disk; it builds on the remote version, and the next scan publishes it.
    pub fn merged(&mut self, path: &str, remote_hash: &str) {
        self.base.insert(path.to_string(), remote_hash.to_string());
    }

    /// A remote version that a live editing session already holds; the file isn't written, and the
    /// next scan publishes this device's copy, which converges with it.
    pub fn accepted(&mut self, path: &str, hash: &str) {
        self.base.insert(path.to_string(), hash.to_string());
    }

    /// A `Write` finished; `ok` false leaves the path as it was.
    pub fn wrote(&mut self, path: &str, hash: &str, ok: bool) {
        if self.writing.get(path).map(String::as_str) == Some(hash) {
            self.writing.remove(path);
        }
        if ok {
            self.base.insert(path.to_string(), hash.to_string());
        }
    }

    /// The replica accepted a `Publish` or `Unpublish`.
    pub fn published(&mut self, path: &str, hash: &str, deleted: bool) {
        let pending = self.publishing.get(path).map(String::as_str);
        if pending == Some(hash) || (deleted && pending == Some(DELETED)) {
            self.publishing.remove(path);
        }
        if deleted {
            self.base.remove(path);
        } else {
            self.base.insert(path.to_string(), hash.to_string());
        }
    }

    fn conflict_copy(&mut self, path: &str, hash: &str, size: f64, exists: impl Fn(&str) -> bool) -> Vec<SyncAction> {
        // The local file stays and is published over the remote version, which lives on as the copy.
        self.base.insert(path.to_string(), hash.to_string());
        // The copy is a new file to the next scan, which publishes it.
        let copy_path = conflict_path(path, |p| exists(p) || self.base.contains_key(p));
        vec![SyncAction::ConflictCopy { path: path.to_string(), copy_path, hash: hash.to_string(), size }]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(path: &str, hash: &str) -> LocalFile {
        LocalFile { path: path.into(), hash: hash.into(), size: 10.0, is_text: true }
    }

    fn entry(path: &str, hash: &str, deleted: bool) -> RemoteEntry {
        RemoteEntry { path: path.into(), hash: hash.into(), size: 10.0, deleted }
    }

    fn publish(path: &str) -> SyncAction {
        SyncAction::Publish { path: path.into() }
    }

    fn write(path: &str, hash: &str) -> SyncAction {
        SyncAction::Write { path: path.into(), hash: hash.into(), size: 10.0 }
    }

    fn never(_: &str) -> bool {
        false
    }

    #[test]
    fn publishes_local_changes_once() {
        let (mut sync, none) = (SpaceSync::default(), IgnoreRules::default());
        assert_eq!(vec![publish("a.typ")], sync.scan(&[text("a.typ", "h1")], &none));
        assert_eq!(Vec::<SyncAction>::new(), sync.scan(&[text("a.typ", "h1")], &none));
        sync.published("a.typ", "h1", false);
        assert_eq!(Vec::<SyncAction>::new(), sync.scan(&[text("a.typ", "h1")], &none));
        assert_eq!(vec![SyncAction::Unpublish { path: "a.typ".into() }], sync.scan(&[], &none));
        sync.published("a.typ", "del", true);
        assert!(sync.synced_paths().is_empty());
    }

    #[test]
    fn applies_remote_changes() {
        let (mut sync, none) = (SpaceSync::default(), IgnoreRules::default());
        assert_eq!(vec![write("a.typ", "h1")], sync.remote(&entry("a.typ", "h1", false), None, &none, never));
        // Scans while the write is in flight don't publish the half-synced file.
        assert_eq!(Vec::<SyncAction>::new(), sync.scan(&[text("a.typ", "h1")], &none));
        sync.wrote("a.typ", "h1", true);
        let local = text("a.typ", "h1");
        assert_eq!(vec![write("a.typ", "h2")], sync.remote(&entry("a.typ", "h2", false), Some(&local), &none, never));
        sync.wrote("a.typ", "h2", true);
        let local = text("a.typ", "h2");
        let trash = sync.remote(&entry("a.typ", "x", true), Some(&local), &none, never);
        assert_eq!(vec![SyncAction::Trash { path: "a.typ".into() }], trash);
    }

    #[test]
    fn merges_text_and_copies_binary_conflicts() {
        let (mut sync, none) = (SpaceSync::default(), IgnoreRules::default());
        sync.load("b0\tmain.typ\nb0\tfig.png");
        let merge = sync.remote(&entry("main.typ", "r1", false), Some(&text("main.typ", "l1")), &none, never);
        let expected = SyncAction::Merge { path: "main.typ".into(), base_hash: "b0".into(), remote_hash: "r1".into() };
        assert_eq!(vec![expected], merge);
        let figure = LocalFile { path: "fig.png".into(), hash: "l1".into(), size: 10.0, is_text: false };
        let copy = sync.remote(&entry("fig.png", "r1", false), Some(&figure), &none, |p| p == "fig (conflict).png");
        let expected = SyncAction::ConflictCopy {
            path: "fig.png".into(),
            copy_path: "fig (conflict 2).png".into(),
            hash: "r1".into(),
            size: 10.0,
        };
        assert_eq!(vec![expected], copy);
        // The local version wins afterwards.
        assert_eq!(publish("fig.png"), sync.scan(&[figure], &none)[0]);
    }

    #[test]
    fn large_text_files_use_lfs() {
        let (mut sync, none) = (SpaceSync::new(100.0), IgnoreRules::default());
        sync.load("b0\tbig.csv");
        let local = LocalFile { path: "big.csv".into(), hash: "l1".into(), size: 500.0, is_text: true };
        let remote = RemoteEntry { path: "big.csv".into(), hash: "r1".into(), size: 500.0, deleted: false };
        let actions = sync.remote(&remote, Some(&local), &none, never);
        assert!(matches!(actions[..], [SyncAction::ConflictCopy { .. }]));
        assert_eq!(SyncMode::Lfs, sync_mode(false, 5.0, 100.0));
        assert_eq!(SyncMode::Merge, sync_mode(true, 5.0, 100.0));
    }

    #[test]
    fn keeps_local_edits_over_remote_deletion_and_rejects_unsafe_paths() {
        let (mut sync, none) = (SpaceSync::default(), IgnoreRules::default());
        sync.load("b0\ta.typ");
        let publish_back = sync.remote(&entry("a.typ", "x", true), Some(&text("a.typ", "l1")), &none, never);
        assert_eq!(vec![publish("a.typ")], publish_back);
        assert!(sync.remote(&entry("../evil", "h", false), None, &none, never).is_empty());
        assert!(sync.remote(&entry(".git/config", "h", false), None, &none, never).is_empty());
        let mut pdfs = IgnoreRules::default();
        pdfs.add("", "*.pdf");
        assert!(sync.remote(&entry("out.pdf", "h", false), None, &pdfs, never).is_empty());
    }

    #[test]
    fn saves_bases() {
        let mut sync = SpaceSync::default();
        sync.load("h1\ta b/c.typ\nh2\tx.typ");
        let mut copy = SpaceSync::default();
        copy.load(&sync.save());
        assert_eq!(vec!["a b/c.typ", "x.typ"], copy.synced_paths());
    }
}
