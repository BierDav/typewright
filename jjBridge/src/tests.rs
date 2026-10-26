use std::fs;
use std::path::Path;

use serde_json::Value;

use crate::repo::{Repo, millis};
use crate::retention::Policy;

const DAY: i64 = 86_400_000;

/// Keeps jj's config root (the managed repo config) out of the real home.
pub(crate) fn setup() -> &'static Path {
    static ROOT: std::sync::OnceLock<tempfile::TempDir> = std::sync::OnceLock::new();
    ROOT.get_or_init(|| {
        let dir = tempfile::tempdir().unwrap();
        // SAFETY: runs once, before any test reads the environment through the bridge.
        unsafe { std::env::set_var("XDG_CONFIG_HOME", dir.path()) };
        dir
    })
    .path()
}

fn open(dir: &Path) -> Repo {
    setup();
    Repo::open(dir).unwrap()
}

fn write(repo: &Repo, path: &str, text: impl AsRef<[u8]>) {
    let disk = repo.root().join(path);
    fs::create_dir_all(disk.parent().unwrap()).unwrap();
    fs::write(disk, text).unwrap();
}

fn read(repo: &Repo, path: &str) -> String { fs::read_to_string(repo.root().join(path)).unwrap() }

fn strs(value: &Value) -> Vec<String> {
    value.as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_owned()).collect()
}

/// Sends `share` from `from` (at `from_path`) to `to` (at `to_path`) the way the sync engine will.
fn send(from: &mut Repo, from_path: &str, to: &mut Repo, to_path: &str, label: &str) -> (Value, Value) {
    let manifest = from.export_node("share", from_path).unwrap();
    let merged = deliver(from, from_path, &manifest, to, to_path, label, &[]).unwrap();
    (manifest, merged)
}

/// Hands an exported `manifest` over to `to` and merges it there, keeping `keep` as it is.
fn deliver(
    from: &Repo,
    from_path: &str,
    manifest: &Value,
    to: &mut Repo,
    to_path: &str,
    label: &str,
    keep: &[String],
) -> anyhow::Result<Value> {
    let wire = tempfile::tempdir().unwrap();
    let missing = to.missing_objects(&manifest.to_string()).unwrap();
    from.write_objects(&missing.to_string(), wire.path().to_str().unwrap()).unwrap();
    let lfs = tempfile::tempdir().unwrap();
    for (rel, file) in manifest["files"].as_object().unwrap() {
        if file["lfs"].as_bool() == Some(true) {
            let source = if rel == crate::nodes::FILE_ENTRY { from_path.to_owned() } else { format!("{from_path}/{rel}") };
            fs::copy(from.root().join(source), lfs.path().join(file["blake3"].as_str().unwrap())).unwrap();
        }
    }
    let imported = to.import_node("share", &manifest.to_string(), wire.path().to_str().unwrap(), label).unwrap();
    assert_eq!(imported["node"], manifest["node"]);
    to.merge_node("share", to_path, manifest["node"].as_str().unwrap(), lfs.path().to_str().unwrap(), keep)
}

/// Two repos syncing `S` (on a) as `Joined` (on b), in sync.
fn synced_pair(text: &str) -> (tempfile::TempDir, Repo, tempfile::TempDir, Repo) {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) = (open(da.path()), open(db.path()));
    write(&a, "S/main.typ", text);
    write(&a, "S/other.typ", "other\n");
    send(&mut a, "S", &mut b, "Joined", "A");
    (da, a, db, b)
}

#[test]
fn a_peer_takes_the_resolution_of_a_conflict_it_has_too() {
    let (_da, mut a, _db, mut b) = synced_pair("1\n2\n3\n");
    write(&a, "S/main.typ", "1\n2 (a)\n3\n");
    write(&b, "Joined/main.typ", "1\n2 (b)\n3\n");
    let a_node = a.export_node("share", "S").unwrap();
    let b_node = b.export_node("share", "Joined").unwrap();
    // Both devices merge the other's node and both end up conflicted.
    let at_b = deliver(&a, "S", &a_node, &mut b, "Joined", "A", &[]).unwrap();
    let at_a = deliver(&b, "Joined", &b_node, &mut a, "S", "B", &[]).unwrap();
    assert!(at_b["node"].is_null() && at_a["node"].is_null());
    assert_eq!(a.conflicts("").unwrap(), ["S/main.typ"]);
    // Another unrelated node can't merge while the conflict waits.
    write(&b, "Mine/x.typ", "x\n");
    // b resolves; a takes b's resolution instead of asking its user again.
    b.resolve("Joined/main.typ", Some("1\n2 (both)\n3\n"), 0).unwrap();
    let resolved = b.export_node("share", "Joined").unwrap();
    let taken = deliver(&b, "Joined", &resolved, &mut a, "S", "B", &[]).unwrap();
    assert_eq!(taken["node"], resolved["node"]);
    assert!(a.conflicts("").unwrap().is_empty());
    assert_eq!(read(&a, "S/main.typ"), "1\n2 (both)\n3\n");
    let again = a.export_node("share", "S").unwrap();
    assert_eq!(again["unchanged"], true);
    assert_eq!(again["node"], resolved["node"]);
}

