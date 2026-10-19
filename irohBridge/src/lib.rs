//! Syncs space folders between the devices of one account over iroh.
//!
//! Every key is derived from the account secret (the passkey's PRF output), so each device of the
//! account finds the others and opens the same replicas without exchanging anything:
//! - a pkarr record lists the account's devices, for dialing,
//! - an account replica lists the synced spaces (`space/<id>` → `{"name": …}`),
//! - one replica per space maps relative paths to blob hashes; all devices write as one author,
//!   so the newest write of a path wins,
//! - one gossip topic per space carries live edits and cursors of open files (see `live`).
//!
//! Events reach Swift as JSON strings through one callback, on arbitrary threads.

use std::{
    collections::{HashMap, HashSet},
    ffi::{CStr, CString, c_char, c_void},
    path::PathBuf,
    str::FromStr,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::Result;
use bytes::Bytes;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, SecretKey,
    address_lookup::{N0_DNS_PKARR_RELAY_PROD, PkarrRelayClient},
    endpoint::presets,
    protocol::Router,
};
use iroh_blobs::{BlobsProtocol, Hash, api::blobs::ImportMode, store::fs::FsStore};
use iroh_dns::pkarr::SignedPacket;
use iroh_docs::{
    Author, AuthorId, Capability, ContentStatus, NamespaceSecret, api::Doc, engine::LiveEvent, protocol::Docs,
    store::Query,
};
use iroh_gossip::net::Gossip;
use n0_future::StreamExt;
use serde_json::json;
use tokio::runtime::Runtime;

mod live;

/// Content of a path's entry once the file is deleted; empty entries can't mark deletions since
/// empty files have them too.
const TOMBSTONE: &[u8] = b"typewright:deleted:v0\0";
const DIRECTORY_NAME: &str = "_devices";
/// Records hold at most 1000 bytes; the oldest devices drop out first.
const MAX_DEVICES: usize = 12;
/// Live sessions send whole documents when they meet; files larger than this sync on save only.
const MAX_GOSSIP_MESSAGE: usize = 1 << 20;

pub type EventCallback = extern "C" fn(context: *mut c_void, event: *const c_char);

pub struct TWSyncNode {
    runtime: Runtime,
    inner: Arc<Inner>,
}

struct Inner {
    endpoint: Endpoint,
    _router: Router,
    blobs: FsStore,
    docs: Docs,
    author: AuthorId,
    account: [u8; 32],
    account_doc: Doc,
    gossip: Gossip,
    spaces: Mutex<HashMap<String, Doc>>,
    topics: Mutex<HashMap<String, live::Topic>>,
    live: Mutex<HashMap<(String, String), live::Session>>,
    /// Serializes opening spaces, so each is subscribed once.
    opening: tokio::sync::Mutex<()>,
    neighbors: Mutex<HashSet<EndpointId>>,
    devices: Mutex<Vec<EndpointId>>,
    callback: EventCallback,
    context: usize,
}

impl Inner {
    fn emit(&self, event: serde_json::Value) {
        let Ok(text) = CString::new(event.to_string()) else { return };
        (self.callback)(self.context as *mut c_void, text.as_ptr());
    }

    fn error(&self, context: &str, err: anyhow::Error) {
        self.emit(json!({"type": "error", "message": format!("{context}: {err:#}")}));
    }

    fn status(&self) {
        let peers: Vec<String> = self.neighbors.lock().unwrap().iter().map(|p| p.to_string()).collect();
        let devices: Vec<String> = self.devices.lock().unwrap().iter().map(|p| p.to_string()).collect();
        self.emit(json!({
            "type": "status", "device": self.endpoint.id().to_string(), "peers": peers, "devices": devices,
        }));
    }


    fn peer_addrs(&self) -> Vec<EndpointAddr> {
        let me = self.endpoint.id();
        self.devices.lock().unwrap().iter().filter(|d| **d != me).map(|d| EndpointAddr::from(*d)).collect()
    }
}

fn derive(context: &str, parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new_derive_key(context);
    for part in parts {
        hasher.update(part);
    }
    *hasher.finalize().as_bytes()
}

fn space_secret(account: &[u8; 32], id: &str) -> NamespaceSecret {
    NamespaceSecret::from_bytes(&derive("typewright 2026-10 space v0", &[account, id.as_bytes()]))
}

fn tombstone_hash() -> Hash {
    Hash::new(TOMBSTONE)
}

