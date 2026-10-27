//! Interface for the web app: the node runs on the page's event loop with in-memory stores. Browsers
//! can't host the replica database, so the page saves `snapshot()` to origin storage and hands it back
//! on the next start; entries are re-signed with their original timestamps, so nothing looks newer.

use std::{str::FromStr, sync::Arc};

use anyhow::{Result, anyhow};
use iroh::{Endpoint, EndpointId, SecretKey, endpoint::presets};
use iroh_blobs::{Hash, store::mem::MemStore};
use iroh_docs::{
    AuthorId,
    engine::{DefaultAuthorStorage, Engine},
    protocol::Docs,
    store::{Query, Store},
};
use iroh_gossip::net::Gossip;
use n0_future::{StreamExt, task::spawn};
use wasm_bindgen::prelude::*;

use crate::{
    Inner, MAX_GOSSIP_MESSAGE, Parts, account_author, account_namespace, begin_join, bundle, hex, live, parse_hex32,
    shares,
    snapshot::{ReplicaSnapshot, SNAPSHOT_BLOB_LIMIT, SNAPSHOT_MAGIC, Snapshot, restore},
    space_author,
};

#[wasm_bindgen]
pub struct SyncNode {
    inner: Arc<Inner>,
}

fn js(err: anyhow::Error) -> JsError {
    JsError::new(&format!("{err:#}"))
}

fn key32(bytes: &[u8], what: &str) -> Result<[u8; 32], JsError> {
    bytes.try_into().map_err(|_| JsError::new(&format!("{what} must be 32 bytes")))
}

/// `[[id, bytes], …]` pairs from JavaScript.
fn pairs(array: &js_sys::Array, what: &str) -> Result<Vec<(String, Vec<u8>)>, JsError> {
    let mut out = Vec::with_capacity(array.length() as usize);
    for item in array.iter() {
        let pair = js_sys::Array::from(&item);
        let id = pair.get(0).as_string().ok_or_else(|| JsError::new(&format!("{what}: an id isn't a string")))?;
        let bytes = js_sys::Uint8Array::new(&pair.get(1)).to_vec();
        out.push((id, bytes));
    }
    Ok(out)
}

fn to_pairs(items: impl IntoIterator<Item = (String, Vec<u8>)>) -> js_sys::Array {
    let out = js_sys::Array::new();
    for (id, bytes) in items {
        out.push(&js_sys::Array::of2(&JsValue::from_str(&id), &js_sys::Uint8Array::from(bytes.as_slice())));
    }
    out
}

#[wasm_bindgen]
impl SyncNode {
    /// Starts syncing for the 32-byte `account` as the device with the 32-byte `device_key`, from the
    /// last `snapshot` if any. `callback` receives every event as a JSON string.
    pub async fn start(
        device_key: Vec<u8>,
        account: Vec<u8>,
        snapshot: Option<Vec<u8>>,
        callback: js_sys::Function,
    ) -> Result<SyncNode, JsError> {
        let account = key32(&account, "account")?;
        let device_key = SecretKey::from_bytes(&key32(&device_key, "device key")?);
        let endpoint = Endpoint::builder(presets::N0).secret_key(device_key).bind().await.map_err(|e| JsError::new(&e.to_string()))?;
        let mem = MemStore::new();
        let blobs = (*mem).clone();
        let mut store = Store::memory();
        let mut carried = Vec::new();
        if let Some(bytes) = snapshot.filter(|b| !b.is_empty()) {
            // A snapshot that doesn't read starts over; peers bring everything back.
            match restore(&mut store, &account, &bytes).await {
                Ok(blobs) => carried = blobs,
                Err(err) => warn(&format!("Typewright: discarded sync snapshot: {err:#}")),
            }
        }
        for blob in carried {
            blobs.add_bytes(blob).await.map_err(|e| js(e.into()))?;
        }
        let gossip = Gossip::builder().max_message_size(MAX_GOSSIP_MESSAGE).spawn(endpoint.clone());
        let downloader = blobs.downloader(&endpoint);
        let engine =
            Engine::spawn(endpoint.clone(), gossip.clone(), store, blobs.clone(), downloader, DefaultAuthorStorage::Mem, None)
                .await
                .map_err(js)?;
        let docs = Docs::new(engine);
        let sink = Box::new(move |event: &str| {
            let _ = callback.call1(&JsValue::NULL, &JsValue::from_str(event));
        });
        let inner = crate::start(Parts { endpoint, store: Box::new(mem), blobs, gossip, docs }, account, sink).await.map_err(js)?;
        Ok(SyncNode { inner })
    }

