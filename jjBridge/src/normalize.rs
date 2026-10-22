//! Brings the repository into a state the app can work with, whatever the jj CLI left behind: concurrent operations,
//! a held lock, a stale or forgotten working copy, narrowed sparse patterns; and keeps other workspaces fresh.
use std::path::Path;
use std::sync::Arc;

use anyhow::{Result, anyhow};
use jj_lib::backend::CommitId;
use jj_lib::merge::Merge;
use jj_lib::merged_tree::MergedTree;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPathBuf;
use jj_lib::working_copy::{WorkingCopyFreshness, create_and_check_out_recovery_commit};
use jj_lib::workspace::Workspace;
use pollster::FutureExt as _;

use crate::history::commit_id;
use crate::repo::{Repo, load_workspace, snapshot_into};

const RECOVERY_DESCRIPTION: &str = "Recovered by Typewright

The working copy was at an operation that no longer exists, so its parents are unknown; this commit holds the files
as they were on disk.
";

/// Waits briefly for another process's working-copy lock; `Busy` if it stays held.
#[cfg(not(target_os = "wasi"))]
fn wait_for_lock(workspace_root: &Path) -> Result<()> {
    let path = workspace_root.join(".jj/working_copy/working_copy.lock");
    for _ in 0..20 {
        match jj_lib::lock::FileLock::try_lock(path.clone()) {
            Ok(Some(_lock)) => return Ok(()),
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(100)),
            // A missing state folder isn't a lock; loading reports the real problem.
            Err(_) => return Ok(()),
        }
    }
    Err(crate::repo::Busy.into())
}

#[cfg(target_os = "wasi")]
fn wait_for_lock(_workspace_root: &Path) -> Result<()> { Ok(()) }

impl Repo {
    /// Loads at head (merging concurrent operations) and makes our working copy fresh. Never loses disk content:
    /// the disk is snapshotted before anything is checked out.
    pub(crate) fn prepare(&mut self) -> Result<Arc<ReadonlyRepo>> {
        self.stale_workspaces.clear();
        wait_for_lock(self.root())?;
        let mut repo = self.head()?;
        let name = self.workspace.workspace_name().to_owned();
        let inputs = self.snapshot_inputs()?;
        let sig = self.signature();
        let wc_parents = self.state.wc_parents.clone();
        let before = repo.clone();
        let workspace_store = self.workspace.repo_loader().workspace_store().clone();
        let workspace_root = self.workspace.workspace_root().to_owned();

        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        let root_only = vec![RepoPathBuf::root()];
        if locked.locked_wc().sparse_patterns()? != root_only.as_slice() {
            // Narrowed with `jj sparse`: bring everything back.
            locked.locked_wc().set_sparse_patterns(root_only).block_on()?;
        }

        if repo.view().get_wc_commit_id(&name).is_none() {
            // `jj workspace forget`: recreate our @ where it was, holding what the working copy last recorded.
            let old_tree = locked.locked_wc().old_tree().clone();
            let store = repo.store().clone();
            let mut parents: Vec<CommitId> = wc_parents
                .iter()
                .filter_map(|p| commit_id(p).ok())
                .filter(|id| store.get_commit(id).is_ok())
                .collect();
            if parents.is_empty() {
                parents.push(store.root_commit_id().clone());
            }
            let mut tx = repo.start_transaction();
            let wc = tx.repo_mut().new_commit(parents, old_tree).write().block_on()?;
            tx.repo_mut().set_wc_commit(name.clone(), wc.id().clone())?;
            repo = tx.commit("typewright: recreate workspace").block_on()?;
            if workspace_store.get_workspace_path(&name).ok().flatten().is_none() {
                let _ = workspace_store.add(&name, &workspace_root);
            }
        }

        let wc_id = repo.view().get_wc_commit_id(&name).cloned().ok_or_else(|| anyhow!("no working-copy commit"))?;
        let wc = repo.store().get_commit(&wc_id)?;
        let freshness = WorkingCopyFreshness::check_stale(locked.locked_wc(), &wc, &repo).block_on();
        match freshness {
            Ok(WorkingCopyFreshness::Fresh) | Ok(WorkingCopyFreshness::Updated(_)) => {}
            Ok(WorkingCopyFreshness::WorkingCopyStale) | Ok(WorkingCopyFreshness::SiblingOperation) => {
                // Like `jj workspace update-stale`, but the disk's edits are carried onto the current @.
                let old_tree = locked.locked_wc().old_tree().clone();
                let (disk, _) = snapshot_into(&inputs, locked.locked_wc(), &old_tree)?;
                let mut target = wc.clone();
                if disk.tree_ids_and_labels() != old_tree.tree_ids_and_labels() {
                    let merged = MergedTree::merge(Merge::from_vec(vec![
                        (wc.tree(), "current @".to_owned()),
                        (old_tree, "last checkout".to_owned()),
                        (disk.clone(), "disk".to_owned()),
                    ]))
                    .block_on()?;
                    // Where both changed, the disk wins; the other side stays in @'s previous version.
                    let merged = if merged.has_conflict() {
                        let mut builder = jj_lib::merged_tree_builder::MergedTreeBuilder::new(merged.clone());
                        for (path, _) in merged.conflicts() {
                            let value = disk.path_value(&path).block_on()?;
                            builder.set_or_remove(path, value);
                        }
                        builder.write_tree().block_on()?
                    } else {
                        merged
                    };
                    let mut tx = repo.start_transaction();
                    target = tx.repo_mut().rewrite_commit(&wc).set_tree(merged).set_committer(sig).write().block_on()?;
                    tx.repo_mut().rebase_descendants().block_on()?;
                    repo = tx.commit("typewright: refresh working copy").block_on()?;
                }
                locked.locked_wc().check_out(&target).block_on()?;
            }
            Err(_) => {
                // The working copy's operation is gone: jj's recovery commit keeps the disk as it is.
                let (new_repo, _) = create_and_check_out_recovery_commit(
                    locked.locked_wc(),
                    &repo,
                    name.clone(),
                    RECOVERY_DESCRIPTION,
                )
                .block_on()?;
                repo = new_repo;
            }
        }
        locked.finish(repo.op_id().clone()).block_on()?;
        self.after_transaction(&before, &repo)?;
        Ok(repo)
    }