fn entry_json(space: &str, key: &[u8], hash: Hash, size: u64) -> serde_json::Value {
    let deleted = hash == tombstone_hash();
    json!({
        "space": space,
        "path": String::from_utf8_lossy(key),
        "hash": hash.to_hex().to_string(),
        "size": if deleted { 0 } else { size },
        "deleted": deleted,
    })
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
    let blobs = FsStore::load(data_dir.join("blobs")).await?;
    let gossip = Gossip::builder().max_message_size(MAX_GOSSIP_MESSAGE).spawn(endpoint.clone());
    let docs = Docs::persistent(data_dir.join("docs")).spawn(endpoint.clone(), (*blobs).clone(), gossip.clone()).await?;
    let router = Router::builder(endpoint.clone())
        .accept(iroh_blobs::ALPN, BlobsProtocol::new(&blobs, None))
        .accept(iroh_gossip::ALPN, gossip.clone())
        .accept(iroh_docs::ALPN, docs.clone())
        .spawn();

    let author = Author::from_bytes(&derive("typewright 2026-10 author v0", &[&account]));
    docs.author_import(author.clone()).await?;
    let account_secret = NamespaceSecret::from_bytes(&derive("typewright 2026-10 account v0", &[&account]));
    let account_doc = docs.import_namespace(Capability::Write(account_secret)).await?;

    let inner = Arc::new(Inner {
        endpoint,
        _router: router,
        blobs,
        docs,
        author: author.id(),
        account,
        account_doc,
        gossip,
        spaces: Mutex::new(HashMap::new()),
        topics: Mutex::new(HashMap::new()),
        live: Mutex::new(HashMap::new()),
        opening: tokio::sync::Mutex::new(()),
        neighbors: Mutex::new(HashSet::new()),
        devices: Mutex::new(Vec::new()),
        callback,
        context,
    });
    tokio::spawn(watch_account(inner.clone()));
    tokio::spawn(directory_loop(inner.clone()));
    inner.status();
    Ok(inner)
}

/// Keeps this device in the account's pkarr record and syncs every replica with the devices listed there.
async fn directory_loop(inner: Arc<Inner>) {
    let key = SecretKey::from_bytes(&derive("typewright 2026-10 directory v0", &[&inner.account]));
    let mut round = 0u32;
    loop {
        if let Err(err) = refresh_directory(&inner, &key, round % 10 == 0).await {
            inner.error("device directory", err);
        }
        round += 1;
        tokio::time::sleep(Duration::from_secs(if round < 3 { 10 } else { 60 })).await;
    }
}

async fn refresh_directory(inner: &Inner, key: &SecretKey, republish: bool) -> Result<()> {
    let client = PkarrRelayClient::new(
        N0_DNS_PKARR_RELAY_PROD.parse()?,
        inner.endpoint.tls_config().clone(),
        inner.endpoint.dns_resolver()?.clone(),
    );
    let mut ids: Vec<String> = match client.resolve(key.public()).await {
        Ok(packet) => packet.txt_records(DIRECTORY_NAME),
        Err(_) => Vec::new(),
    };
    let me = inner.endpoint.id().to_string();
    // Concurrent publishes can drop a device; it adds itself back on its next round.
    if !ids.contains(&me) || republish {
        ids.retain(|id| *id != me);
        ids.push(me);
        while ids.len() > MAX_DEVICES {
            ids.remove(0);
        }
        let packet = SignedPacket::from_txt_strings(key, DIRECTORY_NAME, &ids, 3600)?;
        client.publish(&packet).await?;
    }
    *inner.devices.lock().unwrap() = ids.iter().filter_map(|id| EndpointId::from_str(id).ok()).collect();
    let peers = inner.peer_addrs();
    if !peers.is_empty() {
        inner.account_doc.start_sync(peers.clone()).await?;
        let spaces: Vec<Doc> = inner.spaces.lock().unwrap().values().cloned().collect();
        for doc in spaces {
            doc.start_sync(peers.clone()).await?;
        }
        live::add_peers(inner, peers.iter().map(|addr| addr.id).collect()).await;
    }
    inner.status();
    Ok(())
}