#[test]
fn a_conflicted_share_refuses_nodes_that_dont_resolve_it() {
    let (_da, mut a, _db, mut b) = synced_pair("1\n2\n3\n");
    write(&a, "S/main.typ", "1\n2 (a)\n3\n");
    write(&b, "Joined/main.typ", "1\n2 (b)\n3\n");
    let a_node = a.export_node("share", "S").unwrap();
    deliver(&a, "S", &a_node, &mut b, "Joined", "A", &[]).unwrap();
    write(&a, "S/other.typ", "other, edited\n");
    let next = a.export_node("share", "S").unwrap();
    assert!(deliver(&a, "S", &next, &mut b, "Joined", "A", &[]).is_err());
    assert_eq!(b.conflicts("").unwrap(), ["Joined/main.typ"]);
}

#[test]
fn live_files_keep_their_local_content() {
    let (_da, mut a, _db, mut b) = synced_pair("1\n2\n3\n");
    // The live session already gave b a newer version than a's last commit.
    write(&a, "S/main.typ", "1\n2 typing\n3\n");
    write(&a, "S/other.typ", "other (a)\n");
    write(&b, "Joined/main.typ", "1\n2 typing more\n3\n");
    let a_node = a.export_node("share", "S").unwrap();
    let keep = vec!["Joined/main.typ".to_owned()];
    let merged = deliver(&a, "S", &a_node, &mut b, "Joined", "A", &keep).unwrap();
    assert!(merged["node"].is_string(), "{merged}");
    assert!(strs(&merged["conflicts"]).is_empty());
    assert!(!strs(&merged["changed"]).contains(&"Joined/main.typ".to_owned()));
    assert_eq!(read(&b, "Joined/main.typ"), "1\n2 typing more\n3\n");
    assert_eq!(read(&b, "Joined/other.typ"), "other (a)\n");
    // The conflict resolved to b's side, so the merge node already holds b's live content.
    let next = b.export_node("share", "Joined").unwrap();
    assert_eq!(next["node"], merged["node"]);
    assert_eq!(next["unchanged"], true);
    // Later nodes leave a kept file alone too.
    write(&a, "S/main.typ", "1\n2 typing more\n3 (a)\n");
    let ff = a.export_node("share", "S").unwrap();
    let at_b = deliver(&a, "S", &ff, &mut b, "Joined", "A", &keep).unwrap();
    assert!(strs(&at_b["conflicts"]).is_empty());
    assert_eq!(read(&b, "Joined/main.typ"), "1\n2 typing more\n3\n");
    let next = b.export_node("share", "Joined").unwrap();
    assert!(!next["files"]["main.typ"]["oid"].is_null());
    assert_eq!(read(&b, "Joined/main.typ"), "1\n2 typing more\n3\n");
}

#[test]
fn commit_and_noop() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    write(&repo, "Thesis/main.typ", "= Hello\n");
    write(&repo, "Thesis/.DS_Store", "junk");
    let c = repo.commit("Edit").unwrap();
    assert!(c.commit.is_some());
    assert_eq!(c.changed, vec!["Thesis/main.typ"]);
    let again = repo.commit("Edit").unwrap();
    assert!(again.commit.is_none());
    assert!(again.changed.is_empty());
    // Reopening finds the same repository.
    drop(repo);
    let mut repo = open(dir.path());
    assert!(repo.commit("Edit").unwrap().commit.is_none());
    write(&repo, "Thesis/main.typ", "= Hello\nWorld\n");
    assert_eq!(repo.commit("Edit").unwrap().changed, vec!["Thesis/main.typ"]);
}

