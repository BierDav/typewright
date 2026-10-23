//! Syncs shares (spaces, or any folder or file in one) between the devices of one account over iroh, and with the
//! other accounts a share was shared with through an invite link.
//!
//! Every key is derived from the account secret (the passkey's PRF output), so each device of the
//! account finds the others and opens the same replicas without exchanging anything:
//! - a pkarr record lists the account's devices, for dialing,
//! - an account replica lists the synced shares (`share/<id>` → `{"name", "kind"}`, plus `"shared"` once an invite
//!   exists and the namespace `"secret"` for shares joined from another account's link); spaces listed the old way
//!   (`space/<id>`, before shares) are listed again as shares with the same id and keys,
//! - each share has a replica holding every device's head, a jj node bundle (see `shares` and `bundle`),
//! - shared shares have their own pkarr record, keyed by the share's secret, listing every device
//!   (of any account) syncing them,
//! - one gossip topic per share carries live edits and cursors of open files (see `live`).
//!
//! Events reach Swift (`ffi`) or the web app (`web`) as JSON strings through one callback.

use std::{
    collections::{HashMap, HashSet},
    str::FromStr,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::Result;
use iroh::{
    Endpoint, EndpointAddr, EndpointId, SecretKey,
    address_lookup::{N0_DNS_PKARR_RELAY_PROD, PkarrRelayClient},
    protocol::Router,
};
use iroh_blobs::{BlobsProtocol, Hash};
use iroh_dns::pkarr::SignedPacket;
use iroh_docs::{
    Author, AuthorId, Capability, NamespaceSecret, api::Doc, engine::LiveEvent, protocol::Docs, store::Query,
};
use iroh_gossip::net::Gossip;
use n0_future::{StreamExt, task::spawn, time::sleep};
use serde_json::json;

pub mod bundle;
#[cfg(not(target_arch = "wasm32"))]
mod ffi;
mod live;
mod shares;
#[cfg(target_arch = "wasm32")]
mod web;

#[cfg(not(target_arch = "wasm32"))]
pub use ffi::*;
#[cfg(target_arch = "wasm32")]
pub use web::*;

const DIRECTORY_NAME: &str = "_devices";
/// Records hold at most 1000 bytes; the oldest devices drop out first.
const MAX_DEVICES: usize = 12;
/// Live sessions send whole documents when they meet; files larger than this sync on save only.
pub(crate) const MAX_GOSSIP_MESSAGE: usize = 1 << 20;

/// Receives every event as JSON; the browser is single threaded, so its sink needn't be `Send`.
#[cfg(not(target_arch = "wasm32"))]
pub(crate) type Sink = Box<dyn Fn(&str) + Send + Sync>;
#[cfg(target_arch = "wasm32")]
pub(crate) type Sink = Box<dyn Fn(&str)>;

#[cfg(not(target_arch = "wasm32"))]
pub(crate) type Owner = Box<dyn std::any::Any + Send + Sync>;
#[cfg(target_arch = "wasm32")]
pub(crate) type Owner = Box<dyn std::any::Any>;

/// What a node runs on; the stores differ per platform.
pub(crate) struct Parts {
    pub endpoint: Endpoint,
    /// Keeps the store's owner alive; `blobs` is its API.
    pub store: Owner,
    pub blobs: iroh_blobs::api::Store,
    pub gossip: Gossip,
    pub docs: Docs,
}

pub(crate) struct Inner {
    endpoint: Endpoint,
    _router: Router,
    _store: Owner,
    blobs: iroh_blobs::api::Store,
    docs: Docs,
    author: AuthorId,
    account: [u8; 32],
    account_doc: Doc,
    gossip: Gossip,
    /// Opened share replicas by share id.
    shares: Mutex<HashMap<String, Space>>,
    /// Heads per share whose bundle or LFS files haven't arrived yet: device → bundle hash.
    waiting: Mutex<HashMap<String, HashMap<String, Hash>>>,
    /// What the account replica says about each share's keys.
    infos: Mutex<HashMap<String, SpaceInfo>>,
    /// Devices of other accounts syncing a shared share, from its record or the invite's hints.
    space_devices: Mutex<HashMap<String, Vec<EndpointId>>>,
    topics: Mutex<HashMap<String, live::Topic>>,
    live: Mutex<HashMap<(String, String), live::Session>>,
    /// Serializes opening shares, so each is subscribed once.
    opening: tokio::sync::Mutex<()>,
    neighbors: Mutex<HashSet<EndpointId>>,
    devices: Mutex<Vec<EndpointId>>,
    sink: Sink,
}

// The browser runs everything on one thread, where `Send` and `Sync` are never exercised.
#[cfg(target_arch = "wasm32")]
unsafe impl Send for Inner {}
#[cfg(target_arch = "wasm32")]
unsafe impl Sync for Inner {}

#[derive(Clone)]
pub(crate) struct Space {
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
        (self.sink)(&event.to_string());
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

pub(crate) fn derive(context: &str, parts: &[&[u8]]) -> [u8; 32] {
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
pub(crate) fn space_author(secret: &[u8; 32]) -> Author {
    Author::from_bytes(&derive("typewright 2026-10 space author v0", &[secret]))
}

/// Key of the shared space's pkarr record listing the devices syncing it.
pub(crate) fn space_directory_key(secret: &[u8; 32]) -> SecretKey {
    SecretKey::from_bytes(&derive("typewright 2026-10 space directory v0", &[secret]))
}

pub(crate) fn parse_hex32(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 || !text.is_ascii() {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A space's keys as its `space/<id>` entry in the account replica describes them.
fn space_info(value: &serde_json::Value) -> SpaceInfo {
    SpaceInfo {
        secret: value["secret"].as_str().and_then(parse_hex32),
        shared: value["shared"].as_bool().unwrap_or(false),
    }
}

pub(crate) fn account_author(account: &[u8; 32]) -> Author {
    Author::from_bytes(&derive("typewright 2026-10 author v0", &[account]))
}

pub(crate) fn account_namespace(account: &[u8; 32]) -> NamespaceSecret {
    NamespaceSecret::from_bytes(&derive("typewright 2026-10 account v0", &[account]))
}

/// Starts the node on platform specific parts; the device key is the endpoint's, only the account keys are shared.
pub(crate) async fn start(parts: Parts, account: [u8; 32], sink: Sink) -> Result<Arc<Inner>> {
    let Parts { endpoint, store, blobs, gossip, docs } = parts;
    let router = Router::builder(endpoint.clone())
        .accept(iroh_blobs::ALPN, BlobsProtocol::new(&blobs, None))
        .accept(iroh_gossip::ALPN, gossip.clone())
        .accept(iroh_docs::ALPN, docs.clone())
        .spawn();

    let author = account_author(&account);
    docs.author_import(author.clone()).await?;
    let account_doc = docs.import_namespace(Capability::Write(account_namespace(&account))).await?;

    let inner = Arc::new(Inner {
        endpoint,
        _router: router,
        _store: store,
        blobs,
        docs,
        author: author.id(),
        account,
        account_doc,
        gossip,
        shares: Mutex::new(HashMap::new()),
        waiting: Mutex::new(HashMap::new()),
        infos: Mutex::new(HashMap::new()),
        space_devices: Mutex::new(HashMap::new()),
        topics: Mutex::new(HashMap::new()),
        live: Mutex::new(HashMap::new()),
        opening: tokio::sync::Mutex::new(()),
        neighbors: Mutex::new(HashSet::new()),
        devices: Mutex::new(Vec::new()),
        sink,
    });
    // Joined shares' secrets have to be known before the app opens them.
    if let Err(err) = emit_shares(&inner).await {
        inner.error("account replica", err);
    }
    spawn(watch_account(inner.clone()));
    spawn(directory_loop(inner.clone()));
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
        sleep(Duration::from_secs(if round < 3 { 10 } else { 60 })).await;
    }
}

pub(crate) fn pkarr_client(inner: &Inner) -> Result<PkarrRelayClient> {
    #[cfg(not(target_arch = "wasm32"))]
    return Ok(PkarrRelayClient::new(
        N0_DNS_PKARR_RELAY_PROD.parse()?,
        inner.endpoint.tls_config().clone(),
        inner.endpoint.dns_resolver()?.clone(),
    ));
    #[cfg(target_arch = "wasm32")]
    {
        let _ = inner;
        Ok(PkarrRelayClient::new(N0_DNS_PKARR_RELAY_PROD.parse()?))
    }
}

/// Adds this device to the record (or takes it out with `leave`) and returns the devices it lists.
pub(crate) async fn update_record(
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
    let shares: Vec<(String, Doc)> = inner.shares.lock().unwrap().iter().map(|(id, s)| (id.clone(), s.doc.clone())).collect();
    for (id, doc) in shares {
        if inner.is_shared(&id) {
            refresh_space_directory(inner, &client, &id, republish).await;
        }
        sync_space(inner, &id, &doc).await?;
    }
    inner.status();
    Ok(())
}

/// Keeps this device listed in a shared space's record and remembers who else is.
pub(crate) async fn refresh_space_directory(inner: &Inner, client: &PkarrRelayClient, id: &str, republish: bool) {
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
pub(crate) async fn sync_space(inner: &Inner, id: &str, doc: &Doc) -> Result<()> {
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
        emit_shares(&inner).await?;
        while let Some(event) = events.next().await {
            match event? {
                LiveEvent::InsertLocal { .. } | LiveEvent::InsertRemote { .. } | LiveEvent::ContentReady { .. } => {
                    emit_shares(&inner).await?;
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

pub(crate) fn track(inner: &Inner, peer: EndpointId, up: bool) {
    let mut neighbors = inner.neighbors.lock().unwrap();
    if up { neighbors.insert(peer) } else { neighbors.remove(&peer) };
    drop(neighbors);
    inner.status();
}

/// Lists the account's shares with the devices syncing each (`member/<share>/<device>`), and the
/// shares removed from all devices (`removed/<share>`); remembers the shares' keys on the way.
async fn emit_shares(inner: &Inner) -> Result<()> {
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
    let mut infos = HashMap::new();
    let raw_spaces = account_entries(inner, "space/").await?;
    let raw_shares = account_entries(inner, "share/").await?;
    for (id, info) in &raw_spaces {
        infos.insert(id.clone(), space_info(info));
    }
    // A share's keys win over the space it was migrated from (the same, unless it was joined again).
    for (id, info) in &raw_shares {
        infos.insert(id.clone(), space_info(info));
    }
    {
        // Shares syncing here keep their keys while their entry is missing, and joined secrets stay
        // known, as a join writes its entry after opening may already have asked.
        let mut known = inner.infos.lock().unwrap();
        let shares = inner.shares.lock().unwrap();
        known.retain(|id, info| (shares.contains_key(id) || info.secret.is_some()) && !infos.contains_key(id));
        known.extend(infos);
    }
    let (shares, migrate) = shares::share_list(raw_shares, &raw_spaces, &members);
    // Spaces listed before shares become space shares for all devices.
    for (id, info) in migrate {
        inner.account_doc.set_bytes(inner.author, format!("share/{id}"), serde_json::to_vec(&info)?).await?;
    }
    inner.emit(json!({"type": "shares", "shares": shares, "removed": removed}));
    Ok(())
}

/// The account replica's JSON entries under `prefix` by id; entries whose content hasn't arrived yet are skipped
/// (the next ContentReady lists them).
async fn account_entries(inner: &Inner, prefix: &str) -> Result<Vec<(String, serde_json::Value)>> {
    let mut out = Vec::new();
    let entries = inner.account_doc.get_many(Query::single_latest_per_key().key_prefix(prefix).build()).await?;
    tokio::pin!(entries);
    while let Some(entry) = entries.next().await {
        let entry = entry?;
        let id = String::from_utf8_lossy(&entry.key()[prefix.len()..]).to_string();
        let Ok(bytes) = inner.blobs.get_bytes(entry.content_hash()).await else { continue };
        let Ok(info) = serde_json::from_slice::<serde_json::Value>(&bytes) else { continue };
        out.push((id, info));
    }
    Ok(out)
}

pub(crate) fn member_key(inner: &Inner, space: &str) -> String {
    format!("member/{space}/{}", inner.endpoint.id())
}

pub(crate) async fn latest(doc: &Doc, key: &[u8]) -> Result<Option<iroh_docs::Entry>> {
    doc.get_one(Query::single_latest_per_key().key_exact(key).include_empty().build()).await
}

/// Remembers a joined share's keys and the devices its invite named, before anything opens it.
pub(crate) fn begin_join(inner: &Inner, id: &str, secret: [u8; 32], hints: Vec<EndpointId>) {
    inner.infos.lock().unwrap().insert(id.to_string(), SpaceInfo { secret: Some(secret), shared: true });
    inner.space_devices.lock().unwrap().insert(id.to_string(), hints);
}

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use iroh::endpoint::presets;

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
