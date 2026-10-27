use std::fs;

use base64::Engine as _;

use crate::Repo;

fn setup() -> (tempfile::TempDir, Repo) {
    crate::tests::setup();
    let dir = tempfile::tempdir().unwrap();
    let mut repo = Repo::open(dir.path()).unwrap();
    repo.set_lfs_limit(16);
    fs::create_dir(dir.path().join("S")).unwrap();
    (dir, repo)
}

#[test]
fn whole_file_versions_survive_reopen_and_restore_without_diffs() {
    let (dir, mut repo) = setup();
    let path = "S/report.docx";
    let file = dir.path().join(path);
    fs::write(&file, b"first\0version").unwrap();
    repo.commit("Add report").unwrap();
    let first = repo.file_history(path, 20).unwrap()[0]["commit"].as_str().unwrap().to_owned();
    fs::write(&file, b"second\0version").unwrap();
    // Watcher snapshots must not consume the change before its history autosave.
    repo.working_copy_changes().unwrap();
    repo.commit("Edit").unwrap();
    assert!(repo.commit("Edit").unwrap().changed.is_empty());
    drop(repo);
    let mut repo = Repo::open(dir.path()).unwrap();
    let history = repo.file_history(path, 20).unwrap();
    assert_eq!(history.as_array().unwrap().len(), 2);
    assert_eq!(history[0]["added"], 0);
    assert_eq!(history[0]["removed"], 0);
    let content = repo.file_at(&first, path).unwrap();
    assert_eq!(base64::engine::general_purpose::STANDARD.decode(content["data"].as_str().unwrap()).unwrap(), b"first\0version");
    fs::write(&file, b"unsaved\0version").unwrap();
    repo.restore_file(&first, path).unwrap();
    assert_eq!(fs::read(&file).unwrap(), b"first\0version");
    assert_eq!(repo.file_history(path, 20).unwrap().as_array().unwrap().len(), 4);
}

#[test]
fn large_text_versions_are_whole_files_and_deletions_remain_restorable() {
    let (dir, mut repo) = setup();
    let path = "S/large.txt";
    fs::write(dir.path().join(path), "x".repeat(100)).unwrap();
    repo.commit("Edit").unwrap();
    let id = repo.file_history(path, 20).unwrap()[0]["commit"].as_str().unwrap().to_owned();
    assert!(repo.file_at(&id, path).unwrap()["data"].is_string());
    fs::remove_file(dir.path().join(path)).unwrap();
    repo.commit("Delete").unwrap();
    let history = repo.file_history(path, 20).unwrap();
    assert_eq!(history[0]["kind"], "deleted");
    assert_eq!(history.as_array().unwrap().len(), 2);
    repo.restore_file(&id, path).unwrap();
    assert_eq!(fs::read_to_string(dir.path().join(path)).unwrap(), "x".repeat(100));
}

#[test]
fn retention_keeps_latest_whole_file_and_collects_unused_objects() {
    let (dir, mut repo) = setup();
    for index in 0..4 {
        fs::write(dir.path().join("S/file.bin"), vec![index; 50]).unwrap();
        repo.commit("Edit").unwrap();
    }
    let policy = crate::retention::Policy { last: 1, hourly: 0, daily: 0, weekly: 0, monthly: 0, yearly: 0 };
    repo.squash(&policy).unwrap();
    let history = repo.file_history("S/file.bin", 20).unwrap();
    assert_eq!(history.as_array().unwrap().len(), 1);
    let objects = fs::read_dir(dir.path().join(".jj/typewright/file-history")).unwrap().count();
    assert_eq!(objects, 1);
}

#[test]
fn renaming_a_whole_file_keeps_its_previous_versions() {
    let (dir, mut repo) = setup();
    fs::write(dir.path().join("S/old.docx"), b"first\0version").unwrap();
    repo.commit("Edit").unwrap();
    fs::write(dir.path().join("S/old.docx"), b"second\0version").unwrap();
    repo.commit("Edit").unwrap();
    fs::rename(dir.path().join("S/old.docx"), dir.path().join("S/new.docx")).unwrap();
    repo.commit("Rename").unwrap();
    let history = repo.file_history("S/new.docx", 20).unwrap();
    assert_eq!(history.as_array().unwrap().len(), 3);
    assert_eq!(history[0]["kind"], "renamed");
    assert_eq!(history[0]["from"], "S/old.docx");
    let original = history[2]["commit"].as_str().unwrap();
    assert!(repo.file_at(original, "S/old.docx").unwrap()["data"].is_string());
}

#[test]
fn growing_text_does_not_appear_as_a_deletion_in_history() {
    let (dir, mut repo) = setup();
    fs::write(dir.path().join("S/text.typ"), "small").unwrap();
    repo.commit("Edit").unwrap();
    fs::write(dir.path().join("S/text.typ"), "big".repeat(100)).unwrap();
    repo.commit("Edit").unwrap();
    let history = repo.file_history("S/text.typ", 20).unwrap();
    assert_eq!(history.as_array().unwrap().len(), 2);
    assert!(history.as_array().unwrap().iter().all(|v| v["kind"] != "deleted"));
}
