//! Syncs space folders between the devices of one account over iroh, and with the other accounts a
//! space was shared with through an invite link.
//!
//! Every key is derived from the account secret (the passkey's PRF output), so each device of the
//! account finds the others and opens the same replicas without exchanging anything:
//! - a pkarr record lists the account's devices, for dialing,
//! - an account replica lists the synced spaces (`space/<id>` → `{"name": …}`, plus `"shared"` once
//!   an invite exists and the namespace `"secret"` for spaces joined from another account's link),
//! - one replica per space maps relative paths to blob hashes; everyone writes as one author derived
//!   from the space's secret, so the newest write of a path wins,
//! - shared spaces have their own pkarr record, keyed by the space's secret, listing every device
//!   (of any account) syncing them,
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
    spaces: Mutex<HashMap<String, Space>>,
    /// What the account replica says about each space's keys.
    infos: Mutex<HashMap<String, SpaceInfo>>,
    /// Devices of other accounts syncing a shared space, from its record or the invite's hints.
    space_devices: Mutex<HashMap<String, Vec<EndpointId>>>,
    topics: Mutex<HashMap<String, live::Topic>>,
    live: Mutex<HashMap<(String, String), live::Session>>,
    /// Serializes opening spaces, so each is subscribed once.
    opening: tokio::sync::Mutex<()>,
    neighbors: Mutex<HashSet<EndpointId>>,
    devices: Mutex<Vec<EndpointId>>,
    callback: EventCallback,
    context: usize,
}

#[derive(Clone)]
struct Space {
    doc: Doc,
    author: AuthorId,
}

#[derive(Clone, Default, PartialEq)]
struct SpaceInfo {
    /// Set for spaces joined from a link; others derive theirs from the account.
    secret: Option<[u8; 32]>,
    shared: bool,
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
        // Devices of any account listed for each shared space.
        let shared: HashMap<String, Vec<String>> = self
            .space_devices
            .lock()
            .unwrap()
            .iter()
            .map(|(id, devices)| (id.clone(), devices.iter().map(|d| d.to_string()).collect()))
            .collect();
        self.emit(json!({
            "type": "status", "device": self.endpoint.id().to_string(), "peers": peers, "devices": devices, "shared": shared,
        }));
    }

    fn peer_addrs(&self) -> Vec<EndpointAddr> {
        let me = self.endpoint.id();
        self.devices.lock().unwrap().iter().filter(|d| **d != me).map(|d| EndpointAddr::from(*d)).collect()
    }

    /// The account's devices plus, for shared spaces, everyone else syncing it.
    fn space_peers(&self, id: &str) -> Vec<EndpointId> {
        let me = self.endpoint.id();
        let mut peers: Vec<EndpointId> = self.devices.lock().unwrap().clone();
        if self.is_shared(id) {
            peers.extend(self.space_devices.lock().unwrap().get(id).cloned().unwrap_or_default());
        }
        let mut seen = HashSet::new();
        peers.retain(|p| *p != me && seen.insert(*p));
        peers
    }

    fn namespace(&self, id: &str) -> [u8; 32] {
        self.infos.lock().unwrap().get(id).and_then(|info| info.secret).unwrap_or_else(|| space_secret(&self.account, id))
    }

    fn is_shared(&self, id: &str) -> bool {
        self.infos.lock().unwrap().get(id).is_some_and(|info| info.shared || info.secret.is_some())
    }
}

fn derive(context: &str, parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = blake3::Hasher::new_derive_key(context);
    for part in parts {
        hasher.update(part);
    }
    *hasher.finalize().as_bytes()
}

fn space_secret(account: &[u8; 32], id: &str) -> [u8; 32] {
    derive("typewright 2026-10 space v0", &[account, id.as_bytes()])
}

/// Everyone with the space's secret writes as this author; entries of the account author from
/// before still count, as the newest entry of a key wins across authors.
fn space_author(secret: &[u8; 32]) -> Author {
    Author::from_bytes(&derive("typewright 2026-10 space author v0", &[secret]))
}

/// Key of the shared space's pkarr record listing the devices syncing it.
fn space_directory_key(secret: &[u8; 32]) -> SecretKey {
    SecretKey::from_bytes(&derive("typewright 2026-10 space directory v0", &[secret]))
}