async fn watch_account(inner: Arc<Inner>) {
    let result: Result<()> = async {
        let mut events = inner.account_doc.subscribe().await?;
        emit_spaces(&inner).await?;
        while let Some(event) = events.next().await {
            match event? {
                LiveEvent::InsertLocal { .. } | LiveEvent::InsertRemote { .. } | LiveEvent::ContentReady { .. } => {
                    emit_spaces(&inner).await?
                }
                LiveEvent::NeighborUp(peer) => track(&inner, peer, true),
                LiveEvent::NeighborDown(peer) => track(&inner, peer, false),
                _ => {}
            }
        }
        Ok(())
    }
    .await;
    if let Err(err) = result {
        inner.error("account replica", err);
    }
}

fn track(inner: &Inner, peer: EndpointId, up: bool) {
    let mut neighbors = inner.neighbors.lock().unwrap();
    if up { neighbors.insert(peer) } else { neighbors.remove(&peer) };
    drop(neighbors);
    inner.status();
}

/// Lists the account's spaces with the devices syncing each (`member/<space>/<device>`), and the
/// spaces removed from all devices (`removed/<space>`).
async fn emit_spaces(inner: &Inner) -> Result<()> {
    let mut members: HashMap<String, Vec<String>> = HashMap::new();
    let mut removed = Vec::new();
    let all = inner.account_doc.get_many(Query::single_latest_per_key().build()).await?;
    tokio::pin!(all);
    while let Some(entry) = all.next().await {
        let entry = entry?;
        let key = String::from_utf8_lossy(entry.key()).to_string();
        if let Some(rest) = key.strip_prefix("member/") {
            if let Some((space, device)) = rest.split_once('/') {
                members.entry(space.to_string()).or_default().push(device.to_string());
            }
        } else if let Some(space) = key.strip_prefix("removed/") {
            removed.push(space.to_string());
        }
    }
    let mut spaces = Vec::new();
    let entries = inner.account_doc.get_many(Query::single_latest_per_key().key_prefix("space/").build()).await?;
    tokio::pin!(entries);
    while let Some(entry) = entries.next().await {
        let entry = entry?;
        let id = String::from_utf8_lossy(&entry.key()[6..]).to_string();
        // Content arrives after the entry; the next ContentReady lists it.
        let Ok(bytes) = inner.blobs.get_bytes(entry.content_hash()).await else { continue };
        let Ok(mut info) = serde_json::from_slice::<serde_json::Value>(&bytes) else { continue };
        info["members"] = json!(members.remove(&id).unwrap_or_default());
        info["id"] = json!(id);
        spaces.push(info);
    }
    inner.emit(json!({"type": "spaces", "spaces": spaces, "removed": removed}));
    Ok(())
}

fn member_key(inner: &Inner, space: &str) -> String {
    format!("member/{space}/{}", inner.endpoint.id())
}

/// Stops syncing here; a space nobody syncs anymore leaves the account.
async fn leave_space(inner: Arc<Inner>, id: String) -> Result<()> {
    live::leave(&inner, &id);
    let doc = inner.spaces.lock().unwrap().remove(&id);
    if let Some(doc) = doc {
        doc.leave().await?;
    }
    inner.account_doc.del(inner.author, member_key(&inner, &id)).await?;
    let others = inner.account_doc.get_many(Query::single_latest_per_key().key_prefix(format!("member/{id}/")).build()).await?;
    tokio::pin!(others);
    if others.next().await.is_none() {
        inner.account_doc.del(inner.author, format!("space/{id}")).await?;
    }
    Ok(())
}

/// Takes the space off every device; each keeps its files.
async fn remove_space(inner: Arc<Inner>, id: String) -> Result<()> {
    inner.account_doc.set_bytes(inner.author, format!("removed/{id}"), b"1".to_vec()).await?;
    inner.account_doc.del(inner.author, format!("space/{id}")).await?;
    inner.account_doc.del(inner.author, format!("member/{id}/")).await?;
    leave_space(inner, id).await
}

/// The space's replica, opened, watched and syncing on first use.
async fn space_doc(inner: &Arc<Inner>, id: &str) -> Result<Doc> {
    let _guard = inner.opening.lock().await;
    if let Some(doc) = inner.spaces.lock().unwrap().get(id).cloned() {
        return Ok(doc);
    }
    let doc = inner.docs.import_namespace(Capability::Write(space_secret(&inner.account, id))).await?;
    let events = doc.subscribe().await?;
    tokio::spawn(watch_space(inner.clone(), id.to_string(), doc.clone(), events));
    inner.spaces.lock().unwrap().insert(id.to_string(), doc.clone());
    inner.account_doc.set_bytes(inner.author, member_key(inner, id), b"1".to_vec()).await?;
    live::join(inner, id).await?;
    let peers = inner.peer_addrs();
    if !peers.is_empty() {
        doc.start_sync(peers).await?;
    }
    Ok(doc)
}

