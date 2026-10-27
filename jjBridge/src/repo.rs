//! Opening the repository, snapshots and commits.
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
use jj_lib::working_copy::{LockedWorkingCopy, SnapshotOptions, UntrackedReason};
use jj_lib::workspace::Workspace;
use pollster::FutureExt as _;
use serde::{Deserialize, Serialize};

use crate::lfs::LfsFile;

/// Local library guidance and files left by Finder, editors and our atomic writes; never tracked.
pub(crate) const BASE_IGNORES: &str = ".DS_Store\n._*\nIcon\r\n.Trashes\n.fseventsd\n.Spotlight-V100\n\
.TemporaryItems\n.DocumentRevisions-V100\n.twj-tmp-*\n~$*\n.~lock.*\n*.swp\n/.jj/\n/.jj.broken-*/\n/AGENTS.md\n";
pub(crate) const TEMP_PREFIX: &str = ".twj-tmp-";

pub(crate) const USER_NAME: &str = "Typewright";
pub(crate) const USER_EMAIL: &str = "typewright@localhost";
/// Marks commits Typewright made on its own; only those are ever squashed.
pub(crate) const APP_TRAILER: &str = "Typewright-Commit: auto";

/// Bookkeeping jj has no place for, in `.jj/typewright/state.json`.
#[derive(Default, Serialize, Deserialize)]
pub(crate) struct State {
    /// The workspace the app owns.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    /// Parents of the app's @ after the last call, to recreate a forgotten workspace in place.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub wc_parents: Vec<String>,
    /// Hash of the managed repo config as last written, to tell user edits apart.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config_hash: Option<String>,
    /// LFS files by repo path: untracked by jj, hashed lazily.
    #[serde(default)]
    pub lfs: BTreeMap<String, LfsFile>,
    #[serde(default)]
    pub lfs_versions: BTreeMap<String, Vec<crate::lfs_history::Version>>,
    #[serde(default)]
    pub shares: BTreeMap<String, crate::nodes::ShareState>,
}

pub struct Repo {
    pub(crate) settings: UserSettings,
    pub(crate) workspace: Workspace,
    pub(crate) lfs_limit: u64,
    pub(crate) state: State,
    /// Other workspaces our last call left stale (their files differ from their new @).
    pub(crate) stale_workspaces: Vec<String>,
    /// Whether our last call rewrote files on disk while repairing a stale working copy.
    pub(crate) wrote_files: bool,
    /// Where `.jj` went when it couldn't be loaded and was replaced.
    pub recovered_from: Option<PathBuf>,
    /// Fixed commit time for tests.
    pub(crate) clock: Option<Timestamp>,
    /// The local UTC offset in minutes, for hosts without a time zone database (WASI reports UTC).
    pub(crate) utc_offset: Option<i32>,
    pub(crate) watched_commit: Option<Commit>,
}

pub struct Committed {
    pub commit: Option<String>,
    pub changed: Vec<String>,
}

/// The working copy is locked by someone else (usually the jj CLI); retry later.
#[derive(Debug)]
pub struct Busy;

impl std::fmt::Display for Busy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("the repository is locked by another jj process")
    }
}

impl std::error::Error for Busy {}

pub(crate) fn base_settings() -> Result<StackedConfig> {
    let mut config = StackedConfig::with_defaults();
    let text = format!(
        "user.name = \"{USER_NAME}\"\nuser.email = \"{USER_EMAIL}\"\nui.conflict-marker-style = \"git\"\n"
    );
    config.add_layer(ConfigLayer::parse(ConfigSource::User, &text)?);
    Ok(config)
}

pub(crate) fn settings_with(repo_config: Option<&Path>) -> Result<UserSettings> {
    let mut config = base_settings()?;
    if let Some(path) = repo_config
        && path.is_file()
    {
        // The CLI reads the same file, so both materialize and parse conflicts alike.
        match ConfigLayer::load_from_file(ConfigSource::Repo, path.to_owned()) {
            Ok(layer) => config.add_layer(layer),
            Err(e) => eprintln!("jj: ignoring {}: {e}", path.display()),
        }
    }
    Ok(UserSettings::from_config_and_home_dir(config, None)?)
}

