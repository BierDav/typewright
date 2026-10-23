//! Deleting without a trash: deletions are commits, found again in the history. LFS files were never tracked, so
//! deleting moves them into a stash under `.jj/typewright/deleted/`, kept for `STASH_DAYS`.
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result, anyhow, bail};
use futures::StreamExt as _;
use jj_lib::backend::{MergedTreeValue, Timestamp, TreeValue};
use jj_lib::matchers::{EverythingMatcher, Matcher, PrefixMatcher};
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use pollster::FutureExt as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::history::{commit_id, read_file};
use crate::repo::{Repo, display_description, first_parent_chain, repo_path};

/// How far back the search walks; squashing keeps the chain short.
const MAX_COMMITS: usize = 20_000;
/// Stashed LFS files older than this are dropped.
const STASH_DAYS: i64 = 30;

/// One stashed deletion: the LFS files under `path`, as files below `files/` in its folder.
#[derive(Serialize, Deserialize)]
struct Stash {
    path: String,
    folder: bool,
    /// Milliseconds since the epoch.
    time: i64,
    files: Vec<String>,
}

fn is_tree(value: &MergedTreeValue) -> bool { matches!(value.as_resolved(), Some(Some(TreeValue::Tree(_)))) }
fn is_absent(value: &MergedTreeValue) -> bool { matches!(value.as_resolved(), Some(None)) }

fn prefix_matcher(prefix: &str) -> Result<Box<dyn Matcher>> {
    Ok(if prefix.is_empty() { Box::new(EverythingMatcher) } else { Box::new(PrefixMatcher::new([repo_path(prefix)?])) })
}

fn in_prefix(path: &str, prefix: &str) -> bool {
    prefix.is_empty() || path == prefix || path.starts_with(&format!("{prefix}/"))
}

/// Files below `dir` (or `dir` itself if it's a file), relative to it with `/`; links count as files.
fn walk(dir: &Path) -> Result<Vec<String>> {
    let meta = fs::symlink_metadata(dir)?;
    if !meta.is_dir() {
        return Ok(vec![String::new()]);
    }
    let mut out = Vec::new();
    let mut stack = vec![(dir.to_owned(), String::new())];
    while let Some((disk, rel)) = stack.pop() {
        for entry in fs::read_dir(&disk)? {
            let entry = entry?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let child = if rel.is_empty() { name } else { format!("{rel}/{name}") };
            if entry.file_type()?.is_dir() {
                stack.push((entry.path(), child));
            } else {
                out.push(child);
            }
        }
    }
    Ok(out)
}

fn now_millis(time: Option<Timestamp>) -> i64 { time.unwrap_or_else(Timestamp::now).timestamp.0 }

impl Repo {
    fn stash_dir(&self) -> PathBuf { self.root().join(".jj/typewright/deleted") }

    fn stashes(&self) -> Vec<(String, Stash)> {
        let Ok(entries) = fs::read_dir(self.stash_dir()) else { return Vec::new() };
        entries
            .filter_map(|e| e.ok())
            .filter_map(|e| {
                let id = e.file_name().to_string_lossy().into_owned();
                let stash = serde_json::from_slice(&fs::read(e.path().join("entry.json")).ok()?).ok()?;
                Some((id, stash))
            })
            .collect()
    }

    fn prune_stashes(&self) {
        let cutoff = now_millis(self.clock) - STASH_DAYS * 86_400_000;
        for (id, stash) in self.stashes() {
            if stash.time < cutoff {
                let _ = fs::remove_dir_all(self.stash_dir().join(id));
            }
        }
    }

