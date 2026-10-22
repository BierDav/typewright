use std::path::Path;
use std::sync::Arc;

use futures::AsyncReadExt as _;
use jj_lib::backend::TreeValue;
use jj_lib::config::{ConfigLayer, ConfigSource, StackedConfig};
use jj_lib::gitignore::GitIgnoreFile;
use jj_lib::matchers::{EverythingMatcher, NothingMatcher};
use jj_lib::merge::Merge;
use jj_lib::merged_tree::MergedTree;
use jj_lib::ref_name::WorkspaceName;
use jj_lib::repo::{ReadonlyRepo, Repo as _};
use jj_lib::repo_path::RepoPath;
use jj_lib::settings::UserSettings;
use jj_lib::working_copy::SnapshotOptions;
use jj_lib::default_backend_factories::{default_backend_factories, default_working_copy_factories};
use jj_lib::object_id::ObjectId as _;
use jj_lib::workspace::Workspace;
use pollster::FutureExt as _;

fn settings() -> UserSettings {
    let mut config = StackedConfig::with_defaults();
    config.add_layer(ConfigLayer::parse(ConfigSource::User, "user.name = \"Probe\"\nuser.email = \"probe@example.com\"\n").unwrap());
    UserSettings::from_config_and_home_dir(config, None).unwrap()
}

fn snapshot(ws: &mut Workspace, repo: &Arc<ReadonlyRepo>) -> (Arc<ReadonlyRepo>, MergedTree) {
    let mut locked = ws.start_working_copy_mutation().block_on().unwrap();
    let opts = SnapshotOptions {
        base_ignores: GitIgnoreFile::empty(),
        progress: None,
        start_tracking_matcher: &EverythingMatcher,
        force_tracking_matcher: &NothingMatcher,
        max_new_file_size: 1 << 20,
    };
    let (tree, _stats) = locked.locked_wc().snapshot(&opts).block_on().unwrap();
    let wc_id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).unwrap().clone();
    let wc = repo.store().get_commit(&wc_id).unwrap();
    let mut tx = repo.start_transaction();
    let repo = if wc.tree().tree_ids() != tree.tree_ids() {
        tx.repo_mut().rewrite_commit(&wc).set_tree(tree.clone()).write().block_on().unwrap();
        tx.repo_mut().rebase_descendants().block_on().unwrap();
        tx.commit("snapshot").block_on().unwrap()
    } else {
        repo.clone()
    };
    locked.finish(repo.op_id().clone()).block_on().unwrap();
    (repo, tree)
}

// Describe the working-copy commit and start a new empty one on top (what `jj commit` does).
fn commit(ws: &mut Workspace, repo: &Arc<ReadonlyRepo>, message: &str) -> Arc<ReadonlyRepo> {
    let (repo, _) = snapshot(ws, repo);
    let wc_id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).unwrap().clone();
    let wc = repo.store().get_commit(&wc_id).unwrap();
    let mut tx = repo.start_transaction();
    let done = tx.repo_mut().rewrite_commit(&wc).set_description(message).write().block_on().unwrap();
    tx.repo_mut().rebase_descendants().block_on().unwrap();
    let new_wc = tx.repo_mut().check_out(WorkspaceName::DEFAULT.to_owned(), &done).block_on().unwrap();
    let repo = tx.commit(format!("commit {message}")).block_on().unwrap();
    ws.check_out(repo.op_id().clone(), None, &new_wc).block_on().unwrap();
    repo
}

fn read(tree: &MergedTree, path: &str) -> String {
    let path = RepoPath::from_internal_string(path).unwrap();
    let value = tree.path_value(path).block_on().unwrap();
    match value.into_resolved() {
        Ok(Some(TreeValue::File { id, .. })) => {
            let mut s = String::new();
            tree.store().read_file(path, &id).block_on().unwrap().read_to_string(&mut s).block_on().unwrap();
            s
        }
        Ok(None) => "<missing>".into(),
        Ok(other) => format!("<{other:?}>"),
        Err(conflict) => format!("<conflict with {} sides>", conflict.num_sides()),
    }
}

