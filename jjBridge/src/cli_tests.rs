//! States the jj CLI can leave the repository in, created with the real CLI (skipped when `jj` isn't installed).
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::repo::{Repo, millis};
use crate::retention::Policy;
use crate::tests::setup;

const DAY: i64 = 86_400_000;

fn jj_bin() -> Option<PathBuf> {
    ["/opt/homebrew/bin/jj", "/usr/local/bin/jj"].iter().map(PathBuf::from).find(|p| p.is_file())
}

/// Runs the CLI like a user would, with the test's config root; returns (success, stdout, stderr).
fn jj(dir: &Path, args: &[&str]) -> (bool, String, String) {
    let out = Command::new(jj_bin().unwrap())
        .current_dir(dir)
        .args(args)
        .env("XDG_CONFIG_HOME", setup())
        .env("HOME", setup())
        .env_remove("JJ_CONFIG")
        .env("JJ_USER", "Tester")
        .env("JJ_EMAIL", "tester@example.com")
        .output()
        .unwrap();
    (out.status.success(), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
}

/// Runs the CLI and expects success without stale, lock or missing-config complaints.
fn jj_ok(dir: &Path, args: &[&str]) -> String {
    let (ok, stdout, stderr) = jj(dir, args);
    assert!(ok, "jj {args:?} failed: {stderr}");
    for bad in ["stale", "lock", "Per-repo config not found", "Concurrent"] {
        assert!(!stderr.contains(bad), "jj {args:?} complained ({bad}): {stderr}");
    }
    stdout
}

macro_rules! require_jj {
    () => {
        if jj_bin().is_none() {
            eprintln!("skipped: no jj CLI");
            return;
        }
        setup();
    };
}

fn write(root: &Path, path: &str, text: impl AsRef<[u8]>) {
    let disk = root.join(path);
    fs::create_dir_all(disk.parent().unwrap()).unwrap();
    fs::write(disk, text).unwrap();
}

fn read(root: &Path, path: &str) -> String { fs::read_to_string(root.join(path)).unwrap_or_default() }

fn tracked(root: &Path) -> Vec<String> { jj_ok(root, &["file", "list"]).lines().map(str::to_owned).collect() }

#[cfg(target_os = "macos")]
fn git_ok(root: &Path, args: &[&str]) -> String {
    let out = Command::new("/usr/bin/git").current_dir(root).args(args).output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8(out.stdout).unwrap()
}

#[cfg(target_os = "macos")]
#[test]
fn colocated_git_tracks_app_commits_and_imports_git_changes() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    assert!(root.join(".git").is_dir());
    assert_eq!(git_ok(root, &["rev-parse", "--is-inside-work-tree"]).trim(), "true");
    write(root, "S/a.typ", "one\n");
    let first = repo.commit("First").unwrap().commit.unwrap();
    assert_eq!(git_ok(root, &["rev-parse", "HEAD"]).trim(), first);
    assert!(git_ok(root, &["status", "--porcelain"]).is_empty());
    write(root, "S/a.typ", "two\n");
    repo.working_copy_changes().unwrap();
    assert!(git_ok(root, &["diff", "--", "S/a.typ"]).contains("+two"));

    // Even accidental Git commits must survive the app's next snapshot.
    git_ok(root, &["add", "S/a.typ"]);
    git_ok(root, &["-c", "user.name=Tester", "-c", "user.email=test@example.com", "commit", "-m", "From Git"]);
    let external = git_ok(root, &["rev-parse", "HEAD"]).trim().to_owned();
    write(root, "S/a.typ", "two\nthree\n");
    repo.commit("After Git").unwrap();
    assert_eq!(repo.file_at(&external, "S/a.typ").unwrap()["text"], "two\n");
    assert_eq!(read(root, "S/a.typ"), "two\nthree\n");
    assert!(git_ok(root, &["log", "--format=%s"]).contains("From Git"));
    jj_ok(root, &["st"]);
}