fn parse_hex32(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 || !text.is_ascii() {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A space's keys as its `space/<id>` entry in the account replica describes them.
fn space_info(value: &serde_json::Value) -> SpaceInfo {
    SpaceInfo {
        secret: value["secret"].as_str().and_then(parse_hex32),
        shared: value["shared"].as_bool().unwrap_or(false),
    }
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
        infos: Mutex::new(HashMap::new()),
        space_devices: Mutex::new(HashMap::new()),
        topics: Mutex::new(HashMap::new()),
        live: Mutex::new(HashMap::new()),
        opening: tokio::sync::Mutex::new(()),
        neighbors: Mutex::new(HashSet::new()),
        devices: Mutex::new(Vec::new()),
        callback,
        context,
    });
    // Joined spaces' secrets have to be known before Swift opens them.
    if let Err(err) = emit_spaces(&inner).await {
        inner.error("account replica", err);
    }
    tokio::spawn(watch_account(inner.clone()));
    tokio::spawn(directory_loop(inner.clone()));
    inner.status();
    Ok(inner)
}

/// Keeps this device in the account's pkarr record, and in those of its shared spaces, and syncs
/// every replica with the devices listed there.
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

fn pkarr_client(inner: &Inner) -> Result<PkarrRelayClient> {
    Ok(PkarrRelayClient::new(
        N0_DNS_PKARR_RELAY_PROD.parse()?,
        inner.endpoint.tls_config().clone(),
        inner.endpoint.dns_resolver()?.clone(),
    ))
}

/// Adds this device to the record (or takes it out with `leave`) and returns the devices it lists.
async fn update_record(
    inner: &Inner,
    client: &PkarrRelayClient,
    key: &SecretKey,
    republish: bool,
    leave: bool,
) -> Result<Vec<EndpointId>> {
    let mut ids: Vec<String> = match client.resolve(key.public()).await {
        Ok(packet) => packet.txt_records(DIRECTORY_NAME),
        Err(_) => Vec::new(),
    };
    let me = inner.endpoint.id().to_string();
    let changed = if leave {
        let listed = ids.contains(&me);
        ids.retain(|id| *id != me);
        listed
    } else if !ids.contains(&me) || republish {
        // Concurrent publishes can drop a device; it adds itself back on its next round.
        ids.retain(|id| *id != me);
        ids.push(me);
        while ids.len() > MAX_DEVICES {
            ids.remove(0);
        }
        true
    } else {
        false
    };
    if changed {
        let packet = SignedPacket::from_txt_strings(key, DIRECTORY_NAME, &ids, 3600)?;
        client.publish(&packet).await?;
    }
    Ok(ids.iter().filter_map(|id| EndpointId::from_str(id).ok()).collect())
}

async fn refresh_directory(inner: &Inner, key: &SecretKey, republish: bool) -> Result<()> {
    let client = pkarr_client(inner)?;
    *inner.devices.lock().unwrap() = update_record(inner, &client, key, republish, false).await?;
    let peers = inner.peer_addrs();
    if !peers.is_empty() {
        inner.account_doc.start_sync(peers).await?;
    }
    let spaces: Vec<(String, Doc)> = inner.spaces.lock().unwrap().iter().map(|(id, s)| (id.clone(), s.doc.clone())).collect();
    for (id, doc) in spaces {
        if inner.is_shared(&id) {
            refresh_space_directory(inner, &client, &id, republish).await;
        }
        sync_space(inner, &id, &doc).await?;
    }
    inner.status();
    Ok(())
}

/// Keeps this device listed in a shared space's record and remembers who else is.
async fn refresh_space_directory(inner: &Inner, client: &PkarrRelayClient, id: &str, republish: bool) {
    let key = space_directory_key(&inner.namespace(id));
    match update_record(inner, client, &key, republish, false).await {
        Ok(devices) => {
            let me = inner.endpoint.id();
            let mut all = inner.space_devices.lock().unwrap();
            let known = all.entry(id.to_string()).or_default();
            // The invite's hints stay until the record lists someone else.
            if devices.iter().any(|d| *d != me) || known.is_empty() {
                *known = devices;
            }
        }
        Err(err) => inner.error("space directory", err),
    }
}

/// Syncs the replica and the live topic with everyone known to sync the space. With nobody listed,
/// iroh-docs still dials the peers it last synced the replica with (it keeps a few per replica).
async fn sync_space(inner: &Inner, id: &str, doc: &Doc) -> Result<()> {
    let peers = inner.space_peers(id);
    doc.start_sync(peers.iter().map(|p| EndpointAddr::from(*p)).collect()).await?;
    if !peers.is_empty() {
        live::add_peers(inner, id, peers).await;
    }
    Ok(())
}

