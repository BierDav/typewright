//! Conflicted files of the working-copy commit: listing, hunks for the resolve UI, resolving.
use anyhow::{Result, anyhow, bail};
use jj_lib::backend::MergedTreeValue;
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::conflicts::{
    ConflictMarkerStyle, ConflictMaterializeOptions, materialize_merge_result_to_bytes,
    try_materialize_file_conflict_value,
};
use jj_lib::files::{MergeResult, merge_hunks};
use jj_lib::matchers::{EverythingMatcher, Matcher, PrefixMatcher};
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::RepoPath;
use jj_lib::store::Store;
use pollster::FutureExt as _;
use serde_json::{Value, json};

use crate::repo::{Repo, repo_path};

pub(crate) fn materialize_options(store: &Store) -> ConflictMaterializeOptions {
    ConflictMaterializeOptions {
        marker_style: ConflictMarkerStyle::Git,
        marker_len: None,
        merge: store.merge_options().clone(),
    }
}

/// The conflict as a file with conflict markers, as jj writes it into the working copy.
pub(crate) fn materialize(store: &Store, path: &RepoPath, value: &MergedTreeValue, labels: &ConflictLabels) -> Result<Vec<u8>> {
    match try_materialize_file_conflict_value(store, path, value, labels).block_on()? {
        Some(file) => Ok(materialize_merge_result_to_bytes(&file.contents, &file.labels, &materialize_options(store)).to_vec()),
        None => Ok(format!("Conflict at {}: a file on one side, a folder or link on another.\n", path.as_internal_file_string())
            .into_bytes()),
    }
}

fn text(bytes: &[u8]) -> Option<String> {
    if crate::lfs::sniffs_binary(bytes) {
        return None;
    }
    String::from_utf8(bytes.to_vec()).ok()
}

impl Repo {
    pub fn conflicts(&self, prefix: &str) -> Result<Vec<String>> {
        let repo = self.head()?;
        let tree = self.wc_commit(&repo)?.tree();
        let prefix = if prefix.trim_matches('/').is_empty() { None } else { Some(repo_path(prefix)?) };
        let matcher: Box<dyn Matcher> = match &prefix {
            Some(p) => Box::new(PrefixMatcher::new([p])),
            None => Box::new(EverythingMatcher),
        };
        let mut paths = Vec::new();
        for (path, value) in tree.conflicts_matching(matcher.as_ref()) {
            value?;
            paths.push(path.as_internal_file_string().to_owned());
        }
        Ok(paths)
    }

    pub fn conflict(&self, path: &str) -> Result<Value> {
        let repo = self.head()?;
        let store = repo.store();
        let tree = self.wc_commit(&repo)?.tree();
        let rpath = repo_path(path)?;
        let value = tree.path_value(&rpath).block_on()?;
        if value.is_resolved() {
            bail!("{path} has no conflict");
        }
        let Some(file) = try_materialize_file_conflict_value(store, &rpath, &value, tree.labels()).block_on()? else {
            return Ok(json!({"path": path, "binary": true, "sides": [], "hunks": []}));
        };
        let sides: Vec<String> = (0..file.contents.num_sides())
            .map(|i| match file.labels.get_add(i) {
                Some(label) if !label.is_empty() => label.to_owned(),
                _ => format!("Side {}", i + 1),
            })
            .collect();
        let binary = file.contents.iter().any(|c| text(c).is_none());
        if binary {
            return Ok(json!({"path": path, "binary": true, "sides": sides, "hunks": []}));
        }
        let lossy = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
        let hunks: Vec<Value> = match merge_hunks(&file.contents, store.merge_options()) {
            MergeResult::Resolved(content) => vec![json!({"text": lossy(&content)})],
            MergeResult::Conflict(hunks) => hunks
                .iter()
                .map(|hunk| match hunk.as_resolved() {
                    Some(t) => json!({"text": lossy(t)}),
                    None => json!({"conflict": {
                        "base": lossy(hunk.removes().next().map_or(&b""[..], |b| b.as_ref())),
                        "sides": hunk.adds().map(|s| lossy(s)).collect::<Vec<_>>(),
                    }}),
                })
                .collect(),
        };
        Ok(json!({"path": path, "binary": false, "sides": sides, "hunks": hunks}))
    }

    /// Writes the resolution (text, or side `side` of a binary conflict) and commits it.
    pub fn resolve(&mut self, path: &str, text: Option<&str>, side: i32) -> Result<Value> {
        let repo = self.prepare()?;
        let store = repo.store().clone();
        let tree = self.wc_commit(&repo)?.tree();
        let rpath = repo_path(path)?;
        let value = tree.path_value(&rpath).block_on()?;
        if value.is_resolved() {
            bail!("{path} has no conflict");
        }
        let disk = self.disk_path(&rpath)?;
        let file = try_materialize_file_conflict_value(&store, &rpath, &value, tree.labels()).block_on()?;
        let executable = file.as_ref().and_then(|f| f.executable).unwrap_or(false);
        match text {
            Some(text) => crate::fsutil::write_atomic(&disk, text.as_bytes(), executable)?,
            None => {
                let file = file.ok_or_else(|| anyhow!("{path} can't be resolved by side"))?;
                let index = usize::try_from(side).map_err(|_| anyhow!("invalid side {side}"))?;
                let ids: Vec<_> = file.ids.adds().cloned().collect();
                match ids.get(index).ok_or_else(|| anyhow!("invalid side {side}"))? {
                    Some(_) => {
                        let bytes = file.contents.adds().nth(index).unwrap().to_vec();
                        crate::fsutil::write_atomic(&disk, &bytes, executable)?;
                    }
                    None => crate::fsutil::remove_and_prune(&disk, self.root())?,
                }
            }
        }
        let committed = self.commit(&format!("Resolve {path}"))?;
        if !self.conflicts(path)?.is_empty() {
            bail!("{path} still has conflict markers");
        }
        Ok(json!({"commit": committed.commit}))
    }
}