#[cfg(target_os = "macos")]
#[test]
fn opening_migrates_internal_git_without_losing_history_or_sync_refs() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let other = tempfile::tempdir().unwrap();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "one\n");
    let first = repo.commit("First").unwrap().commit.unwrap();
    let manifest = repo.export_node("share", "S").unwrap();
    jj_ok(root, &["workspace", "add", other.path().join("workspace").to_str().unwrap()]);
    drop(repo);
    jj_ok(root, &["git", "colocation", "disable"]);
    assert!(root.join(".jj/repo/store/git").is_dir());

    write(root, "S/a.typ", "one\nunsaved\n");
    let mut repo = Repo::open(root).unwrap();
    assert!(root.join(".git").is_dir());
    assert_eq!(read(root, "S/a.typ"), "one\nunsaved\n");
    assert_eq!(repo.file_at(&first, "S/a.typ").unwrap()["text"], "one\n");
    assert!(git_ok(root, &["show-ref"]).contains(manifest["node"].as_str().unwrap()));
    repo.commit("After migration").unwrap();
    jj_ok(root, &["st"]);
    jj_ok(&other.path().join("workspace"), &["st"]);
    jj_ok(root, &["git", "colocation", "disable"]);
    repo.working_copy_changes().unwrap();
    assert!(root.join(".git").is_dir());
    jj_ok(root, &["st"]);
}

#[test]
fn cli_reads_managed_config_and_ignores_lfs() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    repo.set_lfs_limit(64);
    write(root, "S/a.typ", "text\n");
    write(root, "S/big.txt", "x".repeat(200));
    write(root, "S/pic.png", "small png");
    write(root, "S/.DS_Store", "junk");
    repo.commit("Edit").unwrap();
    assert_eq!(jj_ok(root, &["config", "get", "snapshot.max-new-file-size"]).trim(), "64");
    assert_eq!(jj_ok(root, &["config", "get", "ui.conflict-marker-style"]).trim(), "git");
    let path = jj_ok(root, &["config", "path", "--repo"]);
    let text = fs::read_to_string(path.trim()).unwrap();
    assert_eq!(crate::config::version(&text), crate::config::version(include_str!("repo_config.toml")));
    assert!(jj_ok(root, &["tw-help"]).contains("For people and AI agents"));
    jj_ok(root, &["tw-log"]);
    write(root, "S/old.typ", "old\n");
    repo.commit("Add S/old.typ").unwrap();
    fs::remove_file(root.join("S/old.typ")).unwrap();
    repo.commit("Delete S/old.typ").unwrap();
    let deleted = jj_ok(root, &["tw-deleted", "--no-graph", "-T", "description.first_line() ++ \"\\n\""]);
    assert_eq!(deleted.trim(), "Delete S/old.typ");
    jj_ok(root, &["log", "-r", "tw_autosaves()"]);
    jj_ok(root, &["st"]);
    // New LFS files the app hasn't seen yet stay untracked by the CLI as well.
    write(root, "S/new.pdf", "fresh pdf");
    write(root, "S/huge.txt", "y".repeat(300));
    jj_ok(root, &["st"]);
    assert_eq!(tracked(root), ["S/a.typ"]);
    // The app picks them up as LFS files.
    let c = repo.commit("Edit").unwrap();
    assert_eq!(c.changed, ["S/huge.txt", "S/new.pdf"]);
    assert_eq!(tracked(root), ["S/a.typ"]);

    // An edited config is left alone except for the limit.
    fs::write(path.trim(), format!("{text}\n# mine\n")).unwrap();
    repo.set_lfs_limit(128);
    let edited = fs::read_to_string(path.trim()).unwrap();
    assert!(edited.contains("# mine"));
    assert_eq!(jj_ok(root, &["config", "get", "snapshot.max-new-file-size"]).trim(), "128");
    drop(repo);
    let _repo = Repo::open(root).unwrap();
    assert!(fs::read_to_string(path.trim()).unwrap().contains("# mine"));
}

#[test]
fn concurrent_operations_merge() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "a\n");
    repo.commit("Edit").unwrap();
    let op = jj_ok(root, &["op", "log", "--no-graph", "-n", "1", "-T", "id"]);
    jj_ok(root, &["--at-op", op.trim(), "bookmark", "create", "one", "-r", "@-"]);
    jj_ok(root, &["--at-op", op.trim(), "bookmark", "create", "two", "-r", "@-"]);
    write(root, "S/a.typ", "a\nb\n");
    assert!(repo.commit("Edit").unwrap().commit.is_some());
    let bookmarks = jj_ok(root, &["bookmark", "list"]);
    assert!(bookmarks.contains("one") && bookmarks.contains("two"), "{bookmarks}");
    jj_ok(root, &["st"]);
}