    pub async fn stop(&self) {
        self.inner.endpoint.close().await;
    }

    #[wasm_bindgen(js_name = deviceId)]
    pub fn device_id(&self) -> String {
        self.inner.endpoint.id().to_string()
    }

    fn spawn(&self, label: &'static str, task: impl Future<Output = Result<()>> + 'static) {
        let inner = self.inner.clone();
        spawn(async move {
            if let Err(err) = task.await {
                inner.error(label, err);
            }
        });
    }

    /// Lists the share (`kind` "space", "folder" or "file") for all devices of the account and starts syncing it
    /// here; `device` labels this device's side of conflicts elsewhere.
    #[wasm_bindgen(js_name = addShare)]
    pub fn add_share(&self, share: String, name: String, kind: String, device: String) {
        self.spawn("add share", shares::add_share(self.inner.clone(), share, name, kind, device));
    }

    /// The hex secret an invite link to the share carries; marks it shared for all devices of the account.
    #[wasm_bindgen(js_name = shareInvite)]
    pub fn share_invite(&self, share: String, name: String, kind: String) -> String {
        let secret = self.inner.namespace(&share);
        self.spawn("invite", shares::invite_share(self.inner.clone(), share, name, kind));
        hex(&secret)
    }

    /// Changes device sync and public sharing; rotating disconnects holders of the old invite.
    #[wasm_bindgen(js_name = configureShare)]
    pub async fn configure_share(&self, share: String, devices: bool, shared: bool, rotate: bool) -> Result<(), JsError> {
        shares::configure_share(self.inner.clone(), share, devices, shared, rotate).await.map_err(js)
    }

    /// Starts syncing a share from another account's invite; `hints` are endpoint ids to dial first.
    #[wasm_bindgen(js_name = joinShare)]
    pub fn join_share(
        &self,
        share: String,
        name: String,
        kind: String,
        secret: String,
        hints: Vec<String>,
        device: String,
    ) -> Result<(), JsError> {
        let secret = parse_hex32(&secret).ok_or_else(|| JsError::new("invalid secret"))?;
        let hints = hints.iter().filter_map(|h| EndpointId::from_str(h.trim()).ok()).collect();
        begin_join(&self.inner, &share, secret, hints);
        self.spawn("join share", shares::join_share(self.inner.clone(), share, name, kind, secret, device));
        Ok(())
    }

    /// Starts syncing a share listed by the account; answers with `head` events for the other devices' heads.
    #[wasm_bindgen(js_name = openShare)]
    pub fn open_share(&self, share: String, device: String) {
        self.spawn("open share", shares::open_share(self.inner.clone(), share, device));
    }

    /// Stops syncing a share on this device; a share nobody syncs leaves the account.
    #[wasm_bindgen(js_name = closeShare)]
    pub fn close_share(&self, share: String) {
        self.spawn("close share", shares::leave_share(self.inner.clone(), share));
    }

    /// Stops syncing a share on every device of the account; the files stay everywhere.
    #[wasm_bindgen(js_name = removeShare)]
    pub fn remove_share(&self, share: String) {
        self.spawn("remove share", shares::remove_share(self.inner.clone(), share));
    }

    /// Reports the other devices' heads again (`head` events).
    #[wasm_bindgen(js_name = listHeads)]
    pub fn list_heads(&self, share: String) {
        let inner = self.inner.clone();
        self.spawn("list heads", async move { shares::list_heads(&inner, &share).await });
    }

