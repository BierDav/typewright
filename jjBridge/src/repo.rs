//! Opening the repository, snapshots and commits, squashing old history.
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use futures::StreamExt as _;
use jj_lib::backend::{Signature, Timestamp, TreeValue};
use jj_lib::commit::Commit;
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::matchers::{DifferenceMatcher, EverythingMatcher, FilesMatcher, Matcher, NothingMatcher};
use jj_lib::merge::Merge;
use jj_lib::merged_tree::MergedTree;
use jj_lib::merged_tree_builder::MergedTreeBuilder;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use jj_lib::settings::UserSettings;
use jj_lib::working_copy::{SnapshotOptions, UntrackedReason};
use jj_lib::workspace::Workspace;
use pollster::FutureExt as _;
use serde::{Deserialize, Serialize};

use crate::lfs::LfsFile;

/// Names the Finder, editors and our own atomic writes leave behind; never tracked.
const BASE_IGNORES: &[u8] = b".DS_Store\n._*\nIcon\r\n.Trashes\n.fseventsd\n.Spotlight-V100\n.TemporaryItems\n\
.DocumentRevisions-V100\n.twj-tmp-*\n~$*\n.~lock.*\n*.swp\n";
pub(crate) const TEMP_PREFIX: &str = ".twj-tmp-";

pub(crate) const USER_NAME: &str = "Typewright";
pub(crate) const USER_EMAIL: &str = "typewright@localhost";

/// Bookkeeping jj has no place for, in `.jj/typewright/state.json`.
#[derive(Default, Serialize, Deserialize)]
pub(crate) struct State {
    /// LFS files by repo path: untracked by jj, hashed lazily.
    #[serde(default)]
    pub lfs: BTreeMap<String, LfsFile>,
    #[serde(default)]
    pub shares: BTreeMap<String, crate::nodes::ShareState>,
}

pub struct Repo {
    pub(crate) workspace: Workspace,
    pub(crate) lfs_limit: u64,
    pub(crate) state: State,
    /// Fixed commit time for tests.
    pub(crate) clock: Option<Timestamp>,
}

pub struct Committed {
    pub commit: Option<String>,
    pub changed: Vec<String>,
}

pub(crate) fn settings() -> Result<UserSettings> {
    let mut config = StackedConfig::with_defaults();
    let text = format!(
        "user.name = \"{USER_NAME}\"\nuser.email = \"{USER_EMAIL}\"\nui.conflict-marker-style = \"git\"\n"
    );
    config.add_layer(ConfigLayer::parse(ConfigSource::User, &text)?);
    Ok(UserSettings::from_config_and_home_dir(config, None)?)
}

pub(crate) fn repo_path(path: &str) -> Result<RepoPathBuf> {
    let path = path.trim_matches('/');
    if path.is_empty() || path.split('/').any(|c| c.is_empty() || c == "." || c == "..") {
        return Err(anyhow!("invalid path {path:?}"));
    }
    RepoPathBuf::from_internal_string(path).map_err(|e| anyhow!("{e}"))
}

impl Repo {
    pub fn open(root: &Path) -> Result<Repo> {
        fs::create_dir_all(root).with_context(|| format!("create {}", root.display()))?;
        let settings = settings()?;
        let workspace = if root.join(".jj").is_dir() {
            Workspace::load(&settings, root, &default_backend_factories(), &default_working_copy_factories())?
        } else {
            Workspace::init_internal_git(&settings, root, gix::hash::Kind::Sha1).block_on()?.0
        };
        let mut repo = Repo { workspace, lfs_limit: 1 << 20, state: State::default(), clock: None };
        if let Ok(data) = fs::read(repo.state_path()) {
            repo.state = serde_json::from_slice(&data).unwrap_or_default();
        }
        Ok(repo)
    }

    pub fn root(&self) -> &Path { self.workspace.workspace_root() }

    fn state_path(&self) -> PathBuf { self.root().join(".jj/typewright/state.json") }

    pub(crate) fn save_state(&self) -> Result<()> {
        let path = self.state_path();
        fs::create_dir_all(path.parent().unwrap())?;
        crate::fsutil::write_atomic(&path, &serde_json::to_vec_pretty(&self.state)?, false)
    }

