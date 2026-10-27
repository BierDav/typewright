//! C interface for the Mac app: the node runs on its own tokio runtime and keeps its replicas,
//! blobs and device key in a data folder. The Mac syncs shares (`shares`); spaces' path-by-path
//! replicas stay for the web app.

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

use crate::{Inner, MAX_GOSSIP_MESSAGE, Parts, begin_join, bundle, hex, live, parse_hex32, shares};

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

#[derive(serde::Deserialize)]
struct LfsSource {
    blake3: String,
    path: PathBuf,
}

/// Bundles the objects `twj_write_objects` put in `dir` (removed afterwards) with the manifest and publishes it.
async fn publish_node(inner: Arc<Inner>, id: String, manifest: String, dir: PathBuf, lfs: String) -> Result<()> {
    let manifest: serde_json::Value = serde_json::from_str(&manifest)?;
    let mut objects = Vec::new();
    for entry in std::fs::read_dir(&dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.len() == 40 && name.chars().all(|c| c.is_ascii_hexdigit()) {
            objects.push((name, std::fs::read(entry.path())?));
        }
    }
    let bytes = bundle::encode(&manifest, &objects)?;
    let _ = std::fs::remove_dir_all(&dir);
    let sources: std::collections::HashMap<String, PathBuf> =
        serde_json::from_str::<Vec<LfsSource>>(&lfs)?.into_iter().map(|s| (s.blake3, s.path)).collect();
    let blobs = inner.blobs.clone();
    shares::publish_node(inner, id, bytes, bundle::lfs_hashes(&manifest), move |doc, author, key| {
        let blobs = blobs.clone();
        let source = sources.get(&key[4..]).cloned();
        async move {
            let source = source.ok_or_else(|| anyhow::anyhow!("no file for LFS {key}"))?;
            let outcome = doc.import_file(&blobs, author, Bytes::from(key.into_bytes()), source, ImportMode::Copy).await?.await?;
            Ok(outcome.hash)
        }
    })
    .await
}

/// Unpacks `device`'s head into `dir`: `manifest.json`, `objects/<oid>` and `lfs/<blake3>` (except `skip`).
async fn fetch_node(inner: Arc<Inner>, id: String, device: String, dir: PathBuf, skip: String, request: i64) {
    let result: Result<String> = async {
        let bundle = shares::head_bundle(&inner, &id, &device).await?;
        let skip: std::collections::HashSet<String> = serde_json::from_str(&skip).unwrap_or_default();
        tokio::fs::create_dir_all(dir.join("objects")).await?;
        tokio::fs::create_dir_all(dir.join("lfs")).await?;
        for (oid, bytes) in &bundle.objects {
            tokio::fs::write(dir.join("objects").join(oid), bytes).await?;
        }
        tokio::fs::write(dir.join("manifest.json"), serde_json::to_vec(&bundle.manifest)?).await?;
        for hash in bundle::lfs_hashes(&bundle.manifest) {
            if !skip.contains(&hash) {
                inner.blobs.export(Hash::from_str(&hash)?, dir.join("lfs").join(&hash)).await?;
            }
        }
        Ok(bundle.manifest["node"].as_str().unwrap_or_default().to_owned())
    }
    .await;
    let event = match result {
        Ok(node) => json!({"type": "fetched", "request": request, "ok": true, "node": node}),
        Err(err) => json!({"type": "fetched", "request": request, "ok": false, "message": format!("{err:#}")}),
    };
    inner.emit(event);
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

/// Lists the share (`kind` "space", "folder" or "file") for all devices of the account and starts syncing it here;
/// `device` names this device on the others.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_add_share(
    node: *const TWSyncNode,
    share: *const c_char,
    name: *const c_char,
    kind: *const c_char,
    device: *const c_char,
) {
    let node = unsafe { &*node };
    let (id, name, kind, device) = unsafe { (string(share), string(name), string(kind), string(device)) };
    node.spawn("add share", shares::add_share(node.inner.clone(), id, name, kind, device));
}

/// The secret (hex) an invite link to the share carries; marks it shared for all devices of the account.
/// Free with `tws_string_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_share_invite(
    node: *const TWSyncNode,
    share: *const c_char,
    name: *const c_char,
    kind: *const c_char,
) -> *mut c_char {
    let node = unsafe { &*node };
    let (id, name, kind) = unsafe { (string(share), string(name), string(kind)) };
    let secret = node.inner.namespace(&id);
    node.spawn("invite", shares::invite_share(node.inner.clone(), id, name, kind));
    CString::new(hex(&secret)).unwrap_or_default().into_raw()
}