#[test]
fn history_rename_file_at_restore() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    write(&repo, "A/a.typ", "one\n");
    let first = repo.commit("First").unwrap().commit.unwrap();
    write(&repo, "A/a.typ", "one\ntwo\nthree\n");
    repo.commit("Second").unwrap();
    fs::rename(repo.root().join("A/a.typ"), repo.root().join("A/b.typ")).unwrap();
    repo.commit("Rename").unwrap();
    write(&repo, "A/b.typ", "one\nTWO\nthree\n");
    repo.commit("Fourth").unwrap();

    let history = repo.file_history("A/b.typ", 100).unwrap();
    let kinds: Vec<&str> = history.as_array().unwrap().iter().map(|v| v["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["modified", "renamed", "modified", "added"]);
    assert_eq!(history[0]["added"], 1);
    assert_eq!(history[0]["removed"], 1);
    assert_eq!(history[1]["from"], "A/a.typ");
    assert_eq!(history[2]["added"], 2);
    assert_eq!(history[3]["description"], "First");
    assert_eq!(repo.file_history("A/b.typ", 2).unwrap().as_array().unwrap().len(), 2);

    assert_eq!(repo.file_at(&first, "A/a.typ").unwrap()["text"], "one\n");
    assert_eq!(repo.file_at(&first, "A/b.typ").unwrap()["missing"], true);
    write(&repo, "A/pic.bin", [0u8, 1, 2]);
    let restored = repo.restore_file(&first, "A/a.typ").unwrap();
    assert!(restored["commit"].is_string());
    assert_eq!(read(&repo, "A/a.typ"), "one\n");
    assert_eq!(repo.file_history("A/a.typ", 10).unwrap()[0]["description"], "Restore A/a.typ");
}

#[test]
fn default_policy_thins_out_and_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    let start = 20_000 * DAY;
    // 300 autosaves over 30 days.
    for i in 0..300 {
        repo.clock = Some(millis(start + i * (DAY / 10)));
        write(&repo, "S/f.typ", format!("v{i}\n"));
        repo.commit("Autosave").unwrap();
    }
    let policy = Policy::default();
    let (squashed, kept) = repo.squash(&policy).unwrap();
    // 100 last, then 48 hours reaching back ~5 days (one commit each), then a few remaining days, weeks, the month.
    assert_eq!(squashed + kept, 300);
    assert!((100 + 48..200).contains(&kept), "{kept}");
    assert_eq!(repo.squash(&policy).unwrap(), (0, kept));
    let history = repo.file_history("S/f.typ", 1000).unwrap();
    assert_eq!(history.as_array().unwrap().len(), kept);
    // The newest version is untouched and each kept commit is still an exact snapshot.
    assert_eq!(repo.file_at(history[0]["commit"].as_str().unwrap(), "S/f.typ").unwrap()["text"], "v299\n");
    assert_eq!(repo.file_at(history[99]["commit"].as_str().unwrap(), "S/f.typ").unwrap()["text"], "v200\n");
    assert_eq!(history[150]["description"], "Autosave");
    assert_eq!(read(&repo, "S/f.typ"), "v299\n");
}

#[test]
fn squash_by_policy() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    let day1 = 20_000 * DAY;
    let times = [day1 + 3_600_000, day1 + 7_200_000, day1 + 10_800_000, day1 + DAY, day1 + DAY + 60_000, day1 + 9 * DAY];
    for (i, t) in times.iter().enumerate() {
        repo.clock = Some(millis(*t));
        write(&repo, "S/f.typ", format!("v{i}\n"));
        write(&repo, &format!("S/{i}.typ"), "x");
        repo.commit(&format!("c{i}")).unwrap();
    }
    repo.clock = Some(millis(day1 + 10 * DAY));
    let daily = Policy { last: 1, hourly: 0, daily: -1, weekly: 0, monthly: 0, yearly: 0 };
    assert_eq!(repo.squash(&daily).unwrap(), (3, 3));
    let history = repo.file_history("S/f.typ", 100).unwrap();
    let descriptions: Vec<&str> = history.as_array().unwrap().iter().map(|v| v["description"].as_str().unwrap()).collect();
    assert_eq!(descriptions, ["c5", "c3\nc4", "c0\nc1\nc2"]);
    // The squashed commit keeps the day's last content.
    let day = history[2]["commit"].as_str().unwrap();
    assert_eq!(repo.file_at(day, "S/f.typ").unwrap()["text"], "v2\n");
    assert_eq!(repo.file_at(day, "S/1.typ").unwrap()["text"], "x");
    assert_eq!(read(&repo, "S/f.typ"), "v5\n");
    assert_eq!(repo.squash(&daily).unwrap(), (0, 3));
    // The working copy still works after the rewrite.
    write(&repo, "S/f.typ", "v6\n");
    assert!(repo.commit("after").unwrap().commit.is_some());
}

#[test]
fn utc_offset_makes_days_local() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    // UTC+2: 21:30 UTC is still day 1 locally, 22:30 and 23:00 UTC are day 2.
    repo.set_utc_offset(120);
    let day1 = 20_000 * DAY;
    let hour = 3_600_000;
    for (i, t) in [day1 + 43 * hour / 2, day1 + 45 * hour / 2, day1 + 23 * hour, day1 + 3 * DAY].iter().enumerate() {
        repo.clock = Some(millis(*t));
        write(&repo, "S/f.typ", format!("v{i}\n"));
        repo.commit(&format!("c{i}")).unwrap();
    }
    let head = repo.head().unwrap();
    let wc = repo.wc_commit(&head).unwrap();
    let parent = jj_lib::repo::Repo::store(head.as_ref()).get_commit(&wc.parent_ids()[0]).unwrap();
    assert_eq!(parent.author().timestamp.tz_offset, 120);
    let daily = Policy { last: 1, hourly: 0, daily: -1, weekly: 0, monthly: 0, yearly: 0 };
    // In UTC the first three would share a day and two would go.
    assert_eq!(repo.squash(&daily).unwrap(), (1, 3));
}