#[test]
fn stale_working_copy_keeps_disk_edits() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "1\n2\n3\n");
    write(root, "S/b.typ", "b1\n");
    let c1 = repo.commit("One").unwrap().commit.unwrap();
    write(root, "S/b.typ", "b2\n");
    repo.commit("Two").unwrap();
    // An edit the app hasn't committed yet, then the CLI moves @ without touching the files.
    write(root, "S/a.typ", "1\n2\n3\nmine\n");
    jj_ok(root, &["--ignore-working-copy", "edit", &c1]);
    repo.commit("Edit").unwrap();
    assert!(repo.wrote_files, "the checkout rewrote b.typ, so editors must reload");
    assert_eq!(read(root, "S/a.typ"), "1\n2\n3\nmine\n");
    assert_eq!(read(root, "S/b.typ"), "b1\n");
    repo.commit("Edit").unwrap();
    assert!(!repo.wrote_files);
    jj_ok(root, &["st"]);

    // The other direction: the repo is rewound under the working copy.
    write(root, "S/c.typ", "c\n");
    repo.commit("Three").unwrap();
    let ops = jj_ok(root, &["op", "log", "--no-graph", "-n", "3", "-T", "id ++ \"\\n\""]);
    let old = ops.lines().nth(2).unwrap();
    jj_ok(root, &["--ignore-working-copy", "op", "restore", old]);
    write(root, "S/c.typ", "c, edited\n");
    repo.commit("Edit").unwrap();
    assert_eq!(read(root, "S/c.typ"), "c, edited\n");
    jj_ok(root, &["st"]);
}

#[test]
fn stale_from_another_workspace() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let root = dir.path();
    let other_ws = other.path().join("ws");
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "1\n2\n");
    repo.commit("One").unwrap();
    jj_ok(root, &["workspace", "add", other_ws.to_str().unwrap()]);
    // Rewrite the app's @- from the other workspace: the app's @ is rebased and its working copy goes stale.
    jj_ok(&other_ws, &["describe", "-r", "default@-", "-m", "described elsewhere"]);
    write(root, "S/a.typ", "1\n2\nmine\n");
    let c = repo.commit("Edit").unwrap();
    assert!(c.commit.is_some());
    assert_eq!(read(root, "S/a.typ"), "1\n2\nmine\n");
    let log = jj_ok(root, &["log", "-r", "::@", "--no-graph", "-T", "description"]);
    assert!(log.contains("described elsewhere"), "{log}");
    jj_ok(root, &["st"]);
    jj_ok(&other_ws, &["st"]);
}

#[test]
fn busy_lock_is_reported() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    let lock = jj_lib::lock::FileLock::lock(root.join(".jj/working_copy/working_copy.lock")).unwrap();
    let err = repo.commit("Edit").err().unwrap();
    assert!(err.chain().any(|c| c.is::<crate::Busy>()));
    drop(lock);
    write(root, "S/a.typ", "a\n");
    assert!(repo.commit("Edit").unwrap().commit.is_some());
}

#[test]
fn moved_working_copy_and_user_descriptions() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "a\n");
    let c1 = repo.commit("One").unwrap().commit.unwrap();
    write(root, "S/b.typ", "b\n");
    let c2 = repo.commit("Two").unwrap().commit.unwrap();
    // @ on an old commit.
    jj_ok(root, &["new", &c1]);
    write(root, "S/c.typ", "c\n");
    let on_old = repo.commit("On old").unwrap().commit.unwrap();
    let parents = jj_ok(root, &["log", "--no-graph", "-r", &on_old, "-T", "parents.map(|p| p.commit_id()).join(\",\")"]);
    assert_eq!(parents.trim(), c1);
    // @ on a merge, with the user's own description.
    jj_ok(root, &["new", &c2, &on_old, "-m", "my merge"]);
    write(root, "S/d.typ", "d\n");
    let merge = repo.commit("Edit").unwrap().commit.unwrap();
    let out = jj_ok(root, &["log", "--no-graph", "-r", &merge, "-T", "description ++ \"|\" ++ parents.len()"]);
    assert_eq!(out.trim(), "my merge\n|2");
    assert_eq!(repo.file_history("S/d.typ", 10).unwrap()[0]["description"], "my merge");
    jj_ok(root, &["st"]);
}

