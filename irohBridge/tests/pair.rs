//! Devices over the real n0 relays: a share reaches a second device of the account, or another account by invite,
//! and so do the heads published for it, with their LFS files. Needs network; run with `cargo test -- --ignored`.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    sync::{Mutex, mpsc},
    time::{Duration, Instant},
};

use iroh_bridge::*;

extern "C" fn on_event(context: *mut c_void, event: *const c_char) {
    let tx = unsafe { &*(context as *const Mutex<mpsc::Sender<serde_json::Value>>) };
    let text = unsafe { CStr::from_ptr(event) }.to_string_lossy();
    let _ = tx.lock().unwrap().send(serde_json::from_str(&text).unwrap());
}

struct Device {
    node: *mut TWSyncNode,
    events: mpsc::Receiver<serde_json::Value>,
}

fn device(dir: &std::path::Path, account: &[u8; 32]) -> Device {
    let (tx, events) = mpsc::channel();
    let context = Box::into_raw(Box::new(Mutex::new(tx))) as *mut c_void;
    let dir = CString::new(dir.to_str().unwrap()).unwrap();
    let node = unsafe { tws_start(dir.as_ptr(), account.as_ptr(), on_event, context) };
    if node.is_null() {
        panic!("start failed: {:?}", events.try_recv());
    }
    Device { node, events }
}

fn wait(device: &Device, what: &str, matches: impl Fn(&serde_json::Value) -> bool) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(120);
    while Instant::now() < deadline {
        if let Ok(event) = device.events.recv_timeout(Duration::from_secs(1)) {
            if event["type"] == "error" || std::env::var("TWS_DEBUG").is_ok() {
                eprintln!("{what}: {event}");
            }
            if matches(&event) {
                return event;
            }
        }
    }
    panic!("timed out waiting for {what}");
}

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn hash(path: &std::path::Path) -> String {
    let raw = unsafe { tws_hash_file(c(path.to_str().unwrap()).as_ptr()) };
    let text = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_string();
    unsafe { tws_string_free(raw) };
    text
}

/// Publishes a node the way the app does: a manifest, its objects in a folder and the LFS files it names.
fn publish(device: &Device, share: &str, dir: &std::path::Path, node: &str, text: &str, lfs: Option<&std::path::Path>) {
    let objects = dir.join(format!("objects-{node}"));
    std::fs::create_dir_all(&objects).unwrap();
    let blob = "b".repeat(39) + &node[..1];
    std::fs::write(objects.join(&blob), format!("blob {}\0{text}", text.len())).unwrap();
    std::fs::write(objects.join(node), "commit 0\0").unwrap();
    let mut files = serde_json::json!({"main.typ": {"mode": "100644", "size": text.len(), "oid": blob, "lfs": false}});
    let mut sources = vec![];
    if let Some(lfs) = lfs {
        let blake3 = hash(lfs);
        files["img.png"] = serde_json::json!({"mode": "100644", "size": 4, "lfs": true, "blake3": blake3, "time": 1});
        sources.push(serde_json::json!({"blake3": blake3, "path": lfs}));
    }
    let manifest = serde_json::json!({"node": node, "tree": "c".repeat(40), "parents": [], "files": files, "ancestry": []});
    let (m, o, l) = (c(&manifest.to_string()), c(objects.to_str().unwrap()), c(&serde_json::Value::from(sources).to_string()));
    unsafe { tws_publish_node(device.node, c(share).as_ptr(), m.as_ptr(), o.as_ptr(), l.as_ptr()) };
    wait(device, "published", |e| e["type"] == "published-node" && e["node"] == node);
    assert!(!objects.exists(), "the objects folder is cleaned up");
}