    /// Publishes a node as this device's head: `manifest` from `twj_export_node`, `objects` the `[oid, bytes]` pairs
    /// `twj_write_objects` wrote for it, and `lfs` `[blake3, bytes]` pairs of its LFS files (the browser keeps no
    /// blobs across reloads, so they're seeded again; ones the replica already lists may be left out).
    #[wasm_bindgen(js_name = publishNode)]
    pub async fn publish_node(&self, share: String, manifest: String, objects: js_sys::Array, lfs: js_sys::Array) -> Result<(), JsError> {
        let manifest: serde_json::Value = serde_json::from_str(&manifest).map_err(|e| js(e.into()))?;
        let objects = pairs(&objects, "objects")?;
        let bytes = bundle::encode(&manifest, &objects).map_err(js)?;
        let seeded = self.seed(&share, &lfs).await?;
        let wanted = bundle::lfs_hashes(&manifest);
        if let Some(missing) = pairs(&lfs, "lfs")?.into_iter().map(|(h, _)| h).find(|h| wanted.contains(h) && !seeded.contains(h)) {
            return Err(JsError::new(&format!("LFS file {missing} changed while it was published")));
        }
        // Everything the bundle names was seeded above or is already listed, so nothing gets added here.
        shares::publish_node(self.inner.clone(), share, bytes, bundle::lfs_hashes(&manifest), |_, _, key| async move {
            Err(anyhow!("no content for {key}"))
        })
        .await
        .map_err(js)
    }

    /// Adds `lfs` (`[blake3, bytes]` pairs read from disk) to the blob store after a reload, without waiting for
    /// the next publish; returns the hashes that matched (a file edited since its node was published doesn't).
    #[wasm_bindgen(js_name = seedLfs)]
    pub async fn seed_lfs(&self, share: String, lfs: js_sys::Array) -> Result<Vec<String>, JsError> {
        self.seed(&share, &lfs).await
    }

    async fn seed(&self, share: &str, lfs: &js_sys::Array) -> Result<Vec<String>, JsError> {
        let mut added = Vec::new();
        for (hash, data) in pairs(lfs, "lfs")? {
            let tag = self.inner.blobs.add_bytes(data).await.map_err(|e| js(e.into()))?;
            if tag.hash.to_hex().to_string() == hash {
                added.push(tag.hash);
            }
        }
        shares::announce_lfs(&self.inner, share, &added).await.map_err(js)?;
        Ok(added.iter().map(|h| h.to_hex().to_string()).collect())
    }

    /// `device`'s current head: `{manifest: string, objects: [oid, bytes][], lfs: [blake3, bytes][]}`, without the
    /// LFS files in `skip` (this device holds them already).
    #[wasm_bindgen(js_name = fetchNode)]
    pub async fn fetch_node(&self, share: String, device: String, skip: Vec<String>) -> Result<JsValue, JsError> {
        let bundle = shares::head_bundle(&self.inner, &share, &device).await.map_err(js)?;
        let mut lfs = Vec::new();
        for hash in bundle::lfs_hashes(&bundle.manifest) {
            if skip.contains(&hash) {
                continue;
            }
            let parsed = Hash::from_str(&hash).map_err(|e| JsError::new(&e.to_string()))?;
            let bytes = self.inner.blobs.get_bytes(parsed).await.map_err(|e| js(e.into()))?;
            lfs.push((hash, bytes.to_vec()));
        }
        let out = js_sys::Object::new();
        let manifest = serde_json::to_string(&bundle.manifest).map_err(|e| js(e.into()))?;
        js_sys::Reflect::set(&out, &"manifest".into(), &manifest.into()).map_err(|_| JsError::new("fetch"))?;
        js_sys::Reflect::set(&out, &"objects".into(), &to_pairs(bundle.objects)).map_err(|_| JsError::new("fetch"))?;
        js_sys::Reflect::set(&out, &"lfs".into(), &to_pairs(lfs)).map_err(|_| JsError::new("fetch"))?;
        Ok(out.into())
    }