#[test]
fn lfs_files_stay_out_of_history() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    repo.set_lfs_limit(100);
    write(&repo, "S/small.typ", "small\n");
    write(&repo, "S/big.txt", "x".repeat(200));
    write(&repo, "S/blob.dat", [b'a', 0, b'b']);
    write(&repo, "S/photo.png", "not really a png");
    let c = repo.commit("Edit").unwrap();
    assert_eq!(c.changed, vec!["S/big.txt", "S/blob.dat", "S/photo.png", "S/small.typ"]);
    let commit = c.commit.unwrap();
    assert_eq!(repo.file_at(&commit, "S/small.typ").unwrap()["text"], "small\n");
    for path in ["S/big.txt", "S/blob.dat", "S/photo.png"] {
        assert_eq!(repo.file_at(&commit, path).unwrap()["missing"], true, "{path}");
    }
    // A tracked file growing past the limit leaves the tree.
    write(&repo, "S/small.typ", "y".repeat(300));
    let grown = repo.commit("Grow").unwrap();
    assert_eq!(grown.changed, vec!["S/small.typ"]);
    assert_eq!(repo.file_at(&grown.commit.unwrap(), "S/small.typ").unwrap()["missing"], true);
    write(&repo, "S/small.typ", "z".repeat(400));
    let again = repo.commit("Grow more").unwrap();
    assert!(again.commit.is_none());
    assert_eq!(again.changed, vec!["S/small.typ"]);
    // Shrinking back below the limit makes it a text file again.
    write(&repo, "S/big.txt", "short\n");
    let shrunk = repo.commit("Shrink").unwrap();
    assert_eq!(repo.file_at(&shrunk.commit.unwrap(), "S/big.txt").unwrap()["text"], "short\n");
    assert!(repo.commit("noop").unwrap().changed.is_empty());
}

#[test]
fn nodes_are_deterministic_across_repos() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) = (open(da.path()), open(db.path()));
    a.set_lfs_limit(64);
    b.set_lfs_limit(64);
    for repo in [&a, &b] {
        write(repo, "S/main.typ", "= Title\n");
        write(repo, "S/sub/part.typ", "part\n");
        write(repo, "S/data.bin", [0u8; 10]);
    }
    write(&a, "Private/secret.typ", "only a\n");
    b.clock = Some(millis(5 * DAY));
    let (na, nb) = (a.export_node("share", "S").unwrap(), b.export_node("other", "S").unwrap());
    assert_eq!(na["tree"], nb["tree"]);
    // LFS times come from the files' mtimes, so equal content written at different times differs only there.
    let lfs_a = &na["files"]["data.bin"];
    assert_eq!(lfs_a["lfs"], true);
    assert_eq!(lfs_a["blake3"], nb["files"]["data.bin"]["blake3"]);
    assert!(na["files"]["main.typ"]["oid"].is_string());
    assert!(na["files"].get("secret.typ").is_none());
    assert_eq!(a.export_node("share", "S").unwrap()["unchanged"], true);

    // Without LFS files the ids match exactly.
    let (dc, dd) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut c, mut d) = (open(dc.path()), open(dd.path()));
    write(&c, "X/a.typ", "a\n");
    write(&d, "Elsewhere/a.typ", "a\n");
    write(&c, "Y/one.typ", "same\n");
    write(&d, "Z/renamed.typ", "same\n");
    assert_eq!(c.export_node("s", "X").unwrap()["node"], d.export_node("s", "Elsewhere").unwrap()["node"]);
    assert_eq!(c.export_node("f", "Y/one.typ").unwrap()["node"], d.export_node("f", "Z/renamed.typ").unwrap()["node"]);
}