    pub fn set_lfs_limit(&mut self, bytes: u64) { self.lfs_limit = bytes; }

    pub(crate) fn head(&self) -> Result<Arc<ReadonlyRepo>> {
        Ok(self.workspace.repo_loader().load_at_head().block_on()?)
    }

    pub(crate) fn wc_commit(&self, repo: &ReadonlyRepo) -> Result<Commit> {
        let id = repo
            .view()
            .get_wc_commit_id(self.workspace.workspace_name())
            .ok_or_else(|| anyhow!("no working-copy commit"))?;
        Ok(repo.store().get_commit(id)?)
    }

    pub(crate) fn signature(&self) -> Signature {
        Signature {
            name: USER_NAME.into(),
            email: USER_EMAIL.into(),
            timestamp: self.clock.unwrap_or_else(Timestamp::now),
        }
    }

    pub(crate) fn disk_path(&self, path: &RepoPath) -> Result<PathBuf> {
        path.to_fs_path(self.root()).map_err(|e| anyhow!("{e}"))
    }

    /// Snapshots the disk; commits if anything changed. LFS files are kept out of the tree.
    pub fn commit(&mut self, message: &str) -> Result<Committed> {
        let mut lfs_changed = self.refresh_lfs()?;
        let repo = self.head()?;
        let wc = self.wc_commit(&repo)?;
        let lfs_paths: Vec<RepoPathBuf> = self.state.lfs.keys().filter_map(|p| repo_path(p).ok()).collect();
        let not_lfs = DifferenceMatcher::new(EverythingMatcher, FilesMatcher::new(&lfs_paths));
        let ignores = GitIgnoreFile::empty().chain(RepoPath::root(), Path::new(""), BASE_IGNORES)?;
        let options = SnapshotOptions {
            base_ignores: ignores,
            progress: None,
            start_tracking_matcher: &not_lfs,
            force_tracking_matcher: &NothingMatcher,
            max_new_file_size: self.lfs_limit,
        };
        let root = self.root().to_owned();
        let limit = self.lfs_limit;
        let name = self.workspace.workspace_name().to_owned();
        let sig = self.signature();

        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        let (snapshot, stats) = locked.locked_wc().snapshot(&options).block_on()?;
        let mut new_lfs = BTreeSet::new();
        for (path, reason) in &stats.untracked_paths {
            if matches!(reason, UntrackedReason::FileTooLarge { .. }) {
                new_lfs.insert(path.clone());
            }
        }
        // Tracked files that grew past the limit, and binary files, leave the tree.
        let mut untrack = Vec::new();
        for (path, after) in diff_files(&wc.tree(), &snapshot, &EverythingMatcher)? {
            if let Some(Some(TreeValue::File { .. })) = after.as_resolved() {
                let disk = path.to_fs_path(&root).map_err(|e| anyhow!("{e}"))?;
                if crate::lfs::is_lfs(&disk, limit) {
                    untrack.push(path);
                }
            }
        }
        let tree = if untrack.is_empty() {
            snapshot
        } else {
            let mut builder = MergedTreeBuilder::new(snapshot);
            for path in &untrack {
                builder.set_or_remove(path.clone(), Merge::absent());
                new_lfs.insert(path.clone());
            }
            builder.write_tree().block_on()?
        };
        let parent_tree = wc.parent_tree(repo.as_ref()).block_on()?;
        let changed: Vec<String> = diff_files(&parent_tree, &tree, &EverythingMatcher)?
            .into_iter()
            .map(|(p, _)| p.as_internal_file_string().to_owned())
            .collect();

        let mut tx = repo.start_transaction();
        let mut_repo = tx.repo_mut();
        let mut committed = None;
        if !changed.is_empty() {
            let done = mut_repo
                .rewrite_commit(&wc)
                .set_tree(tree.clone())
                .set_description(message)
                .set_author(sig.clone())
                .set_committer(sig.clone())
                .write()
                .block_on()?;
            mut_repo.rebase_descendants().block_on()?;
            let next = mut_repo
                .new_commit(vec![done.id().clone()], done.tree())
                .set_author(sig.clone())
                .set_committer(sig)
                .write()
                .block_on()?;
            mut_repo.set_wc_commit(name.clone(), next.id().clone())?;
            committed = Some(done.id().hex());
        } else if tree.tree_ids_and_labels() != wc.tree().tree_ids_and_labels() {
            mut_repo.rewrite_commit(&wc).set_tree(tree).write().block_on()?;
            mut_repo.rebase_descendants().block_on()?;
        }
        let repo = if tx.repo().has_changes() { tx.commit("snapshot").block_on()? } else { repo };
        let new_wc = {
            let id = repo.view().get_wc_commit_id(&name).ok_or_else(|| anyhow!("no working-copy commit"))?;
            repo.store().get_commit(id)?
        };
        locked.locked_wc().reset(&new_wc).block_on()?;
        locked.finish(repo.op_id().clone()).block_on()?;

        for path in new_lfs {
            let key = path.as_internal_file_string().to_owned();
            let disk = self.disk_path(&path)?;
            self.state.lfs.insert(key.clone(), LfsFile::stat(&disk).unwrap_or_default());
            lfs_changed.push(key);
        }
        self.save_state()?;
        let mut changed = changed;
        for path in lfs_changed {
            if !changed.contains(&path) {
                changed.push(path);
            }
        }
        changed.sort();
        Ok(Committed { commit: committed, changed })
    }

