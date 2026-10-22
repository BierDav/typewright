//! Local history of one file: versions, contents and restoring.
use anyhow::{Result, anyhow, bail};
use base64::Engine as _;
use futures::AsyncReadExt as _;
use jj_lib::backend::{CommitId, FileId, MergedTreeValue, TreeValue};
use jj_lib::diff::{ContentDiff, DiffHunkKind};
use jj_lib::matchers::EverythingMatcher;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::store::Store;
use pollster::FutureExt as _;
use serde_json::{Value, json};

use crate::repo::{Repo, diff_files, first_parent_chain, repo_path};

pub(crate) fn read_file(store: &Store, path: &RepoPath, id: &FileId) -> Result<Vec<u8>> {
    let mut reader = store.read_file(path, id).block_on()?;
    let mut buf = Vec::new();
    reader.read_to_end(&mut buf).block_on()?;
    Ok(buf)
}

fn file_id(value: &MergedTreeValue) -> Option<&FileId> {
    match value.as_resolved() {
        Some(Some(TreeValue::File { id, .. })) => Some(id),
        _ => None,
    }
}

fn is_present(value: &MergedTreeValue) -> bool { !matches!(value.as_resolved(), Some(None)) }

fn content(store: &Store, path: &RepoPath, value: &MergedTreeValue) -> Result<Vec<u8>> {
    match file_id(value) {
        Some(id) => read_file(store, path, id),
        None => Ok(Vec::new()),
    }
}

/// Added and removed line counts; zero for binary content.
pub(crate) fn line_counts(old: &[u8], new: &[u8]) -> (usize, usize) {
    if crate::lfs::sniffs_binary(old) || crate::lfs::sniffs_binary(new) {
        return (0, 0);
    }
    let diff = ContentDiff::by_line([old, new]);
    let (mut added, mut removed) = (0, 0);
    for hunk in diff.hunks() {
        if hunk.kind == DiffHunkKind::Different {
            removed += count_lines(hunk.contents[0]);
            added += count_lines(hunk.contents[1]);
        }
    }
    (added, removed)
}

fn count_lines(text: &[u8]) -> usize {
    if text.is_empty() {
        return 0;
    }
    text.iter().filter(|b| **b == b'\n').count() + usize::from(!text.ends_with(b"\n"))
}

/// The path a file had in `before` if `commit` renamed it to `path` (same content, old path gone).
fn renamed_from(before: &MergedTree, after: &MergedTree, path: &RepoPath, value: &MergedTreeValue) -> Result<Option<RepoPathBuf>> {
    let Some(id) = file_id(value) else { return Ok(None) };
    for (other, new_value) in diff_files(before, after, &EverythingMatcher)? {
        if other.as_ref() == path || is_present(&new_value) {
            continue;
        }
        let old_value = before.path_value(&other).block_on()?;
        if file_id(&old_value) == Some(id) {
            return Ok(Some(other));
        }
    }
    Ok(None)
}

pub(crate) fn commit_id(hex: &str) -> Result<CommitId> {
    CommitId::try_from_hex(hex).ok_or_else(|| anyhow!("invalid commit {hex:?}"))
}

impl Repo {
    pub fn file_history(&self, path: &str, limit: u32) -> Result<Value> {
        let repo = self.head()?;
        let store = repo.store().clone();
        let wc = self.wc_commit(&repo)?;
        let mut current = repo_path(path)?;
        let mut versions = Vec::new();
        for commit in first_parent_chain(repo.as_ref(), &wc)? {
            if versions.len() >= limit as usize {
                break;
            }
            let after_tree = commit.tree();
            let before_tree = commit.parent_tree(repo.as_ref()).block_on()?;
            let after = after_tree.path_value(&current).block_on()?;
            let before = before_tree.path_value(&current).block_on()?;
            if after == before {
                continue;
            }
            let mut from = None;
            let kind = match (is_present(&before), is_present(&after)) {
                (false, true) => match renamed_from(&before_tree, &after_tree, &current, &after)? {
                    Some(old) => {
                        from = Some(old);
                        "renamed"
                    }
                    None => "added",
                },
                (true, false) => "deleted",
                _ => "modified",
            };
            let old_path = from.clone().unwrap_or_else(|| current.clone());
            let old_value = if from.is_some() { before_tree.path_value(&old_path).block_on()? } else { before };
            let (added, removed) = line_counts(&content(&store, &old_path, &old_value)?, &content(&store, &current, &after)?);
            let time = commit.committer().timestamp.timestamp.0 as f64 / 1000.0;
            let mut version = json!({
                "commit": commit.id().hex(),
                "time": time,
                "description": commit.description().trim_end(),
                "kind": kind,
                "added": added,
                "removed": removed,
            });
            if let Some(old) = &from {
                version["from"] = json!(old.as_internal_file_string());
                current = old.clone();
            }
            versions.push(version);
        }
        Ok(Value::Array(versions))
    }

    fn value_at(&self, commit: &str, path: &str) -> Result<(RepoPathBuf, MergedTree, MergedTreeValue)> {
        let repo = self.head()?;
        let commit = repo.store().get_commit(&commit_id(commit)?)?;
        let path = repo_path(path)?;
        let tree = commit.tree();
        let value = tree.path_value(&path).block_on()?;
        Ok((path, tree, value))
    }

    pub fn file_at(&self, commit: &str, path: &str) -> Result<Value> {
        let (path, tree, value) = self.value_at(commit, path)?;
        let bytes = match value.as_resolved() {
            Some(None) | Some(Some(TreeValue::Tree(_))) => return Ok(json!({"missing": true})),
            Some(Some(TreeValue::File { id, .. })) => read_file(tree.store(), &path, id)?,
            Some(Some(_)) => return Ok(json!({"missing": true})),
            None => crate::conflicts::materialize(tree.store(), &path, &value, tree.labels())?,
        };
        Ok(match String::from_utf8(bytes) {
            Ok(text) if !crate::lfs::sniffs_binary(text.as_bytes()) => json!({"text": text}),
            Ok(text) => json!({"data": base64::engine::general_purpose::STANDARD.encode(text.as_bytes())}),
            Err(e) => json!({"data": base64::engine::general_purpose::STANDARD.encode(e.as_bytes())}),
        })
    }

    pub fn restore_file(&mut self, commit: &str, path: &str) -> Result<Value> {
        let (repo_path, tree, value) = self.value_at(commit, path)?;
        let Some(Some(TreeValue::File { id, executable, .. })) = value.as_resolved() else {
            bail!("{path} is not a file in {commit}");
        };
        let bytes = read_file(tree.store(), &repo_path, id)?;
        crate::fsutil::write_atomic(&self.disk_path(&repo_path)?, &bytes, *executable)?;
        let committed = self.commit(&format!("Restore {path}"))?;
        Ok(json!({"commit": committed.commit}))
    }
}