async fn open_space(inner: Arc<Inner>, id: String) -> Result<()> {
    space_doc(&inner, &id).await?;
    list_space(&inner, &id).await
}

/// Reports remote writes once their content is local, so the app can write the file right away.
async fn watch_space(
    inner: Arc<Inner>,
    id: String,
    doc: Doc,
    mut events: impl n0_future::Stream<Item = Result<LiveEvent>> + Unpin,
) {
    let mut pending: HashMap<Hash, Vec<Vec<u8>>> = HashMap::new();
    while let Some(event) = events.next().await {
        let event = match event {
            Ok(event) => event,
            Err(err) => return inner.error("space replica", err),
        };
        match event {
            LiveEvent::InsertRemote { entry, content_status, .. } => {
                if content_status == ContentStatus::Complete || entry.content_len() == 0 {
                    inner.emit(remote(&id, entry.key(), entry.content_hash(), entry.content_len()));
                } else {
                    pending.entry(entry.content_hash()).or_default().push(entry.key().to_vec());
                }
            }
            LiveEvent::ContentReady { hash } => {
                for key in pending.remove(&hash).unwrap_or_default() {
                    // Only if nothing newer replaced it meanwhile.
                    if let Ok(Some(entry)) = doc.get_exact(inner.author, &key, true).await {
                        if entry.content_hash() == hash {
                            inner.emit(remote(&id, &key, hash, entry.content_len()));
                        }
                    }
                }
            }
            LiveEvent::NeighborUp(peer) => track(&inner, peer, true),
            LiveEvent::NeighborDown(peer) => track(&inner, peer, false),
            _ => {}
        }
    }
}

fn remote(space: &str, key: &[u8], hash: Hash, size: u64) -> serde_json::Value {
    let mut event = entry_json(space, key, hash, size);
    event["type"] = json!("remote");
    event
}

async fn list_space(inner: &Arc<Inner>, id: &str) -> Result<()> {
    let doc = space_doc(inner, id).await?;
    let stream = doc.get_many(Query::single_latest_per_key().include_empty().build()).await?;
    tokio::pin!(stream);
    let mut entries = Vec::new();
    while let Some(entry) = stream.next().await {
        let entry = entry?;
        // Entries whose content hasn't arrived yet follow as `remote` events.
        let present = entry.content_len() == 0 || inner.blobs.has(entry.content_hash()).await.unwrap_or(false);
        if present {
            entries.push(entry_json(id, entry.key(), entry.content_hash(), entry.content_len()));
        }
    }
    inner.emit(json!({"type": "entries", "space": id, "entries": entries}));
    Ok(())
}

async fn share_space(inner: Arc<Inner>, id: String, name: String) -> Result<()> {
    // Membership lands before the listing, so no device sees the space without members.
    inner.account_doc.set_bytes(inner.author, member_key(&inner, &id), b"1".to_vec()).await?;
    let info = serde_json::to_vec(&json!({"name": name}))?;
    inner.account_doc.set_bytes(inner.author, format!("space/{id}"), info).await?;
    open_space(inner, id).await
}

async fn publish(inner: Arc<Inner>, id: String, path: String, file: PathBuf) -> Result<()> {
    let doc = space_doc(&inner, &id).await?;
    let outcome = doc
        .import_file(&inner.blobs, inner.author, Bytes::from(path.clone().into_bytes()), file, ImportMode::Copy)
        .await?
        .await?;
    let mut event = entry_json(&id, path.as_bytes(), outcome.hash, outcome.size);
    event["type"] = json!("published");
    inner.emit(event);
    Ok(())
}

async fn unpublish(inner: Arc<Inner>, id: String, path: String) -> Result<()> {
    let doc = space_doc(&inner, &id).await?;
    let hash = doc.set_bytes(inner.author, Bytes::from(path.clone().into_bytes()), TOMBSTONE).await?;
    let mut event = entry_json(&id, path.as_bytes(), hash, 0);
    event["type"] = json!("published");
    inner.emit(event);
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

// MARK: - C interface

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