fn load(settings: &UserSettings, root: &Path) -> (Workspace, Arc<ReadonlyRepo>) {
    let ws = Workspace::load(settings, root, &default_backend_factories(), &default_working_copy_factories()).unwrap();
    let repo = ws.repo_loader().load_at_head().block_on().unwrap();
    (ws, repo)
}

// `bench <root> <files> <commits>`: a space of `files` files in 40 folders, then `commits` commits of 5 edits each.
fn bench(root: &Path, files: usize, commits: usize) {
    let settings = settings();
    let _ = std::fs::remove_dir_all(root);
    std::fs::create_dir_all(root).unwrap();
    let (mut ws, mut repo) = Workspace::init_internal_git(&settings, root, gix::hash::Kind::Sha1).block_on().unwrap();
    let path = |i: usize| root.join(format!("Bench/dir{:02}/file{i:05}.typ", i % 40));
    for d in 0..40 { std::fs::create_dir_all(root.join(format!("Bench/dir{d:02}"))).unwrap(); }
    let t = std::time::Instant::now();
    for i in 0..files { std::fs::write(path(i), format!("= File {i}\n\nSome text for file {i}.\n")).unwrap(); }
    println!("wrote {files} files in {:?}", t.elapsed());
    let t = std::time::Instant::now();
    repo = commit(&mut ws, &repo, "initial");
    println!("initial commit in {:?}", t.elapsed());
    let (mut total, mut max) = (std::time::Duration::ZERO, std::time::Duration::ZERO);
    for c in 1..=commits {
        for k in 0..5 {
            let i = (c * 7919 + k * 104729) % files;
            // Alternate between two same-size texts, so only mtimes reveal most edits.
            std::fs::write(path(i), format!("= File {i}\n\nEdit {} of file {i}.\n", if c % 2 == 0 { "A" } else { "B" })).unwrap();
        }
        let t = std::time::Instant::now();
        repo = commit(&mut ws, &repo, &format!("edit {c}"));
        let d = t.elapsed();
        total += d;
        max = max.max(d);
        if c % 50 == 0 {
            println!("commits {c}: avg {:?} max {:?}", total / 50, max);
            total = std::time::Duration::ZERO;
            max = std::time::Duration::ZERO;
        }
    }
    println!("bench ok");
}