    /// Starts live editing of a file shown in an editor: `share` and the path inside it (`@file` for a file share);
    /// `name` labels this device's cursor elsewhere.
    #[wasm_bindgen(js_name = liveOpen)]
    pub fn live_open(&self, share: String, path: String, text: String, name: String) {
        live::open(&self.inner, &share, &path, &text, &name);
    }

    #[wasm_bindgen(js_name = liveClose)]
    pub fn live_close(&self, share: String, path: String) {
        live::close(&self.inner, &share, &path);
    }

    /// Hands over the editor's text and selection (UTF-16) and returns JSON with remote `edits`, an
    /// `adopted` session to merge into, the other `cursors` and `peers`. `step` 1 undoes, 2 redoes.
    #[wasm_bindgen(js_name = liveSync)]
    pub fn live_sync(&self, share: String, path: String, text: String, location: u32, length: u32, step: i32) -> String {
        let step = match step {
            1 => live::Step::Undo,
            2 => live::Step::Redo,
            _ => live::Step::None,
        };
        live::sync(&self.inner, &share, &path, &text, (location, length), step).to_string()
    }

    /// The account replica and every open share's, for `start` after the page reloads.
    pub async fn snapshot(&self) -> Result<Vec<u8>, JsError> {
        self.snapshot_inner().await.map_err(js)
    }

    async fn snapshot_inner(&self) -> Result<Vec<u8>> {
        let inner = &self.inner;
        // (namespace, author secret, replica)
        let mut docs = vec![(account_namespace(&inner.account).to_bytes(), inner.account, inner.account_doc.clone())];
        let open: Vec<(String, iroh_docs::api::Doc)> =
            inner.shares.lock().unwrap().iter().map(|(id, s)| (id.clone(), s.doc.clone())).collect();
        for (id, doc) in open {
            let secret = inner.namespace(&id);
            docs.push((shares::share_namespace(&secret).to_bytes(), secret, doc));
        }
        let mut snapshot = Snapshot { replicas: Vec::new(), blobs: Vec::new() };
        let mut carried = std::collections::HashSet::new();
        let own = account_author(&inner.account).id();
        for (namespace, author, doc) in docs {
            let signers: [AuthorId; 2] = [own, space_author(&author).id()];
            let mut replica = ReplicaSnapshot { namespace, author, entries: Vec::new() };
            let entries = doc.get_many(Query::all().include_empty().build()).await?;
            tokio::pin!(entries);
            while let Some(entry) = entries.next().await {
                let entry = entry?;
                // Entries of authors this account can't sign as come back from peers instead.
                if !signers.contains(&entry.author()) {
                    continue;
                }
                let hash = entry.content_hash();
                replica.entries.push((
                    *entry.author().as_bytes(),
                    entry.key().to_vec(),
                    *hash.as_bytes(),
                    entry.content_len(),
                    entry.timestamp(),
                ));
                if entry.content_len() > 0 && entry.content_len() <= SNAPSHOT_BLOB_LIMIT && carried.insert(hash) {
                    if let Ok(bytes) = inner.blobs.get_bytes(hash).await {
                        snapshot.blobs.push(bytes.to_vec());
                    }
                }
            }
            snapshot.replicas.push(replica);
        }
        let mut out = SNAPSHOT_MAGIC.to_vec();
        out.extend(postcard::to_allocvec(&snapshot)?);
        Ok(out)
    }
}

/// BLAKE3 of `bytes`, hex encoded as blob hashes are.
#[wasm_bindgen(js_name = hashBytes)]
pub fn hash_bytes(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

/// A fresh device key.
#[wasm_bindgen(js_name = generateDeviceKey)]
pub fn generate_device_key() -> Vec<u8> {
    SecretKey::generate().to_bytes().to_vec()
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console)]
    fn warn(message: &str);
}