#[test]
fn sync_round_trip() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) = (open(da.path()), open(db.path()));
    a.set_lfs_limit(64);
    b.set_lfs_limit(64);
    write(&a, "S/main.typ", "line 1\nline 2\nline 3\n");
    write(&a, "S/old.typ", "old\n");
    write(&a, "S/img.png", "fake image");
    write(&b, "Mine/keep.typ", "b's own\n");

    // First sync into an empty destination.
    let (m1, r1) = send(&mut a, "S", &mut b, "Joined", "A");
    assert_eq!(r1["node"], m1["node"]);
    assert_eq!(read(&b, "Joined/main.typ"), "line 1\nline 2\nline 3\n");
    assert_eq!(read(&b, "Joined/img.png"), "fake image");
    assert_eq!(b.export_node("share", "Joined").unwrap()["unchanged"], true);
    assert!(b.missing_objects(&m1.to_string()).unwrap().as_array().unwrap().is_empty());

    // Edits on both sides in different places, plus a deletion, merge cleanly and converge.
    write(&a, "S/main.typ", "line 1 (a)\nline 2\nline 3\n");
    fs::remove_file(a.root().join("S/old.typ")).unwrap();
    write(&b, "Joined/main.typ", "line 1\nline 2\nline 3 (b)\n");
    write(&b, "Joined/new.typ", "from b\n");
    let (_, rb) = send(&mut a, "S", &mut b, "Joined", "A");
    assert!(rb["node"].is_string());
    assert!(strs(&rb["conflicts"]).is_empty());
    assert_eq!(read(&b, "Joined/main.typ"), "line 1 (a)\nline 2\nline 3 (b)\n");
    assert!(!b.root().join("Joined/old.typ").exists());
    let (mb, ra) = send(&mut b, "Joined", &mut a, "S", "B");
    assert_eq!(mb["node"], rb["node"]);
    assert_eq!(ra["node"], rb["node"]);
    assert_eq!(read(&a, "S/new.typ"), "from b\n");
    assert_eq!(a.export_node("share", "S").unwrap()["node"], rb["node"]);
    assert_eq!(a.export_node("share", "S").unwrap()["unchanged"], true);

    // Concurrent merges of the same two nodes compute the same merge node.
    write(&a, "S/main.typ", "line 1 (a)\nline 2 (a)\nline 3 (b)\n");
    write(&b, "Joined/new.typ", "from b, again\n");
    let na = a.export_node("share", "S").unwrap();
    let nb = b.export_node("share", "Joined").unwrap();
    let (_, at_b) = send(&mut a, "S", &mut b, "Joined", "A");
    let (_, at_a) = send(&mut b, "Joined", &mut a, "S", "B");
    assert_ne!(na["node"], nb["node"]);
    assert_eq!(at_a["node"], at_b["node"]);

    // Same line on both sides: a conflict in the working copy, resolved once, published with both parents.
    write(&a, "S/main.typ", "line 1 (a)\nline 2 (from a)\nline 3 (b)\n");
    write(&b, "Joined/main.typ", "line 1 (a)\nline 2 (from b)\nline 3 (b)\n");
    let a_node = a.export_node("share", "S").unwrap();
    let b_node = b.export_node("share", "Joined").unwrap();
    let (_, conflicted) = send(&mut a, "S", &mut b, "Joined", "Laptop");
    assert!(conflicted["node"].is_null());
    assert_eq!(strs(&conflicted["conflicts"]), ["Joined/main.typ"]);
    assert_eq!(b.conflicts("").unwrap(), ["Joined/main.typ"]);
    assert_eq!(b.conflicts("Mine").unwrap(), Vec::<String>::new());
    assert!(read(&b, "Joined/main.typ").contains("<<<<<<<"));
    // Committing again keeps the conflict while the markers are untouched.
    write(&b, "Mine/keep.typ", "b's own, edited\n");
    b.commit("Edit").unwrap();
    assert_eq!(b.conflicts("").unwrap(), ["Joined/main.typ"]);
    assert!(b.export_node("share", "Joined").is_err());
    let conflict = b.conflict("Joined/main.typ").unwrap();
    assert_eq!(conflict["binary"], false);
    assert_eq!(conflict["sides"], serde_json::json!([crate::nodes::local_label(), "Laptop"]));
    let hunks = conflict["hunks"].as_array().unwrap();
    assert_eq!(hunks[0]["text"], "line 1 (a)\n");
    assert_eq!(hunks[1]["conflict"]["base"], "line 2 (a)\n");
    assert_eq!(hunks[1]["conflict"]["sides"], serde_json::json!(["line 2 (from b)\n", "line 2 (from a)\n"]));
    assert_eq!(hunks[2]["text"], "line 3 (b)\n");
    let resolved = b.resolve("Joined/main.typ", Some("line 1 (a)\nline 2 (both)\nline 3 (b)\n"), 0).unwrap();
    assert!(resolved["commit"].is_string());
    assert!(b.conflicts("").unwrap().is_empty());
    let published = b.export_node("share", "Joined").unwrap();
    let mut parents = vec![a_node["node"].clone(), b_node["node"].clone()];
    parents.sort_by_key(|v| v.as_str().unwrap().to_owned());
    assert_eq!(published["parents"], Value::Array(parents));
    let (_, at_a) = send(&mut b, "Joined", &mut a, "S", "B");
    assert_eq!(at_a["node"], published["node"]);
    assert_eq!(read(&a, "S/main.typ"), "line 1 (a)\nline 2 (both)\nline 3 (b)\n");

    // LFS files: concurrent changes keep the newest and a conflict copy, on both devices alike.
    write(&a, "S/img.png", "image from a");
    write(&b, "Joined/img.png", "image from b, later");
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(100);
    fs::File::options().write(true).open(b.root().join("Joined/img.png")).unwrap().set_modified(later).unwrap();
    a.export_node("share", "S").unwrap();
    b.export_node("share", "Joined").unwrap();
    let (_, at_b) = send(&mut a, "S", &mut b, "Joined", "A");
    let (_, at_a) = send(&mut b, "Joined", &mut a, "S", "B");
    assert_eq!(at_a["node"], at_b["node"]);
    for (repo, path) in [(&a, "S"), (&b, "Joined")] {
        assert_eq!(read(repo, &format!("{path}/img.png")), "image from b, later");
        assert_eq!(read(repo, &format!("{path}/img (conflict).png")), "image from a");
    }
    assert_eq!(a.export_node("share", "S").unwrap()["unchanged"], true);
    assert_eq!(b.export_node("share", "Joined").unwrap()["unchanged"], true);
    // b's own space never travelled.
    assert!(!a.root().join("Mine").exists());
}

