//! C interface for the Mac app: the node runs on its own tokio runtime and keeps its replicas,
//! blobs and device key in a data folder.

use std::{
    ffi::{CStr, CString, c_char, c_void},
    path::PathBuf,
    str::FromStr,
    sync::Arc,
    time::Duration,
};

use anyhow::Result;
use bytes::Bytes;
use iroh::{Endpoint, EndpointId, SecretKey, endpoint::presets};
use iroh_blobs::{Hash, api::blobs::ImportMode, store::fs::FsStore};
use iroh_docs::protocol::Docs;
use iroh_gossip::net::Gossip;
use serde_json::json;
use tokio::runtime::Runtime;

use crate::{
    Inner, MAX_GOSSIP_MESSAGE, Parts, begin_join, hex, invite, join_space, leave_space, list_space, live,
    open_space, parse_hex32, remove_space, share_space, space_doc, unpublish,
};

pub type EventCallback = extern "C" fn(context: *mut c_void, event: *const c_char);

pub struct TWSyncNode {
    runtime: Runtime,
    inner: Arc<Inner>,
}

async fn start(data_dir: PathBuf, account: [u8; 32], callback: EventCallback, context: usize) -> Result<Arc<Inner>> {
    tokio::fs::create_dir_all(data_dir.join("docs")).await?;
    // The device key is this device's own; only the account keys are shared.
    let key_path = data_dir.join("device.key");
    let device_key = match tokio::fs::read(&key_path).await {
        Ok(bytes) if bytes.len() == 32 => SecretKey::from_bytes(bytes.as_slice().try_into()?),
        _ => {
            let key = SecretKey::generate();
            tokio::fs::write(&key_path, key.to_bytes()).await?;
            key
        }
    };
    let endpoint = Endpoint::builder(presets::N0).secret_key(device_key).bind().await?;
    let store = FsStore::load(data_dir.join("blobs")).await?;
    let blobs = (*store).clone();
    let gossip = Gossip::builder().max_message_size(MAX_GOSSIP_MESSAGE).spawn(endpoint.clone());
    let docs = Docs::persistent(data_dir.join("docs")).spawn(endpoint.clone(), blobs.clone(), gossip.clone()).await?;
    let sink = Box::new(move |event: &str| {
        if let Ok(text) = CString::new(event) {
            callback(context as *mut c_void, text.as_ptr());
        }
    });
    crate::start(Parts { endpoint, store: Box::new(store), blobs, gossip, docs }, account, sink).await
}

async fn publish(inner: Arc<Inner>, id: String, path: String, file: PathBuf) -> Result<()> {
    let space = space_doc(&inner, &id).await?;
    let outcome = space
        .doc
        .import_file(&inner.blobs, space.author, Bytes::from(path.clone().into_bytes()), file, ImportMode::Copy)
        .await?
        .await?;
    crate::published(&inner, &id, &path, outcome.hash, outcome.size);
    Ok(())
}

async fn export(inner: Arc<Inner>, hash: String, target: PathBuf, request: i64) {
    let result: Result<()> = async {
        let hash = Hash::from_str(&hash)?;
        if let Some(dir) = target.parent() {
            tokio::fs::create_dir_all(dir).await?;
        }
        inner.blobs.export(hash, &target).await?;
        Ok(())
    }
    .await;
    if let Err(err) = &result {
        inner.error("export", anyhow::anyhow!("{err:#}"));
    }
    inner.emit(json!({"type": "exported", "request": request, "ok": result.is_ok()}));
}


unsafe fn string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

impl TWSyncNode {
    fn spawn<F>(&self, label: &'static str, task: F)
    where
        F: Future<Output = Result<()>> + Send + 'static,
    {
        let inner = self.inner.clone();
        self.runtime.spawn(async move {
            if let Err(err) = task.await {
                inner.error(label, err);
            }
        });
    }
}

/// Starts syncing for the account; NULL if the node can't start. `account` is 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_start(
    data_dir: *const c_char,
    account: *const u8,
    callback: EventCallback,
    context: *mut c_void,
) -> *mut TWSyncNode {
    let dir = PathBuf::from(unsafe { string(data_dir) });
    let mut secret = [0u8; 32];
    secret.copy_from_slice(unsafe { std::slice::from_raw_parts(account, 32) });
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread().enable_all().worker_threads(2).build() else {
        return std::ptr::null_mut();
    };
    match runtime.block_on(start(dir, secret, callback, context as usize)) {
        Ok(inner) => Box::into_raw(Box::new(TWSyncNode { runtime, inner })),
        Err(err) => {
            if let Ok(text) = CString::new(json!({"type": "error", "message": format!("start: {err:#}")}).to_string()) {
                callback(context, text.as_ptr());
            }
            std::ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_stop(node: *mut TWSyncNode) {
    if node.is_null() {
        return;
    }
    let node = unsafe { Box::from_raw(node) };
    let inner = node.inner.clone();
    node.runtime.block_on(async move {
        inner.endpoint.close().await;
    });
    node.runtime.shutdown_timeout(Duration::from_secs(2));
}

/// This device's endpoint id; free with `tws_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_device_id(node: *const TWSyncNode) -> *mut c_char {
    let node = unsafe { &*node };
    CString::new(node.inner.endpoint.id().to_string()).unwrap_or_default().into_raw()
}

/// Lists the space for all devices of the account and starts syncing it here.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_share_space(node: *const TWSyncNode, space: *const c_char, name: *const c_char) {
    let node = unsafe { &*node };
    let (id, name) = unsafe { (string(space), string(name)) };
    node.spawn("share space", share_space(node.inner.clone(), id, name));
}

/// The secret (hex) an invite link to the space carries; marks the space shared for all devices of
/// the account. Free with `tws_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_invite(node: *const TWSyncNode, space: *const c_char, name: *const c_char) -> *mut c_char {
    let node = unsafe { &*node };
    let (id, name) = unsafe { (string(space), string(name)) };
    let secret = node.inner.namespace(&id);
    node.spawn("invite", invite(node.inner.clone(), id, name));
    CString::new(hex(&secret)).unwrap_or_default().into_raw()
}