pub(crate) fn repo_path(path: &str) -> Result<RepoPathBuf> {
    let path = path.trim_matches('/');
    if path.is_empty() || path.split('/').any(|c| c.is_empty() || c == "." || c == "..") {
        return Err(anyhow!("invalid path {path:?}"));
    }
    RepoPathBuf::from_internal_string(path).map_err(|e| anyhow!("{e}"))
}

pub(crate) fn load_workspace(settings: &UserSettings, root: &Path) -> Result<Workspace> {
    Ok(Workspace::load(settings, root, &default_backend_factories(), &default_working_copy_factories())?)
}

/// `YYYYMMDD-HHMMSS` in UTC, for names of moved-aside folders.
fn stamp() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs() as i64);
    let (days, rest) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}{m:02}{d:02}-{:02}{:02}{:02}", rest / 3600, rest % 3600 / 60, rest % 60)
}

impl Repo {
    /// Opens (or creates) the repository. A `.jj` that can't be loaded is moved to `.jj.broken-<date>` and replaced by a
    /// fresh repository tracking the files on disk; the files themselves are never touched.
    pub fn open(root: &Path) -> Result<Repo> {
        fs::create_dir_all(root).with_context(|| format!("create {}", root.display()))?;
        let base = settings_with(None)?;
        #[cfg(target_os = "macos")]
        crate::colocation::ensure_layout(root)?;
        let mut recovered_from = None;
        if root.join(".jj").exists() && load_workspace(&base, root).is_err() {
            // One retry: a CLI writing its state at this moment isn't corruption.
            std::thread::sleep(std::time::Duration::from_millis(300));
            if let Err(e) = load_workspace(&base, root) {
                let aside = root.join(format!(".jj.broken-{}", stamp()));
                fs::rename(root.join(".jj"), &aside)
                    .with_context(|| format!("move the unreadable .jj aside ({e:#})"))?;
                eprintln!("jj: {} couldn't be loaded ({e:#}); moved to {}", root.join(".jj").display(), aside.display());
                recovered_from = Some(aside);
            }
        }
        if !root.join(".jj").exists() {
            #[cfg(target_os = "macos")]
            if root.join(".git").exists() {
                Workspace::init_external_git(&base, root, &root.join(".git")).block_on()?;
            } else {
                Workspace::init_colocated_git(&base, root, gix::hash::Kind::Sha1).block_on()?;
            }
            #[cfg(not(target_os = "macos"))]
            Workspace::init_internal_git(&base, root, gix::hash::Kind::Sha1).block_on()?;
        }
        let mut state = State::default();
        if let Ok(data) = fs::read(root.join(".jj/typewright/state.json")) {
            state = serde_json::from_slice(&data).unwrap_or_default();
        }
        let limit = 1 << 20;
        let config = crate::config::ensure_repo_config(&root.join(".jj/repo"), &mut state, limit);
        let settings = settings_with(config.as_deref())?;
        let workspace = load_workspace(&settings, root)?;
        state.workspace = Some(workspace.workspace_name().as_str().to_owned());
        let mut repo = Repo {
            settings,
            workspace,
            lfs_limit: limit,
            state,
            stale_workspaces: Vec::new(),
            wrote_files: false,
            recovered_from,
            clock: None,
            utc_offset: None,
            watched_commit: None,
        };
        repo.save_state()?;
        repo.write_excludes()?;
        let head = repo.prepare()?;
        repo.watched_commit = Some(repo.wc_commit(&head)?);
        Ok(repo)
    }

    pub fn root(&self) -> &Path { self.workspace.workspace_root() }

    fn state_path(&self) -> PathBuf { self.root().join(".jj/typewright/state.json") }

    pub(crate) fn save_state(&self) -> Result<()> {
        let path = self.state_path();
        fs::create_dir_all(path.parent().unwrap())?;
        crate::fsutil::write_atomic(&path, &serde_json::to_vec_pretty(&self.state)?, false)
    }