#[test]
fn squash_respects_user_state_and_other_workspaces() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    let day1 = 20_000 * DAY;
    let mut ids = Vec::new();
    for i in 0..6 {
        repo.clock = Some(millis(day1 + i * 3_600_000));
        write(root, "S/f.typ", format!("v{i}\n"));
        ids.push(repo.commit(&format!("c{i}")).unwrap().commit.unwrap());
    }
    repo.clock = None;
    // A bookmark on c1, the user's description on c3, a tag on c4.
    jj_ok(root, &["bookmark", "create", "keep", "-r", &ids[1]]);
    jj_ok(root, &["describe", "-r", &ids[3], "-m", "mine"]);
    let c4 = jj_ok(root, &["log", "--no-graph", "-r", "description(substring:\"c4\")", "-T", "commit_id"]);
    jj_ok(root, &["tag", "set", "v1", "-r", c4.trim()]);
    let other_ws = other.path().join("ws");
    jj_ok(root, &["workspace", "add", other_ws.to_str().unwrap()]);
    write(&other_ws, "S/elsewhere.typ", "uncommitted in the other workspace\n");

    repo.clock = Some(millis(day1 + 30 * DAY));
    // Everything up to the tag is immutable, and c5 alone has nothing to squash with.
    let daily = Policy { last: 0, hourly: 0, daily: -1, weekly: 0, monthly: 0, yearly: 0 };
    assert_eq!(repo.squash(&daily).unwrap().0, 0);
    jj_ok(root, &["tag", "delete", "v1"]);
    let (squashed, _) = repo.squash(&daily).unwrap();
    let log = jj_ok(root, &["log", "--no-graph", "-r", "::@-", "-T", "description.first_line() ++ \"\\n\""]);
    let lines: Vec<&str> = log.lines().filter(|l| !l.is_empty()).collect();
    // c0 alone (c1 has a bookmark), c1 kept, c2 alone (c3 is the user's), mine, c4+c5 squashed.
    assert_eq!(squashed, 1, "{log}");
    assert_eq!(lines, ["c4", "mine", "c2", "c1", "c0"]);
    assert!(jj_ok(root, &["bookmark", "list"]).contains("keep"));
    assert_eq!(read(root, "S/f.typ"), "v5\n");
    // The other workspace was refreshed in place: no update-stale needed, its edit survives.
    let status = jj_ok(&other_ws, &["st"]);
    assert!(status.contains("elsewhere.typ"), "{status}");
    assert!(other_ws.join("S/elsewhere.typ").is_file());
    jj_ok(root, &["st"]);
}

#[test]
fn inherited_conflicts_and_hidden_commits() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/x.typ", "base\n");
    let base = repo.commit("Base").unwrap().commit.unwrap();
    jj_ok(root, &["new", &base, "-m", "left"]);
    write(root, "S/x.typ", "left\n");
    jj_ok(root, &["new", &base, "-m", "right"]);
    write(root, "S/x.typ", "right\n");
    jj_ok(root, &["new", "description(exact:\"left\n\")", "description(exact:\"right\n\")"]);
    assert_eq!(repo.conflicts("").unwrap(), ["S/x.typ"]);
    let conflict = repo.conflict("S/x.typ").unwrap();
    assert_eq!(conflict["hunks"][0]["conflict"]["sides"], serde_json::json!(["left\n", "right\n"]));
    repo.resolve("S/x.typ", Some("both\n"), 0).unwrap();
    assert!(repo.conflicts("").unwrap().is_empty());
    assert_eq!(read(root, "S/x.typ"), "both\n");
    jj_ok(root, &["st"]);

    // Abandoned commits stay readable.
    write(root, "S/y.typ", "y\n");
    let y = repo.commit("Y").unwrap().commit.unwrap();
    jj_ok(root, &["abandon", &y]);
    assert_eq!(repo.file_at(&y, "S/y.typ").unwrap()["text"], "y\n");
}

#[test]
fn undo_keeps_sync_state() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "a\n");
    let manifest = repo.export_node("share", "S").unwrap();
    let node = manifest["node"].as_str().unwrap().to_owned();
    jj_ok(root, &["undo"]);
    jj_ok(root, &["op", "restore", "@--"]);
    assert_eq!(repo.node("share", &node).unwrap()["node"], node.as_str());
    let git_dir = root.join(if cfg!(target_os = "macos") { ".git" } else { ".jj/repo/store/git" });
    let refs = Command::new("git").arg("-C").arg(git_dir).args(["show-ref"]).output();
    if let Ok(refs) = refs {
        assert!(String::from_utf8_lossy(&refs.stdout).contains("refs/typewright/shares/share/head"));
    }
    write(root, "S/a.typ", "a\nb\n");
    assert!(repo.export_node("share", "S").unwrap()["parents"].as_array().unwrap().contains(&serde_json::json!(node)));
}