    /// Deletes files and folders from disk and commits `message`; LFS files among them go to the stash first.
    /// Returns entries shaped like `deleted()`'s, for `restore_deleted` (undo).
    pub fn delete(&mut self, paths: &[String], message: &str) -> Result<Value> {
        self.prune_stashes();
        // Pending edits land first, so `lastCommit` has the latest content.
        self.commit("Edit")?;
        let repo = self.head()?;
        let last = self.wc_commit(&repo)?.parent_ids().first().map(|id| id.hex());
        let time = now_millis(self.clock);
        let mut entries = Vec::new();
        for (index, path) in paths.iter().enumerate() {
            let rpath = repo_path(path)?;
            let disk = self.disk_path(&rpath)?;
            let meta = fs::symlink_metadata(&disk).with_context(|| format!("{path} doesn't exist"))?;
            let folder = meta.is_dir();
            let files = walk(&disk)?;
            let lfs: Vec<&String> = files
                .iter()
                .filter(|rel| {
                    let key = if rel.is_empty() { path.clone() } else { format!("{path}/{rel}") };
                    let file = if rel.is_empty() { disk.clone() } else { disk.join(rel) };
                    self.state.lfs.contains_key(&key) || crate::lfs::is_lfs(&file, self.lfs_limit)
                })
                .collect();
            let mut stash_id = None;
            if !lfs.is_empty() {
                let id = format!("{time}-{index}");
                let dir = self.stash_dir().join(&id);
                for rel in &lfs {
                    let from = if rel.is_empty() { disk.clone() } else { disk.join(rel) };
                    let to = dir.join("files").join(if rel.is_empty() { "file" } else { rel.as_str() });
                    fs::create_dir_all(to.parent().unwrap())?;
                    fs::rename(&from, &to).or_else(|_| fs::copy(&from, &to).map(|_| ()))?;
                }
                let stash = Stash { path: path.clone(), folder, time, files: lfs.iter().map(|s| s.to_string()).collect() };
                fs::write(dir.join("entry.json"), serde_json::to_vec(&stash)?)?;
                stash_id = Some(id);
            }
            if folder { fs::remove_dir_all(&disk)? } else if disk.symlink_metadata().is_ok() { fs::remove_file(&disk)? }
            entries.push(json!({
                "path": path,
                "kind": if folder { "folder" } else { "file" },
                "files": files.len(),
                "lastCommit": last,
                "stash": stash_id,
                "time": time as f64 / 1000.0,
                "description": message,
            }));
        }
        let committed = self.commit(message)?;
        for entry in &mut entries {
            entry["commit"] = json!(committed.commit);
        }
        Ok(json!({"commit": committed.commit, "deleted": entries}))
    }