/// Starts syncing a space from an invite: `secret` is hex and `hints` comma separated endpoint ids
/// to dial first. Answers with an `entries` event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_join_space(
    node: *const TWSyncNode,
    space: *const c_char,
    name: *const c_char,
    secret: *const c_char,
    hints: *const c_char,
) {
    let node = unsafe { &*node };
    let (id, name, secret, hints) = unsafe { (string(space), string(name), string(secret), string(hints)) };
    let Some(secret) = parse_hex32(&secret) else {
        return node.inner.error("join space", anyhow::anyhow!("invalid secret"));
    };
    let hints = hints.split(',').filter_map(|h| EndpointId::from_str(h.trim()).ok()).collect();
    // Known before returning, so Swift's next calls open the right replica.
    begin_join(&node.inner, &id, secret, hints);
    node.spawn("join space", join_space(node.inner.clone(), id, name, secret));
}

/// Starts syncing a space listed by the account; answers with an `entries` event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_open_space(node: *const TWSyncNode, space: *const c_char) {
    let node = unsafe { &*node };
    let id = unsafe { string(space) };
    node.spawn("open space", open_space(node.inner.clone(), id));
}

/// Stops syncing a space on this device; the other devices keep it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_close_space(node: *const TWSyncNode, space: *const c_char) {
    let node = unsafe { &*node };
    let id = unsafe { string(space) };
    node.spawn("close space", leave_space(node.inner.clone(), id));
}

/// Stops syncing a space on every device of the account; the files stay everywhere.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_remove_space(node: *const TWSyncNode, space: *const c_char) {
    let node = unsafe { &*node };
    let id = unsafe { string(space) };
    node.spawn("remove space", remove_space(node.inner.clone(), id));
}

/// Starts live editing of a file shown in an editor; `name` labels this device's cursor elsewhere.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_live_open(
    node: *const TWSyncNode,
    space: *const c_char,
    path: *const c_char,
    text: *const c_char,
    name: *const c_char,
) {
    let node = unsafe { &*node };
    let (space, path, text, name) = unsafe { (string(space), string(path), string(text), string(name)) };
    let _guard = node.runtime.enter();
    live::open(&node.inner, &space, &path, &text, &name);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_live_close(node: *const TWSyncNode, space: *const c_char, path: *const c_char) {
    let node = unsafe { &*node };
    let (space, path) = unsafe { (string(space), string(path)) };
    live::close(&node.inner, &space, &path);
}

/// Hands over the editor's text and selection (UTF-16) and returns what changed elsewhere as JSON:
/// `edits` to apply in order, `adopted` texts to merge, the other `cursors` and the `peers` count.
/// `step` 1 undoes and 2 redoes this device's last edit. Free with `tws_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_live_sync(
    node: *const TWSyncNode,
    space: *const c_char,
    path: *const c_char,
    text: *const c_char,
    location: u32,
    length: u32,
    step: i32,
) -> *mut c_char {
    let node = unsafe { &*node };
    let (space, path, text) = unsafe { (string(space), string(path), string(text)) };
    let step = match step {
        1 => live::Step::Undo,
        2 => live::Step::Redo,
        _ => live::Step::None,
    };
    let result = live::sync(&node.inner, &space, &path, &text, (location, length), step);
    CString::new(result.to_string()).unwrap_or_default().into_raw()
}

/// Imports the file at `file` as the space's `path`; answers with a `published` event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_publish(
    node: *const TWSyncNode,
    space: *const c_char,
    path: *const c_char,
    file: *const c_char,
) {
    let node = unsafe { &*node };
    let (id, path, file) = unsafe { (string(space), string(path), PathBuf::from(string(file))) };
    node.spawn("publish", publish(node.inner.clone(), id, path, file));
}

/// Marks the space's `path` deleted; answers with a `published` event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_unpublish(node: *const TWSyncNode, space: *const c_char, path: *const c_char) {
    let node = unsafe { &*node };
    let (id, path) = unsafe { (string(space), string(path)) };
    node.spawn("unpublish", unpublish(node.inner.clone(), id, path));
}

/// Writes a blob to `target`; answers with an `exported` event carrying `request`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_export(node: *const TWSyncNode, hash: *const c_char, target: *const c_char, request: i64) {
    let node = unsafe { &*node };
    let (hash, target) = unsafe { (string(hash), PathBuf::from(string(target))) };
    node.runtime.spawn(export(node.inner.clone(), hash, target, request));
}

/// Re-sends the space's entries as an `entries` event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_list_space(node: *const TWSyncNode, space: *const c_char) {
    let node = unsafe { &*node };
    let id = unsafe { string(space) };
    let inner = node.inner.clone();
    node.spawn("list space", async move { list_space(&inner, &id).await });
}

/// BLAKE3 of a file, hex encoded as blob hashes are; NULL if unreadable. Free with `tws_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_hash_file(path: *const c_char) -> *mut c_char {
    let path = unsafe { string(path) };
    let mut hasher = blake3::Hasher::new();
    match hasher.update_mmap(&path) {
        Ok(_) => CString::new(hasher.finalize().to_hex().to_string()).unwrap_or_default().into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
