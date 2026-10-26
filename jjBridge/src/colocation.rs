use std::fs;
use std::path::Path;
use std::sync::Arc;

use anyhow::{Context as _, Result, anyhow, bail};
use jj_lib::git::{self, GitImportOptions};
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::transaction::Transaction;
use pollster::FutureExt as _;

use crate::Repo;

// A marker lets startup finish a migration interrupted between the move and git_target update.
pub(crate) fn ensure_layout(root: &Path) -> Result<()> {
    let store = root.join(".jj/repo/store");
    let marker = root.join(".jj/typewright/colocating");
    let target = store.join("git_target");
    let internal = store.join("git");
    let dot_git = root.join(".git");
    if !marker.exists() && fs::read_to_string(&target).ok().as_deref() != Some("git") {
        return Ok(());
    }
    let _git_lock = jj_lib::lock::FileLock::try_lock(root.join(".jj/repo/git_import_export.lock"))?
        .ok_or(crate::Busy)?;
    let _lock = jj_lib::lock::FileLock::try_lock(root.join(".jj/working_copy/working_copy.lock"))?
        .ok_or(crate::Busy)?;
    if !marker.exists() {
        if fs::symlink_metadata(&dot_git).is_ok() {
            bail!("cannot colocate Typewright history: {} already exists", dot_git.display());
        }
        fs::create_dir_all(marker.parent().unwrap())?;
        fs::write(&marker, b"")?;
    }
    if !dot_git.exists() {
        fs::rename(&internal, &dot_git).context("move Typewright's Git store to .git")?;
    }
    let config_path = dot_git.join("config");
    let mut config = gix::config::File::from_path_no_includes(config_path, gix::config::Source::Local)
        .map_err(|e| anyhow!("read Git config: {e}"))?;
    config.set_raw_value("core.bare", "false").map_err(|e| anyhow!("set core.bare: {e}"))?;
    git::save_git_config(&config)?;
    crate::fsutil::write_atomic(&target, b"../../../.git", false)?;
    fs::remove_file(marker)?;
    Ok(())
}

impl Repo {
    pub(crate) fn import_git(&mut self, repo: Arc<ReadonlyRepo>) -> Result<Arc<ReadonlyRepo>> {
        let _lock = jj_lib::lock::FileLock::try_lock(self.workspace.repo_path().join("git_import_export.lock"))?
            .ok_or(crate::Busy)?;
        let name = self.workspace.workspace_name().to_owned();
        let root = self.root().to_owned();
        let mut tx = repo.start_transaction();
        git::import_head(tx.repo_mut(), &name, &root).block_on()?;
        let head_changed = repo.view().git_head(&name) != tx.repo().view().git_head(&name);
        let mut new_wc = None;
        if head_changed && let Some(id) = tx.repo().view().git_head(&name).as_normal().cloned() {
            let commit = tx.repo().store().get_commit(&id)?;
            new_wc = Some(tx.repo_mut().check_out(name, &commit).block_on()?);
        }
        // Git refs protect user commits; importing never abandons Typewright's history.
        git::import_refs(tx.repo_mut(), &GitImportOptions {
            abandon_unreachable_commits: false,
            record_synthetic_predecessors: false,
            remote_auto_track_bookmarks: Default::default(),
        }).block_on()?;
        tx.repo_mut().rebase_descendants().block_on()?;
        if !tx.repo().has_changes() { return Ok(repo); }
        if let Some(wc) = new_wc {
            let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
            // Git already changed the files; only move jj's recorded baseline.
            locked.locked_wc().reset(&wc).block_on()?;
            let updated = tx.commit("typewright: import git").block_on()?;
            locked.finish(updated.op_id().clone()).block_on()?;
            Ok(updated)
        } else {
            Ok(tx.commit("typewright: import git refs").block_on()?)
        }
    }

    pub(crate) fn export_git(&self, tx: &mut Transaction) -> Result<jj_lib::lock::FileLock> {
        export_git(tx, self.workspace.workspace_name(), self.root())
    }
}

pub(crate) fn export_git(tx: &mut Transaction, name: &jj_lib::ref_name::WorkspaceName, root: &Path) -> Result<jj_lib::lock::FileLock> {
    let lock = jj_lib::lock::FileLock::try_lock(root.join(".jj/repo/git_import_export.lock"))?
        .ok_or(crate::Busy)?;
    let id = tx.repo().view().get_wc_commit_id(name).context("no working-copy commit")?;
    let wc = tx.repo().store().get_commit(id)?;
    git::reset_head(tx.repo_mut(), name, root, &wc).block_on()?;
    git::export_refs(tx.repo_mut())?;
    // Keep Git HEAD and jj's recorded HEAD consistent until the caller commits its transaction.
    Ok(lock)
}

#[cfg(test)]
mod tests {
    use super::*;
    use jj_lib::workspace::Workspace;

    fn internal(root: &Path) {
        crate::tests::setup();
        let settings = crate::repo::settings_with(None).unwrap();
        Workspace::init_internal_git(&settings, root, gix::hash::Kind::Sha1).block_on().unwrap();
    }

    #[test]
    fn startup_finishes_an_interrupted_migration() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        internal(root);
        fs::create_dir_all(root.join(".jj/typewright")).unwrap();
        fs::write(root.join(".jj/typewright/colocating"), "").unwrap();
        fs::rename(root.join(".jj/repo/store/git"), root.join(".git")).unwrap();
        let mut repo = Repo::open(root).unwrap();
        assert!(repo.recovered_from.is_none());
        assert_eq!(fs::read_to_string(root.join(".jj/repo/store/git_target")).unwrap(), "../../../.git");
        assert!(!root.join(".jj/typewright/colocating").exists());
        assert!(repo.commit("Check").unwrap().changed.is_empty());
    }

    #[test]
    fn migration_preserves_an_unrelated_git_directory() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        internal(root);
        fs::create_dir(root.join(".git")).unwrap();
        fs::write(root.join(".git/keep"), "unrelated").unwrap();
        assert!(Repo::open(root).err().unwrap().to_string().contains("already exists"));
        assert_eq!(fs::read_to_string(root.join(".git/keep")).unwrap(), "unrelated");
        assert!(root.join(".jj/repo/store/git/objects").is_dir());
        assert!(!root.join(".jj/typewright/colocating").exists());
    }
}