    pub fn set_lfs_limit(&mut self, bytes: u64) {
        if bytes == self.lfs_limit {
            return;
        }
        self.lfs_limit = bytes;
        let repo_dir = self.workspace.repo_path().to_owned();
        crate::config::ensure_repo_config(&repo_dir, &mut self.state, bytes);
        let _ = self.save_state();
    }

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
            timestamp: {
                let mut time = self.clock.unwrap_or_else(Timestamp::now);
                if let Some(offset) = self.utc_offset {
                    time.tz_offset = offset;
                }
                time
            },
        }
    }

    pub fn set_utc_offset(&mut self, minutes: i32) { self.utc_offset = Some(minutes) }

    pub(crate) fn disk_path(&self, path: &RepoPath) -> Result<PathBuf> {
        path.to_fs_path(self.root()).map_err(|e| anyhow!("{e}"))
    }

    /// Ignores for snapshots: ours, then git's like the CLI (`core.excludesFile`, the user's part of `info/exclude`).
    pub(crate) fn base_ignores(&self) -> Result<Arc<GitIgnoreFile>> {
        let mut ignores = GitIgnoreFile::empty().chain(RepoPath::root(), Path::new(""), BASE_IGNORES.as_bytes())?;
        if let Some(path) = crate::config::global_excludes_file(self) {
            ignores = ignores.chain_with_file(RepoPath::root(), path)?;
        }
        if let (Some(path), Some(bytes)) = (crate::config::exclude_path(self), crate::config::user_excludes(self)) {
            ignores = ignores.chain(RepoPath::root(), &path, &bytes)?;
        }
        Ok(ignores)
    }

    pub(crate) fn snapshot_inputs(&self) -> Result<SnapshotInputs> {
        Ok(SnapshotInputs {
            lfs: self.state.lfs.keys().filter_map(|p| repo_path(p).ok()).collect(),
            ignores: self.base_ignores()?,
            limit: self.lfs_limit,
            root: self.root().to_owned(),
        })
    }

    pub(crate) fn add_lfs(&mut self, paths: BTreeSet<RepoPathBuf>) -> Result<Vec<String>> {
        let mut keys = Vec::new();
        for path in paths {
            let key = path.as_internal_file_string().to_owned();
            let disk = self.disk_path(&path)?;
            self.state.lfs.insert(key.clone(), LfsFile::stat(&disk).unwrap_or_default());
            keys.push(key);
        }
        Ok(keys)
    }

    /// The description for a commit of @: the user's own if they wrote one, else ours with the app trailer.
    fn description_for(wc: &Commit, message: &str) -> String {
        if wc.description().trim().is_empty() {
            format!("{}\n\n{APP_TRAILER}\n", message.trim_end())
        } else {
            wc.description().to_owned()
        }
    }

    /// Snapshots the disk; commits if anything changed and starts a new empty @ on top.
    pub fn commit(&mut self, message: &str) -> Result<Committed> {
        let mut lfs_changed = self.refresh_lfs()?;
        // Before the snapshot, so files that left the LFS list are seen again.
        self.write_excludes()?;
        let repo = self.prepare()?;
        let wc = self.wc_commit(&repo)?;
        let parent_tree = wc.parent_tree(repo.as_ref()).block_on()?;
        let name = self.workspace.workspace_name().to_owned();
        let sig = self.signature();
        let description = Self::description_for(&wc, message);

        let inputs = self.snapshot_inputs()?;
        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        let (tree, new_lfs) = snapshot_into(&inputs, locked.locked_wc(), &parent_tree)?;
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
                .set_description(description)
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
        #[cfg(target_os = "macos")]
        let _git_lock = crate::colocation::export_git(&mut tx, &name, &inputs.root)?;
        let new_repo = if tx.repo().has_changes() { tx.commit("typewright: commit").block_on()? } else { repo.clone() };
        let id = new_repo.view().get_wc_commit_id(&name).ok_or_else(|| anyhow!("no working-copy commit"))?;
        locked.locked_wc().reset(&new_repo.store().get_commit(id)?).block_on()?;
        locked.finish(new_repo.op_id().clone()).block_on()?;
        self.after_transaction(&repo, &new_repo)?;

        let added = self.add_lfs(new_lfs)?;
        if !added.is_empty() {
            self.write_excludes()?;
        }
        lfs_changed.extend(added);
        lfs_changed.extend(self.record_lfs_versions(message, committed.as_deref())?);
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

    /// Writes `tree` into @ and commits it as `message`, assuming the disk already matches.
    pub(crate) fn commit_tree(&mut self, tree: MergedTree, message: &str) -> Result<Option<String>> {
        let repo = self.head()?;
        let wc = self.wc_commit(&repo)?;
        let name = self.workspace.workspace_name().to_owned();
        let sig = self.signature();
        let description = Self::description_for(&wc, message);
        let parent_tree = wc.parent_tree(repo.as_ref()).block_on()?;
        let mut tx = repo.start_transaction();
        let mut_repo = tx.repo_mut();
        let mut committed = None;
        if tree.tree_ids_and_labels() != parent_tree.tree_ids_and_labels() {
            let done = mut_repo
                .rewrite_commit(&wc)
                .set_tree(tree)
                .set_description(description)
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
        #[cfg(target_os = "macos")]
        let _git_lock = self.export_git(&mut tx)?;
        let new_repo = if tx.repo().has_changes() { tx.commit("typewright: sync").block_on()? } else { repo.clone() };
        let id = new_repo.view().get_wc_commit_id(&name).ok_or_else(|| anyhow!("no working-copy commit"))?;
        let new_wc = new_repo.store().get_commit(id)?;
        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        locked.locked_wc().reset(&new_wc).block_on()?;
        locked.finish(new_repo.op_id().clone()).block_on()?;
        self.after_transaction(&repo, &new_repo)?;
        Ok(committed)
    }
}

pub(crate) struct SnapshotInputs {
    lfs: Vec<RepoPathBuf>,
    ignores: Arc<GitIgnoreFile>,
    limit: u64,
    root: PathBuf,
}

/// Snapshots the disk into `locked`; LFS files (listed, too large, binary) stay out of the tree.
/// `reference` is the tree new files are judged against; returns the tree and newly found LFS paths.
pub(crate) fn snapshot_into(
    inputs: &SnapshotInputs,
    locked: &mut dyn LockedWorkingCopy,
    reference: &MergedTree,
) -> Result<(MergedTree, BTreeSet<RepoPathBuf>)> {
    let not_lfs = DifferenceMatcher::new(EverythingMatcher, FilesMatcher::new(&inputs.lfs));
    let options = SnapshotOptions {
        base_ignores: inputs.ignores.clone(),
        progress: None,
        start_tracking_matcher: &not_lfs,
        force_tracking_matcher: &NothingMatcher,
        max_new_file_size: inputs.limit,
    };
    let (snapshot, stats) = locked.snapshot(&options).block_on()?;
    let mut new_lfs = BTreeSet::new();
    for (path, reason) in &stats.untracked_paths {
        if matches!(reason, UntrackedReason::FileTooLarge { .. }) {
            new_lfs.insert(path.clone());
        }
    }
    // Files that grew past the limit, and binary files (even when the CLI tracked them first), leave the tree.
    let mut untrack = Vec::new();
    for (path, after) in diff_files(reference, &snapshot, &EverythingMatcher)? {
        if let Some(Some(TreeValue::File { .. })) = after.as_resolved() {
            let disk = path.to_fs_path(&inputs.root).map_err(|e| anyhow!("{e}"))?;
            if crate::lfs::is_lfs(&disk, inputs.limit) {
                untrack.push(path);
            }
        }
    }
    if untrack.is_empty() {
        return Ok((snapshot, new_lfs));
    }
    let mut builder = MergedTreeBuilder::new(snapshot);
    for path in untrack {
        builder.set_or_remove(path.clone(), Merge::absent());
        new_lfs.insert(path);
    }
    Ok((builder.write_tree().block_on()?, new_lfs))
}

/// Committed history from @'s first parent down to (excluding) the root, newest first.
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

/// A description without Typewright's trailer, for display.
pub(crate) fn display_description(description: &str) -> String {
    let trimmed = description.trim_end();
    trimmed.strip_suffix(APP_TRAILER).map_or(trimmed, |d| d.trim_end()).to_owned()
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