/// Configures device sync and sharing independently; answers with a `configured` event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_configure_share(node: *const TWSyncNode, share: *const c_char, devices: i32, shared: i32, rotate: i32, request: i64) {
    let node = unsafe { &*node };
    let id = unsafe { string(share) };
    let inner = node.inner.clone();
    node.runtime.spawn(async move {
        let result = shares::configure_share(inner.clone(), id, devices != 0, shared != 0, rotate != 0).await;
        inner.emit(serde_json::json!({"type": "configured", "request": request, "ok": result.is_ok(), "message": result.err().map(|e| format!("{e:#}"))}));
    });
}

/// Starts syncing a share from an invite: `secret` is hex and `hints` comma separated endpoint ids to dial first.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_join_share(
    node: *const TWSyncNode,
    share: *const c_char,
    name: *const c_char,
    kind: *const c_char,
    secret: *const c_char,
    hints: *const c_char,
    device: *const c_char,
) {
    let node = unsafe { &*node };
    let (id, name, kind, secret, hints, device) =
        unsafe { (string(share), string(name), string(kind), string(secret), string(hints), string(device)) };
    let Some(secret) = parse_hex32(&secret) else {
        return node.inner.error("join share", anyhow::anyhow!("invalid secret"));
    };
    let hints = hints.split(',').filter_map(|h| EndpointId::from_str(h.trim()).ok()).collect();
    // Known before returning, so the next calls open the right replica.
    begin_join(&node.inner, &id, secret, hints);
    node.spawn("join share", shares::join_share(node.inner.clone(), id, name, kind, secret, device));
}

/// Starts syncing a share listed by the account; answers with `head` events for the other devices' heads.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_open_share(node: *const TWSyncNode, share: *const c_char, device: *const c_char) {
    let node = unsafe { &*node };
    let (id, device) = unsafe { (string(share), string(device)) };
    node.spawn("open share", shares::open_share(node.inner.clone(), id, device));
}

/// Stops syncing a share on this device; the other devices keep it. A share nobody syncs leaves the account.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_close_share(node: *const TWSyncNode, share: *const c_char) {
    let node = unsafe { &*node };
    let id = unsafe { string(share) };
    node.spawn("close share", shares::leave_share(node.inner.clone(), id));
}

/// Stops syncing a share on every device of the account; the files stay everywhere.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_remove_share(node: *const TWSyncNode, share: *const c_char) {
    let node = unsafe { &*node };
    let id = unsafe { string(share) };
    node.spawn("remove share", shares::remove_share(node.inner.clone(), id));
}

/// Re-sends the ready heads of the other devices as `head` events.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_list_heads(node: *const TWSyncNode, share: *const c_char) {
    let node = unsafe { &*node };
    let id = unsafe { string(share) };
    let inner = node.inner.clone();
    node.spawn("list heads", async move { shares::list_heads(&inner, &id).await });
}

/// Publishes a node as this device's head: `manifest` from `twj_export_node`, `objects` the folder
/// `twj_write_objects` filled with the node (removed afterwards), `lfs` a JSON array of `{"blake3", "path"}`
/// naming where the manifest's LFS files are. Answers with a `published-node` event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_publish_node(
    node: *const TWSyncNode,
    share: *const c_char,
    manifest: *const c_char,
    objects: *const c_char,
    lfs: *const c_char,
) {
    let node = unsafe { &*node };
    let (id, manifest, objects, lfs) = unsafe { (string(share), string(manifest), PathBuf::from(string(objects)), string(lfs)) };
    node.spawn("publish node", publish_node(node.inner.clone(), id, manifest, objects, lfs));
}

/// Unpacks `device`'s head into `dir` (`manifest.json`, `objects/`, `lfs/`; LFS files in the JSON array `skip`
/// are left out); answers with a `fetched` event carrying `request` and the `node`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_fetch_node(
    node: *const TWSyncNode,
    share: *const c_char,
    device: *const c_char,
    dir: *const c_char,
    skip: *const c_char,
    request: i64,
) {
    let node = unsafe { &*node };
    let (id, device, dir, skip) = unsafe { (string(share), string(device), PathBuf::from(string(dir)), string(skip)) };
    node.runtime.spawn(fetch_node(node.inner.clone(), id, device, dir, skip, request));
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

/// Writes a blob to `target`; answers with an `exported` event carrying `request`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn tws_export(node: *const TWSyncNode, hash: *const c_char, target: *const c_char, request: i64) {
    let node = unsafe { &*node };
    let (hash, target) = unsafe { (string(hash), PathBuf::from(string(target))) };
    node.runtime.spawn(export(node.inner.clone(), hash, target, request));
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