    /// Records where @ sits and refreshes other workspaces whose @ a transaction rewrote.
    pub(crate) fn after_transaction(&mut self, before: &ReadonlyRepo, after: &Arc<ReadonlyRepo>) -> Result<()> {
        let ours = self.workspace.workspace_name().to_owned();
        if let Some(id) = after.view().get_wc_commit_id(&ours) {
            let parents: Vec<String> = after.store().get_commit(id)?.parent_ids().iter().map(|p| p.hex()).collect();
            if parents != self.state.wc_parents {
                self.state.wc_parents = parents;
                self.save_state()?;
            }
        }
        for (name, new_id) in after.view().wc_commit_ids() {
            if *name == ours || before.view().get_wc_commit_id(name) == Some(new_id) {
                continue;
            }
            if !self.refresh_workspace(name, new_id, after).unwrap_or(false) && !self.stale_workspaces.contains(&name.as_str().to_owned()) {
                self.stale_workspaces.push(name.as_str().to_owned());
            }
        }
        Ok(())
    }

    /// Moves another workspace's state to its rewritten @ without writing files, if its recorded tree still matches.
    fn refresh_workspace(&self, name: &jj_lib::ref_name::WorkspaceName, new_id: &CommitId, repo: &Arc<ReadonlyRepo>) -> Result<bool> {
        let Some(path) = self.workspace.repo_loader().workspace_store().get_workspace_path(name)? else { return Ok(false) };
        if !path.join(".jj/working_copy").is_dir() || wait_for_lock(&path).is_err() {
            return Ok(false);
        }
        let mut workspace: Workspace = load_workspace(&self.settings, &path)?;
        if workspace.workspace_name() != name {
            return Ok(false);
        }
        // Its own store: trees of different store instances can't be diffed.
        let commit = workspace.repo_loader().store().get_commit(new_id)?;
        let mut locked = workspace.start_working_copy_mutation().block_on()?;
        if locked.locked_wc().old_tree().tree_ids_and_labels() != commit.tree().tree_ids_and_labels() {
            return Ok(false);
        }
        locked.locked_wc().reset(&commit).block_on()?;
        locked.finish(repo.op_id().clone()).block_on()?;
        Ok(true)
    }
}