#[test]
#[ignore]
fn syncs_a_share_between_two_devices() {
    let root = std::env::temp_dir().join(format!("tws-pair-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let account: [u8; 32] = std::array::from_fn(|i| (i as u8).wrapping_mul(37).wrapping_add(std::process::id() as u8));
    let a = device(&root.join("a"), &account);
    let b = device(&root.join("b"), &account);

    let share = format!("share-{}", std::process::id());
    unsafe { tws_add_share(a.node, c(&share).as_ptr(), c("Thesis").as_ptr(), c("space").as_ptr(), c("Laptop").as_ptr()) };
    wait(&b, "share listed on b", |e| {
        e["type"] == "shares"
            && e["shares"].as_array().unwrap().iter().any(|s| s["id"] == share.as_str() && s["kind"] == "space" && s["name"] == "Thesis")
    });
    unsafe { tws_open_share(b.node, c(&share).as_ptr(), c("Desktop").as_ptr()) };

    let image = root.join("img.png");
    std::fs::write(&image, [0u8, 1, 2, 3]).unwrap();
    let first = "1".repeat(40);
    publish(&a, &share, &root, &first, "= Hello", Some(&image));
    let head = wait(&b, "head on b", |e| e["type"] == "head" && e["share"] == share.as_str() && e["node"] == first.as_str());
    assert_eq!(head["name"], "Laptop");

    let out = root.join("fetched");
    unsafe { tws_fetch_node(b.node, c(&share).as_ptr(), c(head["device"].as_str().unwrap()).as_ptr(), c(out.to_str().unwrap()).as_ptr(), c("[]").as_ptr(), 7) };
    let fetched = wait(&b, "fetch", |e| e["type"] == "fetched" && e["request"] == 7);
    assert_eq!(fetched["ok"], true, "{fetched}");
    assert_eq!(fetched["node"], first.as_str());
    let manifest: serde_json::Value = serde_json::from_slice(&std::fs::read(out.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["node"], first.as_str());
    assert!(manifest.get("ancestry").is_none());
    let blob = "b".repeat(39) + "1";
    assert_eq!(std::fs::read_to_string(out.join("objects").join(blob)).unwrap(), "blob 7\0= Hello");
    assert_eq!(std::fs::read(out.join("lfs").join(hash(&image))).unwrap(), [0u8, 1, 2, 3]);

    // The next head replaces the first.
    let second = "2".repeat(40);
    publish(&a, &share, &root, &second, "= Hello again", None);
    wait(&b, "second head on b", |e| e["type"] == "head" && e["node"] == second.as_str());

    // b's head reaches a, named after b.
    let third = "3".repeat(40);
    publish(&b, &share, &root, &third, "= From b", None);
    let head = wait(&a, "head on a", |e| e["type"] == "head" && e["node"] == third.as_str());
    assert_eq!(head["name"], "Desktop");

    unsafe { tws_close_share(b.node, c(&share).as_ptr()) };
    wait(&a, "b left", |e| {
        e["type"] == "shares" && e["shares"].as_array().unwrap().iter().any(|s| s["id"] == share.as_str() && s["members"].as_array().unwrap().len() == 1)
    });

    unsafe {
        tws_stop(a.node);
        tws_stop(b.node);
    }
    let _ = std::fs::remove_dir_all(root);
}

/// Two accounts: `a` invites, `b` joins with the secret and no hints, so it finds `a` through the share's record.
#[test]
#[ignore]
fn shares_a_file_with_another_account() {
    let root = std::env::temp_dir().join(format!("tws-invite-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let seed = std::process::id() as u8;
    let a = device(&root.join("a"), &std::array::from_fn(|i| (i as u8).wrapping_mul(13).wrapping_add(seed)));
    let b = device(&root.join("b"), &std::array::from_fn(|i| (i as u8).wrapping_mul(29).wrapping_add(seed)));

    let share = format!("share-{}", std::process::id());
    unsafe { tws_add_share(a.node, c(&share).as_ptr(), c("todo.typ").as_ptr(), c("file").as_ptr(), c("A").as_ptr()) };
    let secret = unsafe { tws_share_invite(a.node, c(&share).as_ptr(), c("todo.typ").as_ptr(), c("file").as_ptr()) };
    let secret_text = unsafe { CStr::from_ptr(secret) }.to_str().unwrap().to_string();
    unsafe { tws_string_free(secret) };
    wait(&a, "shared on a", |e| {
        e["type"] == "shares" && e["shares"].as_array().unwrap().iter().any(|s| s["id"] == share.as_str() && s["shared"] == true)
    });
    let node = "4".repeat(40);
    publish(&a, &share, &root, &node, "- milk", None);

    unsafe {
        tws_join_share(b.node, c(&share).as_ptr(), c("todo.typ").as_ptr(), c("file").as_ptr(), c(&secret_text).as_ptr(), c("").as_ptr(), c("B").as_ptr())
    };
    wait(&b, "head on b", |e| e["type"] == "head" && e["node"] == node.as_str());

    // Heads of the joined account reach the owner.
    let reply = "5".repeat(40);
    publish(&b, &share, &root, &reply, "- milk\n- eggs", None);
    wait(&a, "head on a", |e| e["type"] == "head" && e["node"] == reply.as_str() && e["name"] == "B");

    unsafe {
        tws_stop(a.node);
        tws_stop(b.node);
    }
    let _ = std::fs::remove_dir_all(root);
}
