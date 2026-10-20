//! Devices over the real n0 relays: a space reaches a second device of the account, or another account by invite;
//! a file follows, and so does its deletion. Needs network; run with `cargo test -- --ignored`.

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

#[test]
#[ignore]
fn syncs_a_space_between_two_devices() {
    let root = std::env::temp_dir().join(format!("tws-pair-{}", std::process::id()));
    let account: [u8; 32] = std::array::from_fn(|i| (i as u8).wrapping_mul(37).wrapping_add(std::process::id() as u8));
    let a = device(&root.join("a"), &account);
    let b = device(&root.join("b"), &account);

    let space = format!("space-{}", std::process::id());
    unsafe { tws_share_space(a.node, c(&space).as_ptr(), c("Thesis").as_ptr()) };
    wait(&b, "space listed on b", |e| {
        e["type"] == "spaces" && e["spaces"].as_array().unwrap().iter().any(|s| s["id"] == space.as_str())
    });
    unsafe { tws_open_space(b.node, c(&space).as_ptr()) };

    let file = root.join("main.typ");
    std::fs::write(&file, "= Hello").unwrap();
    unsafe { tws_publish(a.node, c(&space).as_ptr(), c("main.typ").as_ptr(), c(file.to_str().unwrap()).as_ptr()) };
    let event = wait(&b, "file on b", |e| e["type"] == "remote" && e["path"] == "main.typ");
    assert_eq!(event["deleted"], false);
    let hash = unsafe { tws_hash_file(c(file.to_str().unwrap()).as_ptr()) };
    assert_eq!(event["hash"], unsafe { CStr::from_ptr(hash) }.to_str().unwrap());

    let out = root.join("b-main.typ");
    unsafe { tws_export(b.node, c(event["hash"].as_str().unwrap()).as_ptr(), c(out.to_str().unwrap()).as_ptr(), 7) };
    wait(&b, "export", |e| e["type"] == "exported" && e["request"] == 7 && e["ok"] == true);
    assert_eq!(std::fs::read_to_string(&out).unwrap(), "= Hello");

    unsafe { tws_unpublish(a.node, c(&space).as_ptr(), c("main.typ").as_ptr()) };
    wait(&b, "deletion on b", |e| e["type"] == "remote" && e["path"] == "main.typ" && e["deleted"] == true);

    unsafe {
        tws_stop(a.node);
        tws_stop(b.node);
    }
    let _ = std::fs::remove_dir_all(root);
}

/// Two accounts: `a` invites, `b` joins with the secret and no hints, so it finds `a` through the space's record.
#[test]
#[ignore]
fn shares_a_space_with_another_account() {
    let root = std::env::temp_dir().join(format!("tws-invite-{}", std::process::id()));
    let seed = std::process::id() as u8;
    let a = device(&root.join("a"), &std::array::from_fn(|i| (i as u8).wrapping_mul(13).wrapping_add(seed)));
    let b = device(&root.join("b"), &std::array::from_fn(|i| (i as u8).wrapping_mul(29).wrapping_add(seed)));

    let space = format!("space-{}", std::process::id());
    unsafe { tws_share_space(a.node, c(&space).as_ptr(), c("Paper").as_ptr()) };
    let secret = unsafe { tws_invite(a.node, c(&space).as_ptr(), c("Paper").as_ptr()) };
    let secret_text = unsafe { CStr::from_ptr(secret) }.to_str().unwrap().to_string();
    unsafe { tws_string_free(secret) };
    wait(&a, "shared on a", |e| {
        e["type"] == "spaces" && e["spaces"].as_array().unwrap().iter().any(|s| s["id"] == space.as_str() && s["shared"] == true)
    });

    let file = root.join("main.typ");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(&file, "= Shared").unwrap();
    unsafe { tws_publish(a.node, c(&space).as_ptr(), c("main.typ").as_ptr(), c(file.to_str().unwrap()).as_ptr()) };

    unsafe { tws_join_space(b.node, c(&space).as_ptr(), c("Paper").as_ptr(), c(&secret_text).as_ptr(), c("").as_ptr()) };
    // The listing and the file arrive in either order.
    let (listed, arrived) = (std::cell::Cell::new(false), std::cell::Cell::new(false));
    wait(&b, "file and listing on b", |e| {
        if e["type"] == "spaces" && e["spaces"].as_array().unwrap().iter().any(|s| s["id"] == space.as_str() && s["shared"] == true) {
            listed.set(true);
        }
        if (e["type"] == "remote" && e["path"] == "main.typ" && e["space"] == space.as_str())
            || (e["type"] == "entries" && e["entries"].as_array().unwrap().iter().any(|x| x["path"] == "main.typ"))
        {
            arrived.set(true);
        }
        listed.get() && arrived.get()
    });

    // Writes of the joined account reach the owner.
    let other = root.join("notes.typ");
    std::fs::write(&other, "notes").unwrap();
    unsafe { tws_publish(b.node, c(&space).as_ptr(), c("notes.typ").as_ptr(), c(other.to_str().unwrap()).as_ptr()) };
    wait(&a, "file on a", |e| e["type"] == "remote" && e["path"] == "notes.typ");

    unsafe {
        tws_stop(a.node);
        tws_stop(b.node);
    }
    let _ = std::fs::remove_dir_all(root);
}
