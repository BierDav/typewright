//! Recently deleted files and folders, found in the history, and putting them back.
use std::collections::{BTreeMap, HashSet};

use anyhow::{Result, bail};
use futures::StreamExt as _;
use jj_lib::backend::{MergedTreeValue, TreeValue};
use jj_lib::matchers::{EverythingMatcher, Matcher, PrefixMatcher};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use pollster::FutureExt as _;
use serde_json::{Value, json};

use crate::history::{commit_id, read_file};
use crate::repo::{Repo, display_description, first_parent_chain, repo_path};

/// How far back the search walks; squashing keeps the chain short.
const MAX_COMMITS: usize = 20_000;

fn is_tree(value: &MergedTreeValue) -> bool { matches!(value.as_resolved(), Some(Some(TreeValue::Tree(_)))) }
fn is_absent(value: &MergedTreeValue) -> bool { matches!(value.as_resolved(), Some(None)) }

fn prefix_matcher(prefix: &str) -> Result<Box<dyn Matcher>> {
    let prefix = prefix.trim_matches('/');
    Ok(if prefix.is_empty() { Box::new(EverythingMatcher) } else { Box::new(PrefixMatcher::new([repo_path(prefix)?])) })
}

impl Repo {
    /// Files and folders under `prefix` that some commit deleted and that don't exist again, newest deletion first.
    /// A folder deleted as a whole is one entry; `lastCommit` is the deleting commit's parent, which still has it.
    pub fn deleted(&self, prefix: &str, limit: u32) -> Result<Value> {
        let repo = self.head()?;
        let wc = self.wc_commit(&repo)?;
        let current = wc.tree();
        let matcher = prefix_matcher(prefix)?;
        let mut seen: HashSet<RepoPathBuf> = HashSet::new();
        let mut entries = Vec::new();
        for commit in first_parent_chain(repo.as_ref(), &wc)?.into_iter().take(MAX_COMMITS) {
            if entries.len() >= limit as usize {
                break;
            }
            let Some(parent_id) = commit.parent_ids().first() else { continue };
            let before = commit.parent_tree(repo.as_ref()).block_on()?;
            let after = commit.tree();
            // Removed files, grouped under the topmost folder that disappeared with them.
            let mut groups: BTreeMap<RepoPathBuf, (bool, usize)> = BTreeMap::new();
            let mut stream = before.diff_stream(&after, matcher.as_ref());
            while let Some(entry) = stream.next().block_on() {
                let values = entry.values?;
                if is_absent(&values.before) || !is_absent(&values.after) {
                    continue;
                }
                let mut key = (entry.path.clone(), false);
                for dir in entry.path.ancestors().skip(1) {
                    if dir.is_root() || !self.under_prefix(dir, prefix) {
                        break;
                    }
                    if is_absent(&after.path_value(dir).block_on()?) && is_tree(&before.path_value(dir).block_on()?) {
                        key = (dir.to_owned(), true);
                    }
                }
                let group = groups.entry(key.0).or_insert((key.1, 0));
                group.1 += 1;
            }
            for (path, (folder, files)) in groups {
                if !seen.insert(path.clone()) || !is_absent(&current.path_value(&path).block_on()?) {
                    continue;
                }
                if self.disk_path(&path)?.symlink_metadata().is_ok() {
                    continue;
                }
                entries.push(json!({
                    "path": path.as_internal_file_string(),
                    "kind": if folder { "folder" } else { "file" },
                    "files": files,
                    "commit": commit.id().hex(),
                    "lastCommit": parent_id.hex(),
                    "time": commit.author().timestamp.timestamp.0 as f64 / 1000.0,
                    "description": display_description(commit.description()),
                }));
                if entries.len() >= limit as usize {
                    break;
                }
            }
        }
        Ok(Value::Array(entries))
    }

    fn under_prefix(&self, dir: &RepoPath, prefix: &str) -> bool {
        let prefix = prefix.trim_matches('/');
        prefix.is_empty() || dir.as_internal_file_string().len() >= prefix.len()
    }

    /// Writes the file or folder `path` as it was in `commit` to `dest` (often the same path) and commits
    /// "Restore <dest>". Refuses with `"exists": true` when something is at `dest` already.
    pub fn restore_path(&mut self, commit: &str, path: &str, dest: &str) -> Result<Value> {
        let repo = self.head()?;
        let source = repo.store().get_commit(&commit_id(commit)?)?;
        let tree = source.tree();
        let from = repo_path(path)?;
        let to = repo_path(dest)?;
        if self.disk_path(&to)?.symlink_metadata().is_ok() {
            return Ok(json!({"error": format!("{dest} exists"), "exists": true}));
        }
        let value: MergedTreeValue = tree.path_value(&from).block_on()?;
        let mut files: Vec<(RepoPathBuf, Vec<u8>, bool)> = Vec::new();
        match value.as_resolved() {
            Some(Some(TreeValue::File { id, executable, .. })) => {
                files.push((to.clone(), read_file(tree.store(), &from, id)?, *executable));
            }
            Some(Some(TreeValue::Tree(_))) => {
                let prefix = from.as_internal_file_string().len() + 1;
                let matcher = PrefixMatcher::new([&from]);
                for (file, entry) in tree.entries_matching(&matcher) {
                    let entry: MergedTreeValue = entry?;
                    let Some(Some(TreeValue::File { id, executable, .. })) = entry.as_resolved() else { continue };
                    let rest = &file.as_internal_file_string()[prefix..];
                    let target = repo_path(&format!("{}/{rest}", to.as_internal_file_string()))?;
                    files.push((target, read_file(tree.store(), &file, id)?, *executable));
                }
            }
            _ => bail!("{path} is not in {commit}"),
        }
        for (file, bytes, executable) in &files {
            crate::fsutil::write_atomic(&self.disk_path(file)?, bytes, *executable)?;
        }
        let committed = self.commit(&format!("Restore {dest}"))?;
        Ok(json!({"commit": committed.commit, "files": files.len()}))
    }
}