#[test]
fn file_share_and_binary_resolve() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (mut a, mut b) = (open(da.path()), open(db.path()));
    write(&a, "Thesis/notes.typ", "notes\n");
    write(&a, "Thesis/other.typ", "not shared\n");
    let (m, r) = send(&mut a, "Thesis/notes.typ", &mut b, "Inbox/from a.typ", "A");
    assert_eq!(r["node"], m["node"]);
    assert_eq!(m["files"].as_object().unwrap().keys().collect::<Vec<_>>(), [crate::nodes::FILE_ENTRY]);
    assert_eq!(read(&b, "Inbox/from a.typ"), "notes\n");
    assert!(!b.root().join("Inbox/other.typ").exists());
    write(&b, "Inbox/from a.typ", "notes\nmore\n");
    let (_, back) = send(&mut b, "Inbox/from a.typ", &mut a, "Thesis/notes.typ", "B");
    assert!(back["node"].is_string());
    assert_eq!(read(&a, "Thesis/notes.typ"), "notes\nmore\n");
    // Concurrent edits of the whole file conflict; resolving by side writes that side.
    write(&a, "Thesis/notes.typ", "a's version\n");
    write(&b, "Inbox/from a.typ", "b's version\n");
    b.export_node("share", "Inbox/from a.typ").unwrap();
    let (_, conflicted) = send(&mut a, "Thesis/notes.typ", &mut b, "Inbox/from a.typ", "A");
    assert_eq!(strs(&conflicted["conflicts"]), ["Inbox/from a.typ"]);
    b.resolve("Inbox/from a.typ", None, 1).unwrap();
    assert_eq!(read(&b, "Inbox/from a.typ"), "a's version\n");
    assert!(b.conflicts("").unwrap().is_empty());
}

#[test]
fn conflict_names() {
    assert_eq!(crate::nodes::test_conflict_name("S/img.png"), "S/img (conflict).png");
    assert_eq!(crate::nodes::test_conflict_name("S/.env"), "S/.env (conflict)");
    assert_eq!(crate::nodes::test_conflict_name("Makefile"), "Makefile (conflict)");
}

#[test]
fn ffi_json_and_git_validity() {
    use std::ffi::{CStr, CString};
    setup();
    let dir = tempfile::tempdir().unwrap();
    let c = |s: &str| CString::new(s).unwrap();
    let take = |ptr: *mut std::ffi::c_char| -> Value {
        let value = serde_json::from_str(unsafe { CStr::from_ptr(ptr) }.to_str().unwrap()).unwrap();
        unsafe { crate::twj_string_free(ptr) };
        value
    };
    let root = c(dir.path().to_str().unwrap());
    let repo = unsafe { crate::twj_open(root.as_ptr()) };
    assert!(!repo.is_null());
    fs::create_dir_all(dir.path().join("S")).unwrap();
    fs::write(dir.path().join("S/a.typ"), "a\n").unwrap();
    let committed = take(unsafe { crate::twj_commit(repo, c("Edit").as_ptr()) });
    assert_eq!(committed["changed"], serde_json::json!(["S/a.typ"]));
    let bad = take(unsafe { crate::twj_file_history(repo, c("../etc").as_ptr(), 10) });
    assert!(bad["error"].is_string());
    let manifest = take(unsafe { crate::twj_export_node(repo, c("share").as_ptr(), c("S").as_ptr()) });
    let node = take(unsafe { crate::twj_node(repo, c("share").as_ptr(), c(manifest["node"].as_str().unwrap()).as_ptr()) });
    assert_eq!(node["tree"], manifest["tree"]);
    let resolved = take(unsafe { crate::twj_resolve(repo, c("S/a.typ").as_ptr(), std::ptr::null(), 0) });
    assert!(resolved["error"].as_str().unwrap().contains("no conflict"));
    unsafe { crate::twj_close(repo) };
    // The node is a valid git commit, reachable from its ref.
    let git = dir.path().join(if cfg!(target_os = "macos") { ".git" } else { ".jj/repo/store/git" });
    if let Ok(out) = std::process::Command::new("git").arg("-C").arg(&git).args(["fsck", "--strict"]).output() {
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let show = std::process::Command::new("git")
            .arg("-C")
            .arg(&git)
            .args(["cat-file", "-p", "refs/typewright/shares/share/head"])
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&show.stdout);
        assert!(text.contains("author Typewright Sync <sync@typewright.invalid> 1767225600 +0000"), "{text}");
    }
}

