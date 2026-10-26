//! Immediate working-copy changes without ending the autosave change.
use std::collections::BTreeMap;

use anyhow::Result;
use futures::StreamExt as _;
use jj_lib::backend::MergedTreeValue;
use jj_lib::matchers::EverythingMatcher;
use jj_lib::repo::Repo as _;
use pollster::FutureExt as _;
use serde_json::{Value, json};

use crate::repo::{Repo, diff_files, repo_path, snapshot_into};

fn absent(value: &MergedTreeValue) -> bool { matches!(value.as_resolved(), Some(None)) }

impl Repo {
    pub fn working_copy_changes(&mut self) -> Result<Value> {
        let mut lfs_changed = self.refresh_lfs()?;
        self.write_excludes()?;
        let repo = self.prepare()?;
        let wc = self.wc_commit(&repo)?;
        let before = self.watched_commit.clone().unwrap_or_else(|| wc.clone());
        #[cfg(target_os = "macos")]
        let name = self.workspace.workspace_name().to_owned();
        #[cfg(target_os = "macos")]
        let root = self.root().to_owned();
        let inputs = self.snapshot_inputs()?;
        let mut locked = self.workspace.start_working_copy_mutation().block_on()?;
        let (tree, new_lfs) = snapshot_into(&inputs, locked.locked_wc(), &wc.tree())?;
        let mut tx = repo.start_transaction();
        let current = if tree.tree_ids_and_labels() == wc.tree().tree_ids_and_labels() {
            wc
        } else {
            let current = tx.repo_mut().rewrite_commit(&wc).set_tree(tree.clone()).write().block_on()?;
            tx.repo_mut().rebase_descendants().block_on()?;
            current
        };
        #[cfg(target_os = "macos")]
        let _git_lock = crate::colocation::export_git(&mut tx, &name, &root)?;
        let new_repo = if tx.repo().has_changes() { tx.commit("snapshot external changes").block_on()? } else { repo.clone() };
        locked.locked_wc().reset(&current).block_on()?;
        locked.finish(new_repo.op_id().clone()).block_on()?;
        self.after_transaction(&repo, &new_repo)?;
        lfs_changed.extend(self.add_lfs(new_lfs)?);
        self.write_excludes()?;
        self.save_state()?;

        let changes = diff_files(&before.tree(), &tree, &EverythingMatcher)?;
        let mut paths: Vec<String> = changes.iter().map(|(p, _)| p.as_internal_file_string().to_owned()).collect();
        paths.extend(lfs_changed);
        paths.sort();
        paths.dedup();
        let mut moves = BTreeMap::new();
        let mut records = new_repo.store().backend().get_copy_records(None, before.id(), current.id())?;
        while let Some(record) = records.next().block_on() {
            let record = record?;
            if absent(&tree.path_value(&record.source).block_on()?) {
                moves.insert(record.source.as_internal_file_string().to_owned(), record.target.as_internal_file_string().to_owned());
            }
        }
        // jj tracks files; lift a complete subtree move to its folder or space.
        let mut folders = BTreeMap::new();
        for (from, to) in &moves {
            let (mut from, mut to) = (from.as_str(), to.as_str());
            while let (Some((old_parent, old_name)), Some((new_parent, new_name))) = (from.rsplit_once('/'), to.rsplit_once('/')) {
                if old_name != new_name { break; }
                from = old_parent;
                to = new_parent;
                if from == to { continue; }
                if !absent(&tree.path_value(&repo_path(from)?).block_on()?)
                    || !absent(&before.tree().path_value(&repo_path(to)?).block_on()?) {
                    continue;
                }
                let prefix = format!("{from}/");
                let complete = changes.iter().filter(|(p, value)| absent(value) && p.as_internal_file_string().starts_with(&prefix))
                    .all(|(p, _)| {
                        let path = p.as_internal_file_string();
                        moves.get(path).is_some_and(|target| target == &format!("{to}/{}", &path[prefix.len()..]))
                    });
                if complete { folders.insert(from.to_owned(), to.to_owned()); }
            }
        }
        moves.extend(folders);
        let renamed: Vec<Value> = moves.iter().filter(|(from, to)| {
            !moves.iter().any(|(parent, target)| *from != parent && from.starts_with(&format!("{parent}/"))
                && **to == format!("{target}{}", &from[parent.len()..]))
        }).map(|(from, to)| json!({"from": from, "to": to})).collect();
        self.watched_commit = Some(current);
        Ok(json!({"changed": paths, "renamed": renamed}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use jj_lib::object_id::ObjectId as _;

    fn setup() -> (tempfile::TempDir, Repo) {
        crate::tests::setup();
        let dir = tempfile::tempdir().unwrap();
        let repo = Repo::open(dir.path()).unwrap();
        (dir, repo)
    }

    #[test]
    fn working_copy_changes_detects_renames_without_finishing_autosave() {
        let (dir, mut repo) = setup();
        fs::create_dir(dir.path().join("Space")).unwrap();
        fs::write(dir.path().join("Space/main.typ"), "one\ntwo\nthree\nfour\nfive\n").unwrap();
        repo.commit("Initial").unwrap();
        repo.working_copy_changes().unwrap();
        let before_history = repo.file_history("Space/main.typ", 20).unwrap();
        fs::rename(dir.path().join("Space/main.typ"), dir.path().join("Space/renamed.typ")).unwrap();
        fs::write(dir.path().join("Space/renamed.typ"), "one\ntwo\nthree\nfour\nchanged\n").unwrap();
        let changes = repo.working_copy_changes().unwrap();
        assert_eq!(changes["renamed"], json!([{"from": "Space/main.typ", "to": "Space/renamed.typ"}]));
        assert!(repo.working_copy_changes().unwrap()["changed"].as_array().unwrap().is_empty());
        let head = repo.head().unwrap();
        let wc = repo.wc_commit(&head).unwrap();
        assert!(wc.description().is_empty());
        let parent = head.store().get_commit(&wc.parent_ids()[0]).unwrap();
        assert_eq!(parent.id().hex(), before_history[0]["commit"].as_str().unwrap());
        assert!(repo.commit("Edit").unwrap().commit.is_some());
    }

    #[test]
    fn working_copy_changes_lifts_folder_and_space_moves() {
        let (dir, mut repo) = setup();
        fs::create_dir_all(dir.path().join("Space/chapters")).unwrap();
        fs::write(dir.path().join("Space/chapters/one.typ"), "= One").unwrap();
        fs::write(dir.path().join("Space/main.typ"), "= Main").unwrap();
        repo.commit("Initial").unwrap();
        repo.working_copy_changes().unwrap();
        fs::rename(dir.path().join("Space/chapters"), dir.path().join("Space/sections")).unwrap();
        assert_eq!(repo.working_copy_changes().unwrap()["renamed"], json!([{"from": "Space/chapters", "to": "Space/sections"}]));
        fs::rename(dir.path().join("Space"), dir.path().join("Renamed")).unwrap();
        assert_eq!(repo.working_copy_changes().unwrap()["renamed"], json!([{"from": "Space", "to": "Renamed"}]));
    }

    #[test]
    fn working_copy_changes_does_not_treat_a_copy_as_a_move() {
        let (dir, mut repo) = setup();
        fs::write(dir.path().join("a.typ"), "= Same").unwrap();
        repo.commit("Initial").unwrap();
        repo.working_copy_changes().unwrap();
        fs::copy(dir.path().join("a.typ"), dir.path().join("b.typ")).unwrap();
        assert!(repo.working_copy_changes().unwrap()["renamed"].as_array().unwrap().is_empty());
    }
}