    /// Writes `tree` into the working-copy commit and commits it as `message`, assuming the disk already matches.
    pub(crate) fn commit_tree(&mut self, tree: MergedTree, message: &str) -> Result<Option<String>> {
        let repo = self.head()?;
        let wc = self.wc_commit(&repo)?;
        let name = self.workspace.workspace_name().to_owned();
        let sig = self.signature();
        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        let mut tx = repo.start_transaction();
        let mut_repo = tx.repo_mut();
        let parent_tree = wc.parent_tree(repo.as_ref()).block_on()?;
        let mut committed = None;
        if tree.tree_ids_and_labels() != parent_tree.tree_ids_and_labels() {
            let done = mut_repo
                .rewrite_commit(&wc)
                .set_tree(tree)
                .set_description(message)
                .set_author(sig.clone())
                .set_committer(sig.clone())
                .write()
                .block_on()?;
            mut_repo.rebase_descendants().block_on()?;
            let next = mut_repo
                .new_commit(vec![done.id().clone()], done.tree())
                .set_author(sig.clone())
                .set_committer(sig)
                .write()
                .block_on()?;
            mut_repo.set_wc_commit(name.clone(), next.id().clone())?;
            committed = Some(done.id().hex());
        }
        let repo = if tx.repo().has_changes() { tx.commit("sync").block_on()? } else { repo };
        let id = repo.view().get_wc_commit_id(&name).ok_or_else(|| anyhow!("no working-copy commit"))?;
        let new_wc = repo.store().get_commit(id)?;
        locked.locked_wc().reset(&new_wc).block_on()?;
        locked.finish(repo.op_id().clone()).block_on()?;
        Ok(committed)
    }