#[test]
fn forgotten_workspace_and_sparse_patterns() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "a\n");
    write(root, "T/b.typ", "b\n");
    let c = repo.commit("One").unwrap().commit.unwrap();
    jj_ok(root, &["workspace", "forget", "default"]);
    write(root, "S/a.typ", "a2\n");
    let next = repo.commit("Edit").unwrap().commit.unwrap();
    let parent = jj_ok(root, &["log", "--no-graph", "-r", &next, "-T", "parents.map(|p| p.commit_id()).join(\",\")"]);
    assert_eq!(parent.trim(), c);
    assert!(jj_ok(root, &["workspace", "list"]).contains("default"));
    jj_ok(root, &["st"]);

    jj_ok(root, &["sparse", "set", "--clear", "--add", "S"]);
    assert!(!root.join("T/b.typ").exists());
    drop(repo);
    let mut repo = Repo::open(root).unwrap();
    assert_eq!(read(root, "T/b.typ"), "b\n");
    assert_eq!(jj_ok(root, &["sparse", "list"]).trim(), ".");
    assert!(repo.commit("Edit").unwrap().changed.is_empty());
}

#[test]
fn nested_repos_colocation_missing_and_corrupt_jj() {
    require_jj!();
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut repo = Repo::open(root).unwrap();
    write(root, "S/a.typ", "a\n");
    repo.commit("One").unwrap();
    // Nested workspaces and Git metadata never become document history.
    jj_ok(root, &["workspace", "add", "Inner"]);
    let git = Command::new("git").arg("-C").arg(root).args(["init", "-q"]).status();
    write(root, "S/b.typ", "b\n");
    repo.commit("Two").unwrap();
    let files = tracked(root);
    assert!(files.iter().all(|f| !f.starts_with("Inner/") && !f.starts_with(".git")), "{files:?}");
    assert!(files.contains(&"S/b.typ".to_owned()));
    if git.is_ok() {
        jj_ok(root, &["st"]);
    }
    drop(repo);
    // Remove both stores to simulate a completely deleted repository.
    let _ = fs::remove_dir_all(root.join(".git"));
    let _ = fs::remove_dir_all(root.join("Inner"));

    // `.jj` deleted: a new repository tracks the files.
    fs::remove_dir_all(root.join(".jj")).unwrap();
    let mut repo = Repo::open(root).unwrap();
    assert_eq!(repo.commit("Edit").unwrap().changed, ["S/a.typ", "S/b.typ"]);
    drop(repo);

    // `.jj` corrupt: moved aside, files untouched, a fresh repository again.
    fs::write(root.join(".jj/repo/store/type"), "nonsense").unwrap();
    fs::remove_dir_all(root.join(".jj/repo/op_heads")).unwrap();
    let mut repo = Repo::open(root).unwrap();
    let aside = repo.recovered_from.clone().unwrap();
    assert!(aside.file_name().unwrap().to_string_lossy().starts_with(".jj.broken-"));
    assert!(aside.join("repo").is_dir());
    assert_eq!(read(root, "S/a.typ"), "a\n");
    let changed = repo.commit("Edit").unwrap().changed;
    if cfg!(target_os = "macos") {
        assert!(changed.is_empty());
    } else {
        assert_eq!(changed, ["S/a.typ", "S/b.typ"]);
    }
    assert_eq!(tracked(root), ["S/a.typ", "S/b.typ"]);
    jj_ok(root, &["st"]);
}

#[test]
fn workspaces_with_changed_trees_are_reported() {
    require_jj!();
    use std::ffi::{CStr, CString};
    let dir = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let root = dir.path();
    let other_ws = other.path().join("ws");
    let c_root = CString::new(root.to_str().unwrap()).unwrap();
    let repo = unsafe { crate::twj_open(c_root.as_ptr()) };
    write(root, "S/a.typ", "a\n");
    let msg = CString::new("Edit").unwrap();
    unsafe { crate::twj_string_free(crate::twj_commit(repo, msg.as_ptr())) };
    jj_ok(root, &["workspace", "add", other_ws.to_str().unwrap()]);
    // The other workspace builds on the app's @, so the app's next commit changes the tree under it.
    jj_ok(&other_ws, &["new", "default@"]);
    write(root, "S/a.typ", "a\nb\n");
    let out = unsafe { crate::twj_commit(repo, msg.as_ptr()) };
    let value: serde_json::Value = serde_json::from_str(unsafe { CStr::from_ptr(out) }.to_str().unwrap()).unwrap();
    unsafe { crate::twj_string_free(out) };
    assert_eq!(value["staleWorkspaces"], serde_json::json!(["ws"]), "{value}");
    let (_, _, stderr) = jj(&other_ws, &["st"]);
    assert!(stderr.contains("stale"), "{stderr}");
    jj_ok(&other_ws, &["workspace", "update-stale"]);
    assert_eq!(read(&other_ws, "S/a.typ"), "a\nb\n");
    unsafe { crate::twj_close(repo) };
}