#[test]
fn exclude_patterns_are_escaped() {
    assert_eq!(crate::config::test_pattern("S/a[1]*.png"), "/S/a\\[1\\]\\*.png");
    assert_eq!(crate::config::test_pattern("S/#x !y "), "/S/\\#x \\!y\\ ");
}

fn paths(value: &Value) -> Vec<(String, String)> {
    value.as_array().unwrap().iter().map(|v| (v["path"].as_str().unwrap().to_owned(), v["kind"].as_str().unwrap().to_owned())).collect()
}

#[test]
fn recently_deleted_groups_folders_and_dedups() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    write(&repo, "S/main.typ", "main\n");
    write(&repo, "S/notes.typ", "notes v1\n");
    write(&repo, "S/figs/a.typ", "a\n");
    write(&repo, "S/figs/sub/b.typ", "b\n");
    write(&repo, "T/x.typ", "x\n");
    repo.commit("Add").unwrap();
    // notes: deleted, restored, edited, deleted again; only the last deletion counts.
    fs::remove_file(repo.root().join("S/notes.typ")).unwrap();
    repo.commit("Delete S/notes.typ").unwrap();
    write(&repo, "S/notes.typ", "notes v2\n");
    repo.commit("Restore").unwrap();
    fs::remove_file(repo.root().join("S/notes.typ")).unwrap();
    repo.commit("Delete S/notes.typ").unwrap();
    // A whole folder in one commit is one entry.
    fs::remove_dir_all(repo.root().join("S/figs")).unwrap();
    repo.commit("Delete S/figs").unwrap();
    // A whole space too.
    fs::remove_dir_all(repo.root().join("T")).unwrap();
    repo.commit("Delete T").unwrap();

    let all = repo.deleted("", 50).unwrap();
    assert_eq!(paths(&all), [("T".into(), "folder".into()), ("S/figs".into(), "folder".into()), ("S/notes.typ".into(), "file".into())]);
    assert_eq!(all[1]["files"], 2);
    assert_eq!(all[2]["description"], "Delete S/notes.typ");
    let notes = all[2].clone();
    assert_eq!(repo.file_at(notes["lastCommit"].as_str().unwrap(), "S/notes.typ").unwrap()["text"], "notes v2\n");
    // Scoped to a folder.
    assert_eq!(paths(&repo.deleted("S", 50).unwrap()).len(), 2);
    assert_eq!(paths(&repo.deleted("S", 1).unwrap()).len(), 1);

    // Restoring a folder brings all its files back and drops it from the list.
    let restored = repo.restore_deleted(&all[1].to_string(), "S/figs").unwrap();
    assert_eq!(restored["files"], 2);
    assert_eq!(read(&repo, "S/figs/sub/b.typ"), "b\n");
    assert_eq!(paths(&repo.deleted("", 50).unwrap()).len(), 2);
    // Something at the destination is never overwritten; another name works.
    write(&repo, "S/notes.typ", "new\n");
    assert_eq!(repo.restore_deleted(&notes.to_string(), "S/notes.typ").unwrap()["exists"], true);
    repo.restore_deleted(&notes.to_string(), "S/notes 2.typ").unwrap();
    assert_eq!(read(&repo, "S/notes 2.typ"), "notes v2\n");
    assert_eq!(read(&repo, "S/notes.typ"), "new\n");
    // A file that exists again isn't listed.
    assert!(paths(&repo.deleted("", 50).unwrap()).iter().all(|(p, _)| p != "S/notes.typ"));
}

#[test]
fn delete_commits_and_stashes_lfs_files() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    write(&repo, "S/main.typ", "main\n");
    write(&repo, "S/fig/plot.png", [0x89, b'P', b'N', b'G', 0, 1, 2]);
    write(&repo, "S/fig/plot.typ", "plot\n");
    write(&repo, "S/photo.jpg", "jpeg bytes");
    repo.commit("Add").unwrap();
    // An unsaved edit goes into the history before the deletion.
    write(&repo, "S/fig/plot.typ", "plot v2\n");
    let result = repo.delete(&["S/fig".into(), "S/photo.jpg".into()], "Delete S/fig and S/photo.jpg").unwrap();
    assert!(result["commit"].is_string());
    assert!(!repo.root().join("S/fig").exists());
    let entries = result["deleted"].as_array().unwrap();
    assert!(entries[0]["stash"].is_string() && entries[1]["stash"].is_string());
    // Both show up: the folder through jj with its stash, the LFS-only file through the stash alone.
    let deleted = repo.deleted("S", 10).unwrap();
    let mut listed = paths(&deleted);
    listed.sort();
    assert_eq!(listed, [("S/fig".into(), "folder".into()), ("S/photo.jpg".into(), "file".into())]);
    // Undo with the entries `delete` returned.
    repo.restore_deleted(&entries[0].to_string(), "S/fig").unwrap();
    assert_eq!(read(&repo, "S/fig/plot.typ"), "plot v2\n");
    assert_eq!(fs::read(repo.root().join("S/fig/plot.png")).unwrap(), [0x89, b'P', b'N', b'G', 0, 1, 2]);
    let photo = repo.deleted("S", 10).unwrap()[0].clone();
    assert_eq!(photo["path"], "S/photo.jpg");
    repo.restore_deleted(&photo.to_string(), "S/photo.jpg").unwrap();
    assert_eq!(read(&repo, "S/photo.jpg"), "jpeg bytes");
    assert!(repo.deleted("S", 10).unwrap().as_array().unwrap().is_empty());
    assert!(repo.commit("Edit").unwrap().commit.is_none());
}