    /// Commits older than `days` collapse into one commit per local calendar day.
    pub fn squash(&mut self, days: u32) -> Result<usize> {
        let now = self.clock.unwrap_or_else(Timestamp::now).timestamp.0;
        let cutoff = now - i64::from(days) * 86_400_000;
        let repo = self.head()?;
        let name = self.workspace.workspace_name().to_owned();
        let wc = self.wc_commit(&repo)?;
        let mut chain = first_parent_chain(repo.as_ref(), &wc)?;
        chain.reverse();
        let groups = squash_groups(&chain, cutoff);
        if groups.is_empty() {
            return Ok(0);
        }
        // Rebuilt by hand rather than with rebase_descendants, which would stamp every rebased commit with now.
        let mut tx = repo.start_transaction();
        let mut_repo = tx.repo_mut();
        let mut parent = repo.store().root_commit_id().clone();
        let mut squashed = 0;
        let mut i = 0;
        while i < chain.len() {
            let (commit, description) = match groups.iter().find(|g| g.start == i) {
                Some(group) => {
                    let members = &chain[group.clone()];
                    for c in &members[..members.len() - 1] {
                        mut_repo.record_abandoned_commit(c);
                    }
                    squashed += members.len() - 1;
                    i = group.end;
                    let mut seen = BTreeSet::new();
                    let lines: Vec<&str> = members
                        .iter()
                        .map(|c| c.description().trim())
                        .filter(|d| !d.is_empty() && seen.insert(*d))
                        .collect();
                    (members.last().unwrap(), Some(lines.join("\n")))
                }
                None => {
                    i += 1;
                    (&chain[i - 1], None)
                }
            };
            if description.is_none() && commit.parent_ids() == [parent.clone()] {
                parent = commit.id().clone();
                continue;
            }
            let mut builder = mut_repo
                .rewrite_commit(commit)
                .set_parents(vec![parent.clone()])
                .set_author(commit.author().clone())
                .set_committer(commit.committer().clone());
            if let Some(description) = description {
                builder = builder.set_description(description);
            }
            parent = builder.write().block_on()?.id().clone();
        }
        let new_wc = mut_repo
            .rewrite_commit(&wc)
            .set_parents(vec![parent])
            .set_author(wc.author().clone())
            .set_committer(wc.committer().clone())
            .write()
            .block_on()?;
        mut_repo.set_wc_commit(name, new_wc.id().clone())?;
        mut_repo.rebase_descendants().block_on()?;
        let repo = tx.commit("squash history").block_on()?;
        let new_wc = self.wc_commit(&repo)?;
        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        locked.locked_wc().reset(&new_wc).block_on()?;
        locked.finish(repo.op_id().clone()).block_on()?;
        Ok(squashed)
    }
}

/// Committed history from the working copy's parent down to (excluding) the root, newest first.
pub(crate) fn first_parent_chain(repo: &dyn jj_lib::repo::Repo, wc: &Commit) -> Result<Vec<Commit>> {
    let root = repo.store().root_commit_id().clone();
    let mut chain = Vec::new();
    let mut id = wc.parent_ids().first().cloned();
    while let Some(current) = id {
        if current == root {
            break;
        }
        let commit = repo.store().get_commit(&current)?;
        id = commit.parent_ids().first().cloned();
        chain.push(commit);
    }
    Ok(chain)
}

pub(crate) fn local_day(timestamp: &Timestamp) -> i64 {
    let seconds = timestamp.timestamp.0.div_euclid(1000) + i64::from(timestamp.tz_offset) * 60;
    seconds.div_euclid(86_400)
}

/// Runs of at least two consecutive commits older than `cutoff` on the same local day, as index ranges.
fn squash_groups(oldest_first: &[Commit], cutoff: i64) -> Vec<std::ops::Range<usize>> {
    let mut groups = Vec::new();
    let mut i = 0;
    while i < oldest_first.len() {
        let time = &oldest_first[i].committer().timestamp;
        if time.timestamp.0 >= cutoff {
            break;
        }
        let day = local_day(time);
        let mut j = i + 1;
        while j < oldest_first.len() {
            let t = &oldest_first[j].committer().timestamp;
            if t.timestamp.0 >= cutoff || local_day(t) != day {
                break;
            }
            j += 1;
        }
        if j - i > 1 {
            groups.push(i..j);
        }
        i = j;
    }
    groups
}

/// Changed file paths between two trees with their new values.
pub(crate) fn diff_files(
    from: &MergedTree,
    to: &MergedTree,
    matcher: &dyn Matcher,
) -> Result<Vec<(RepoPathBuf, jj_lib::backend::MergedTreeValue)>> {
    let mut stream = from.diff_stream(to, matcher);
    let mut out = Vec::new();
    while let Some(entry) = stream.next().block_on() {
        let values = entry.values?;
        out.push((entry.path, values.after));
    }
    Ok(out)
}

#[cfg(test)]
pub(crate) fn millis(ms: i64) -> Timestamp { Timestamp { timestamp: jj_lib::backend::MillisSinceEpoch(ms), tz_offset: 0 } }