    /// Files and folders under `prefix` that some commit deleted and that don't exist again, newest deletion first.
    /// A folder deleted as a whole is one entry; `lastCommit` is the deleting commit's parent, which still has it.
    pub fn deleted(&self, prefix: &str, limit: u32) -> Result<Value> {
        let prefix = prefix.trim_matches('/');
        let repo = self.head()?;
        let wc = self.wc_commit(&repo)?;
        let current = wc.tree();
        let matcher = prefix_matcher(prefix)?;
        let mut found: Vec<Value> = Vec::new();
        let mut seen: HashSet<RepoPathBuf> = HashSet::new();
        for commit in first_parent_chain(repo.as_ref(), &wc)?.into_iter().take(MAX_COMMITS) {
            if found.len() >= limit as usize {
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
                    if dir.is_root() || !in_prefix(dir.as_internal_file_string(), prefix) {
                        break;
                    }
                    // jj has no empty folders: a folder still on disk only lost files.
                    if is_absent(&after.path_value(dir).block_on()?)
                        && is_tree(&before.path_value(dir).block_on()?)
                        && self.disk_path(dir)?.symlink_metadata().is_err()
                    {
                        key = (dir.to_owned(), true);
                    }
                }
                groups.entry(key.0).or_insert((key.1, 0)).1 += 1;
            }
            for (path, (folder, files)) in groups {
                if !seen.insert(path.clone()) || !is_absent(&current.path_value(&path).block_on()?) {
                    continue;
                }
                found.push(json!({
                    "path": path.as_internal_file_string(),
                    "kind": if folder { "folder" } else { "file" },
                    "files": files,
                    "commit": commit.id().hex(),
                    "lastCommit": parent_id.hex(),
                    "time": commit.author().timestamp.timestamp.0 as f64 / 1000.0,
                    "description": display_description(commit.description()),
                }));
            }
        }
        // Stashed LFS files join the deletion they were part of, or stand on their own.
        let mut stashes: Vec<(String, Stash)> =
            self.stashes().into_iter().filter(|(_, s)| in_prefix(&s.path, prefix)).collect();
        stashes.sort_by_key(|(_, s)| -s.time);
        let mut used = HashSet::new();
        for entry in &mut found {
            let path = entry["path"].as_str().unwrap_or_default().to_owned();
            let time = (entry["time"].as_f64().unwrap_or(0.0) * 1000.0) as i64;
            if let Some((id, _)) = stashes.iter().find(|(id, s)| !used.contains(id) && s.path == path && s.time <= time + 1000) {
                used.insert(id.clone());
                entry["stash"] = json!(id);
            }
        }
        for (id, stash) in &stashes {
            if used.contains(id) || found.iter().any(|e| e["path"] == stash.path.as_str()) {
                continue;
            }
            found.push(json!({
                "path": stash.path,
                "kind": if stash.folder { "folder" } else { "file" },
                "files": stash.files.len(),
                "stash": id,
                "time": stash.time as f64 / 1000.0,
                "description": format!("Delete {}", stash.path),
            }));
        }
        let mut entries = Vec::new();
        for entry in found {
            let path = repo_path(entry["path"].as_str().unwrap_or_default())?;
            if self.disk_path(&path)?.symlink_metadata().is_err() {
                entries.push(entry);
            }
        }
        entries.sort_by(|a, b| b["time"].as_f64().partial_cmp(&a["time"].as_f64()).unwrap_or(std::cmp::Ordering::Equal));
        entries.truncate(limit as usize);
        Ok(Value::Array(entries))
    }

    /// Puts a deleted entry (from `deleted` or `delete`) back at `dest`, which may differ from its path, and commits
    /// "Restore <dest>". Refuses with `"exists": true` when something is at `dest` already.
    pub fn restore_deleted(&mut self, entry: &str, dest: &str) -> Result<Value> {
        let entry: Value = serde_json::from_str(entry)?;
        let path = entry["path"].as_str().ok_or_else(|| anyhow!("entry without a path"))?;
        let to = repo_path(dest)?;
        let target = self.disk_path(&to)?;
        if target.symlink_metadata().is_ok() {
            return Ok(json!({"error": format!("{dest} exists"), "exists": true}));
        }
        let folder = entry["kind"] == "folder";
        let mut count = 0;
        if let Some(commit) = entry["lastCommit"].as_str() {
            count += self.write_from_commit(commit, path, &to)?;
        }
        if let Some(id) = entry["stash"].as_str() {
            let dir = self.stash_dir().join(id);
            let stash: Stash = serde_json::from_slice(&fs::read(dir.join("entry.json"))?)?;
            for rel in &stash.files {
                let from = dir.join("files").join(if rel.is_empty() { "file" } else { rel.as_str() });
                let file = if rel.is_empty() { target.clone() } else { target.join(rel) };
                fs::create_dir_all(file.parent().unwrap())?;
                fs::rename(&from, &file).or_else(|_| fs::copy(&from, &file).map(|_| ()))?;
                count += 1;
            }
            let _ = fs::remove_dir_all(&dir);
        }
        if count == 0 && folder {
            fs::create_dir_all(&target)?;
        } else if count == 0 {
            bail!("nothing left of {path}");
        }
        let committed = self.commit(&format!("Restore {dest}"))?;
        Ok(json!({"commit": committed.commit, "files": count}))
    }

    /// Writes the file or folder `path` from `commit` to `to`; the number of files written.
    fn write_from_commit(&self, commit: &str, path: &str, to: &RepoPath) -> Result<usize> {
        let repo = self.head()?;
        let tree = repo.store().get_commit(&commit_id(commit)?)?.tree();
        let from = repo_path(path)?;
        let value: MergedTreeValue = tree.path_value(&from).block_on()?;
        let mut files: Vec<(RepoPathBuf, Vec<u8>, bool)> = Vec::new();
        match value.as_resolved() {
            Some(Some(TreeValue::File { id, executable, .. })) => {
                files.push((to.to_owned(), read_file(tree.store(), &from, id)?, *executable));
            }
            Some(Some(TreeValue::Tree(_))) => {
                let skip = from.as_internal_file_string().len() + 1;
                let matcher = PrefixMatcher::new([&from]);
                for (file, entry) in tree.entries_matching(&matcher) {
                    let entry: MergedTreeValue = entry?;
                    let Some(Some(TreeValue::File { id, executable, .. })) = entry.as_resolved() else { continue };
                    let rest = &file.as_internal_file_string()[skip..];
                    let target = repo_path(&format!("{}/{rest}", to.as_internal_file_string()))?;
                    files.push((target, read_file(tree.store(), &file, id)?, *executable));
                }
            }
            _ => {}
        }
        for (file, bytes, executable) in &files {
            crate::fsutil::write_atomic(&self.disk_path(file)?, bytes, *executable)?;
        }
        Ok(files.len())
    }
}