async fn watch_account(inner: Arc<Inner>) {
    let result: Result<()> = async {
        let mut events = inner.account_doc.subscribe().await?;
        emit_spaces(&inner).await?;
        while let Some(event) = events.next().await {
            match event? {
                LiveEvent::InsertLocal { .. } | LiveEvent::InsertRemote { .. } | LiveEvent::ContentReady { .. } => {
                    emit_spaces(&inner).await?;
                    live::retopic(&inner).await;
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
/// spaces removed from all devices (`removed/<space>`); remembers the spaces' keys on the way.
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
    let mut infos = HashMap::new();
    let entries = inner.account_doc.get_many(Query::single_latest_per_key().key_prefix("space/").build()).await?;
    tokio::pin!(entries);
    while let Some(entry) = entries.next().await {
        let entry = entry?;
        let id = String::from_utf8_lossy(&entry.key()[6..]).to_string();
        // Content arrives after the entry; the next ContentReady lists it.
        let Ok(bytes) = inner.blobs.get_bytes(entry.content_hash()).await else { continue };
        let Ok(mut info) = serde_json::from_slice::<serde_json::Value>(&bytes) else { continue };
        let keys = space_info(&info);
        info["shared"] = json!(keys.shared || keys.secret.is_some());
        if let Some(fields) = info.as_object_mut() {
            fields.remove("secret");
        }
        infos.insert(id.clone(), keys);
        info["members"] = json!(members.remove(&id).unwrap_or_default());
        info["id"] = json!(id);
        spaces.push(info);
    }
    {
        // Spaces syncing here keep their keys while their entry is missing, and joined secrets stay
        // known, as a join writes its entry after opening may already have asked.
        let mut known = inner.infos.lock().unwrap();
        let open = inner.spaces.lock().unwrap();
        known.retain(|id, info| (open.contains_key(id) || info.secret.is_some()) && !infos.contains_key(id));
        known.extend(infos);
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
    let space = inner.spaces.lock().unwrap().remove(&id);
    if let Some(space) = space {
        space.doc.leave().await?;
    }
    // Others sharing the space stop dialing this device.
    if inner.is_shared(&id) {
        let key = space_directory_key(&inner.namespace(&id));
        if let Err(err) = update_record(&inner, &pkarr_client(&inner)?, &key, false, true).await {
            inner.error("space directory", err);
        }
        inner.space_devices.lock().unwrap().remove(&id);
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
async fn space_doc(inner: &Arc<Inner>, id: &str) -> Result<Space> {
    let _guard = inner.opening.lock().await;
    if let Some(space) = inner.spaces.lock().unwrap().get(id).cloned() {
        return Ok(space);
    }
    let secret = inner.namespace(id);
    let author = space_author(&secret);
    inner.docs.author_import(author.clone()).await?;
    let doc = inner.docs.import_namespace(Capability::Write(NamespaceSecret::from_bytes(&secret))).await?;
    let events = doc.subscribe().await?;
    tokio::spawn(watch_space(inner.clone(), id.to_string(), doc.clone(), events));
    let space = Space { doc: doc.clone(), author: author.id() };
    inner.spaces.lock().unwrap().insert(id.to_string(), space.clone());
    inner.account_doc.set_bytes(inner.author, member_key(inner, id), b"1".to_vec()).await?;
    live::join(inner, id).await?;
    sync_space(inner, id, &doc).await?;
    if inner.is_shared(id) {
        // Listing this device and finding the others shouldn't wait for the next directory round.
        let inner = inner.clone();
        let id = id.to_string();
        tokio::spawn(async move {
            let Ok(client) = pkarr_client(&inner) else { return };
            refresh_space_directory(&inner, &client, &id, false).await;
            let _ = sync_space(&inner, &id, &doc).await;
        });
    }
    Ok(space)
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
                    // Only if nothing newer, by any author, replaced it meanwhile.
                    if let Ok(Some(entry)) = latest(&doc, &key).await {
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

async fn latest(doc: &Doc, key: &[u8]) -> Result<Option<iroh_docs::Entry>> {
    doc.get_one(Query::single_latest_per_key().key_exact(key).include_empty().build()).await
}

fn remote(space: &str, key: &[u8], hash: Hash, size: u64) -> serde_json::Value {
    let mut event = entry_json(space, key, hash, size);
    event["type"] = json!("remote");
    event
}

async fn list_space(inner: &Arc<Inner>, id: &str) -> Result<()> {
    let doc = space_doc(inner, id).await?.doc;
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

/// Marks an own space shared, so all devices of the account list themselves in its record.
async fn invite(inner: Arc<Inner>, id: String, name: String) -> Result<()> {
    let key = format!("space/{id}");
    let stored = match inner.account_doc.get_exact(inner.author, key.clone(), false).await? {
        Some(entry) => inner.blobs.get_bytes(entry.content_hash()).await.ok(),
        None => None,
    };
    let mut info: serde_json::Value =
        stored.and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_else(|| json!({"name": name}));
    if info["shared"].as_bool() != Some(true) {
        info["shared"] = json!(true);
        inner.account_doc.set_bytes(inner.author, key, serde_json::to_vec(&info)?).await?;
    }
    inner.infos.lock().unwrap().entry(id.clone()).or_default().shared = true;
    live::retopic(&inner).await;
    refresh_space_directory(&inner, &pkarr_client(&inner)?, &id, true).await;
    Ok(())
}

/// Starts syncing a space from another account's invite; the account replica keeps its secret for
/// this account's other devices.
async fn join_space(inner: Arc<Inner>, id: String, name: String, secret: [u8; 32]) -> Result<()> {
    // Joining again after "Remove From All Devices" brings it back.
    inner.account_doc.del(inner.author, format!("removed/{id}")).await?;
    inner.account_doc.set_bytes(inner.author, member_key(&inner, &id), b"1".to_vec()).await?;
    let info = serde_json::to_vec(&json!({"name": name, "secret": hex(&secret), "shared": true}))?;
    inner.account_doc.set_bytes(inner.author, format!("space/{id}"), info).await?;
    open_space(inner, id).await
}

async fn publish(inner: Arc<Inner>, id: String, path: String, file: PathBuf) -> Result<()> {
    let space = space_doc(&inner, &id).await?;
    let outcome = space
        .doc
        .import_file(&inner.blobs, space.author, Bytes::from(path.clone().into_bytes()), file, ImportMode::Copy)
        .await?
        .await?;
    let mut event = entry_json(&id, path.as_bytes(), outcome.hash, outcome.size);
    event["type"] = json!("published");
    inner.emit(event);
    Ok(())
}

async fn unpublish(inner: Arc<Inner>, id: String, path: String) -> Result<()> {
    let space = space_doc(&inner, &id).await?;
    let hash = space.doc.set_bytes(space.author, Bytes::from(path.clone().into_bytes()), TOMBSTONE).await?;
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
    node.inner.infos.lock().unwrap().insert(id.clone(), SpaceInfo { secret: Some(secret), shared: true });
    node.inner.space_devices.lock().unwrap().insert(id.clone(), hints);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips_and_rejects_junk() {
        let bytes: [u8; 32] = std::array::from_fn(|i| (i * 9) as u8);
        assert_eq!(parse_hex32(&hex(&bytes)), Some(bytes));
        assert_eq!(parse_hex32(&hex(&bytes).to_uppercase()), Some(bytes));
        assert_eq!(parse_hex32("00"), None);
        assert_eq!(parse_hex32(&"zz".repeat(32)), None);
        assert_eq!(parse_hex32(&"é".repeat(32)), None);
    }

    #[test]
    fn reads_space_keys_from_account_entries() {
        let secret = [3u8; 32];
        let joined = space_info(&json!({"name": "A", "secret": hex(&secret), "shared": true}));
        assert!(joined.secret == Some(secret) && joined.shared);
        assert!(space_info(&json!({"name": "B"})) == SpaceInfo::default());
    }

    #[test]
    fn own_spaces_keep_their_replica() {
        // Changing this derivation would orphan every synced space.
        let id = NamespaceSecret::from_bytes(&space_secret(&[7u8; 32], "abc")).id();
        let expected = NamespaceSecret::from_bytes(&derive("typewright 2026-10 space v0", &[&[7u8; 32], b"abc"])).id();
        assert_eq!(id, expected);
        assert_ne!(space_author(&[1u8; 32]).id(), space_author(&[2u8; 32]).id());
    }

    #[tokio::test]
    async fn newest_entry_wins_across_authors() -> Result<()> {
        let endpoint = Endpoint::builder(presets::Minimal).bind().await?;
        let blobs = iroh_blobs::store::mem::MemStore::new();
        let gossip = Gossip::builder().spawn(endpoint.clone());
        let docs = Docs::memory().spawn(endpoint.clone(), (*blobs).clone(), gossip).await?;
        let doc = docs.import_namespace(Capability::Write(NamespaceSecret::from_bytes(&[5u8; 32]))).await?;
        // Entries of the account author from before space authors still resolve by time.
        let old = Author::from_bytes(&[1u8; 32]);
        let new = space_author(&[5u8; 32]);
        docs.author_import(old.clone()).await?;
        docs.author_import(new.clone()).await?;
        doc.set_bytes(old.id(), "main.typ", "old").await?;
        doc.set_bytes(new.id(), "main.typ", "new").await?;
        doc.set_bytes(new.id(), "other.typ", "x").await?;
        doc.set_bytes(old.id(), "other.typ", "y").await?;
        let main = latest(&doc, b"main.typ").await?.unwrap();
        assert_eq!(main.content_hash(), Hash::new("new"));
        assert_eq!(main.author(), new.id());
        assert_eq!(latest(&doc, b"other.typ").await?.unwrap().content_hash(), Hash::new("y"));
        assert!(latest(&doc, b"missing").await?.is_none());
        endpoint.close().await;
        Ok(())
    }
}