#[test]
fn renames_are_not_deletions() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    write(&repo, "S/a.typ", "a\n");
    write(&repo, "S/dir/b.typ", "b\n");
    repo.commit("Add").unwrap();
    fs::rename(repo.root().join("S/a.typ"), repo.root().join("S/c.typ")).unwrap();
    fs::rename(repo.root().join("S/dir"), repo.root().join("S/moved")).unwrap();
    repo.commit("Rename").unwrap();
    assert!(repo.deleted("", 10).unwrap().as_array().unwrap().is_empty());
}

#[test]
fn deleting_the_last_file_of_a_folder_lists_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    write(&repo, "S/ch/one.typ", "one\n");
    repo.commit("Add").unwrap();
    repo.delete(&["S/ch/one.typ".into()], "Delete S/ch/one.typ").unwrap();
    // The folder stays on disk (empty), so the file is what was deleted.
    assert!(repo.root().join("S/ch").is_dir());
    assert_eq!(paths(&repo.deleted("S", 10).unwrap()), [("S/ch/one.typ".into(), "file".into())]);
}

#[test]
fn recently_deleted_survives_squashing() {
    let dir = tempfile::tempdir().unwrap();
    let mut repo = open(dir.path());
    let start = 20_000 * DAY;
    repo.clock = Some(millis(start));
    write(&repo, "S/gone.typ", "bye\n");
    write(&repo, "S/f.typ", "v\n");
    repo.commit("Add").unwrap();
    for i in 0..20 {
        repo.clock = Some(millis(start + DAY + (i + 1) * 60_000));
        write(&repo, "S/f.typ", format!("v{i}\n"));
        if i == 5 {
            fs::remove_file(repo.root().join("S/gone.typ")).unwrap();
        }
        repo.commit("Autosave").unwrap();
    }
    // The day of the deletion collapses to one commit; the file's deletion is part of it.
    let policy = Policy { last: 1, hourly: 0, daily: -1, weekly: 0, monthly: 0, yearly: 0 };
    let (squashed, _) = repo.squash(&policy).unwrap();
    assert!(squashed > 0);
    let deleted = repo.deleted("", 10).unwrap();
    assert_eq!(paths(&deleted), [("S/gone.typ".into(), "file".into())]);
    let last = deleted[0]["lastCommit"].as_str().unwrap();
    assert_eq!(repo.file_at(last, "S/gone.typ").unwrap()["text"], "bye\n");
}

#[test]
fn deletions_from_sync_show_in_recently_deleted() {
    let (_da, mut a, _db, mut b) = synced_pair("main\n");
    write(&a, "S/photo.jpg", "jpeg bytes");
    a.commit("Add photo").unwrap();
    send(&mut a, "S", &mut b, "Joined", "A");
    assert_eq!(read(&b, "Joined/photo.jpg"), "jpeg bytes");
    // A deletes a text file and an LFS file; B's merge removes both without a trash.
    a.delete(&["S/other.typ".into(), "S/photo.jpg".into()], "Delete").unwrap();
    let (_, merged) = send(&mut a, "S", &mut b, "Joined", "A");
    assert!(merged["node"].is_string(), "{merged}");
    assert!(!b.root().join("Joined/other.typ").exists() && !b.root().join("Joined/photo.jpg").exists());
    let deleted = b.deleted("Joined", 10).unwrap();
    let mut listed = paths(&deleted);
    listed.sort();
    assert_eq!(listed, [("Joined/other.typ".into(), "file".into()), ("Joined/photo.jpg".into(), "file".into())]);
    for entry in deleted.as_array().unwrap() {
        b.restore_deleted(&entry.to_string(), entry["path"].as_str().unwrap()).unwrap();
    }
    assert_eq!(read(&b, "Joined/other.typ"), "other\n");
    assert_eq!(read(&b, "Joined/photo.jpg"), "jpeg bytes");
}