// `verify <root>`: the repo loads, snapshots and its history reads back.
fn verify(root: &Path) {
    let settings = settings();
    let (mut ws, repo) = load(&settings, root);
    let (repo, tree) = snapshot(&mut ws, &repo);
    let wc_id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).unwrap().clone();
    let mut commit = repo.store().get_commit(&wc_id).unwrap();
    let root_id = repo.store().root_commit_id().clone();
    let mut n = 0;
    while commit.id() != &root_id {
        n += 1;
        commit = repo.store().get_commit(&commit.parent_ids()[0]).unwrap();
    }
    println!("verify ok: {n} commits, file00000 = {:?}", read(&tree, "Bench/dir00/file00000.typ").lines().nth(2));
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("bench") => return bench(Path::new(&args[2]), args[3].parse().unwrap(), args[4].parse().unwrap()),
        Some("verify") => return verify(Path::new(&args[2])),
        _ => {}
    }
    let root = Path::new(std::env::args().nth(1).as_deref().unwrap_or("/work/repo")).to_owned();
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let t0 = std::time::Instant::now();
    let settings = settings();
    let (mut ws, repo) = Workspace::init_internal_git(&settings, &root, gix::hash::Kind::Sha1).block_on().unwrap();
    println!("init ok ({:?})", t0.elapsed());

    std::fs::create_dir_all(root.join("Thesis")).unwrap();
    std::fs::write(root.join("Thesis/main.typ"), "line 1\nline 2\nline 3\nline 4\nline 5\n").unwrap();
    std::fs::write(root.join("Thesis/refs.bib"), "@book{x}\n").unwrap();
    let repo = commit(&mut ws, &repo, "first");
    std::fs::write(root.join("Thesis/main.typ"), "line 1 edited\nline 2\nline 3\nline 4\nline 5\n").unwrap();
    let repo = commit(&mut ws, &repo, "second");
    // Same size as before, so only the mtime tells the snapshot that it changed.
    std::fs::write(root.join("Thesis/main.typ"), "line 1 EDITED\nline 2\nline 3\nline 4\nline 5\n").unwrap();
    let repo = commit(&mut ws, &repo, "third");
    println!("commits ok ({:?})", t0.elapsed());

    // History of Thesis/main.typ: walk first parents from the working-copy commit.
    let wc_id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).unwrap().clone();
    let mut commit = repo.store().get_commit(&wc_id).unwrap();
    let root_id = repo.store().root_commit_id().clone();
    let mut versions = vec![];
    while commit.id() != &root_id {
        versions.push((commit.id().hex()[..12].to_owned(), commit.description().to_owned(), commit.committer().timestamp.timestamp.0, read(&commit.tree(), "Thesis/main.typ")));
        commit = repo.store().get_commit(&commit.parent_ids()[0]).unwrap();
    }
    for v in &versions { println!("history {v:?}"); }
    assert_eq!(versions.len(), 4);
    assert_eq!(versions[1].3, "line 1 EDITED\nline 2\nline 3\nline 4\nline 5\n");

    // 3-way merge: base = "first", side A edits lines 4-5, side B edits line 1 → clean; A and C both edit line 4 → conflict.
    let mut first = repo.store().get_commit(&wc_id).unwrap();
    for _ in 0..3 { first = repo.store().get_commit(&first.parent_ids()[0]).unwrap(); }
    let base = first.tree();
    let side = |ws: &mut Workspace, repo: &Arc<ReadonlyRepo>, text: &str| {
        std::fs::write(root.join("Thesis/main.typ"), text).unwrap();
        snapshot(ws, repo)
    };
    let (repo, a) = side(&mut ws, &repo, "line 1\nline 2\nline 3\nline 4 from A\nline 5 from A\n");
    let (repo, b) = side(&mut ws, &repo, "line 1 from B\nline 2\nline 3\nline 4\nline 5\n");
    let clean = MergedTree::merge(Merge::from_vec(vec![(a.clone(), "A".into()), (base.clone(), "base".into()), (b.clone(), "B".into())])).block_on().unwrap();
    println!("clean merge: {:?}", read(&clean, "Thesis/main.typ"));
    assert_eq!(read(&clean, "Thesis/main.typ"), "line 1 from B\nline 2\nline 3\nline 4 from A\nline 5 from A\n");
    let (repo, c) = side(&mut ws, &repo, "line 1\nline 2\nline 3\nline 4 from C\nline 5\n");
    let conflicted = MergedTree::merge(Merge::from_vec(vec![(a, "A".into()), (base, "base".into()), (c, "C".into())])).block_on().unwrap();
    println!("conflicting merge: {} has_conflict={}", read(&conflicted, "Thesis/main.typ"), conflicted.has_conflict());

    // Put the conflict into the working copy and check it out (writes conflict markers to disk).
    let wc_id = repo.view().get_wc_commit_id(WorkspaceName::DEFAULT).unwrap().clone();
    let wc = repo.store().get_commit(&wc_id).unwrap();
    let mut tx = repo.start_transaction();
    let merged = tx.repo_mut().rewrite_commit(&wc).set_tree(conflicted).write().block_on().unwrap();
    tx.repo_mut().rebase_descendants().block_on().unwrap();
    let repo = tx.commit("merge").block_on().unwrap();
    ws.check_out(repo.op_id().clone(), None, &merged).block_on().unwrap();
    println!("on disk after conflict checkout:\n{}", std::fs::read_to_string(root.join("Thesis/main.typ")).unwrap());

    // Reload from disk to prove persistence.
    drop(ws);
    let ws = Workspace::load(&settings, &root, &default_backend_factories(), &default_working_copy_factories()).unwrap();
    let repo = ws.repo_loader().load_at_head().block_on().unwrap();
    println!("reloaded at op {} with {} heads; total {:?}", &repo.op_id().hex()[..12], repo.view().heads().len(), t0.elapsed());
}
