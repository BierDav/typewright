//! Interface for the web app: the node runs on the page's event loop with in-memory stores. Browsers
//! can't host the replica database, so the page saves `snapshot()` to origin storage and hands it back
//! on the next start; entries are re-signed with their original timestamps, so nothing looks newer.

use std::{str::FromStr, sync::Arc};

use anyhow::Result;
use iroh::{Endpoint, EndpointId, SecretKey, endpoint::presets};
use iroh_blobs::{Hash, store::mem::MemStore};
use iroh_docs::{
    Author, AuthorId, Capability, ContentStatus, NamespaceSecret, Record, RecordIdentifier,
    engine::{DefaultAuthorStorage, Engine},
    protocol::Docs,
    store::{Query, Store},
};
use iroh_gossip::net::Gossip;
use n0_future::{StreamExt, task::spawn};
use serde::{Deserialize, Serialize};
use wasm_bindgen::prelude::*;

use crate::{
    Inner, MAX_GOSSIP_MESSAGE, Parts, TOMBSTONE, account_author, account_namespace, begin_join, hex, invite,
    join_space, leave_space, list_space, live, open_space, parse_hex32, publish_bytes, remove_space, share_space,
    space_author, unpublish,
};

/// Blobs up to this size ride along in snapshots: account entries, and the bases of text merges.
const SNAPSHOT_BLOB_LIMIT: u64 = 256 * 1024;

#[derive(Serialize, Deserialize)]
struct Snapshot {
    replicas: Vec<ReplicaSnapshot>,
    blobs: Vec<Vec<u8>>,
}

#[derive(Serialize, Deserialize)]
struct ReplicaSnapshot {
    secret: [u8; 32],
    /// Author, key, content hash, length and timestamp of every entry.
    entries: Vec<([u8; 32], Vec<u8>, [u8; 32], u64, u64)>,
}

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

/// Authors this account can sign as: its own, and every replica's space author.
fn authors(account: &[u8; 32], secrets: &[[u8; 32]]) -> Vec<Author> {
    std::iter::once(account_author(account)).chain(secrets.iter().map(space_author)).collect()
}

/// Rebuilds the replicas a snapshot describes; returns the blobs it carried.
async fn restore(store: &mut Store, account: &[u8; 32], bytes: &[u8]) -> Result<Vec<Vec<u8>>> {
    let snapshot: Snapshot = postcard::from_bytes(bytes)?;
    let secrets: Vec<[u8; 32]> = snapshot.replicas.iter().map(|r| r.secret).collect();
    let authors = authors(account, &secrets);
    for replica in &snapshot.replicas {
        let namespace = NamespaceSecret::from_bytes(&replica.secret);
        store.import_namespace(Capability::Write(namespace.clone()))?;
        let mut open = store.open_replica(&namespace.id())?;
        for (author, key, hash, len, timestamp) in &replica.entries {
            let Some(author) = authors.iter().find(|a| a.id().as_bytes() == author) else { continue };
            let id = RecordIdentifier::new(namespace.id(), author.id(), key);
            let entry = iroh_docs::Entry::new(id, Record::new(Hash::from_bytes(*hash), *len, *timestamp));
            let _ = open.insert_remote_entry(entry.sign(&namespace, author), [0; 32], ContentStatus::Complete).await;
        }
        drop(open);
        store.close_replica(namespace.id());
    }
    store.flush()?;
    Ok(snapshot.blobs)
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
        blobs.add_bytes(TOMBSTONE.to_vec()).await.map_err(|e| js(e.into()))?;
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

    /// Lists the space for all devices of the account and starts syncing it here.
    #[wasm_bindgen(js_name = shareSpace)]
    pub fn share_space(&self, space: String, name: String) {
        self.spawn("share space", share_space(self.inner.clone(), space, name));
    }

    /// The hex secret an invite link carries; marks the space shared for all devices of the account.
    pub fn invite(&self, space: String, name: String) -> String {
        let secret = self.inner.namespace(&space);
        self.spawn("invite", invite(self.inner.clone(), space, name));
        hex(&secret)
    }

    /// Starts syncing a space from another account's invite; `hints` are endpoint ids to dial first.
    #[wasm_bindgen(js_name = joinSpace)]
    pub fn join_space(&self, space: String, name: String, secret: String, hints: Vec<String>) -> Result<(), JsError> {
        let secret = parse_hex32(&secret).ok_or_else(|| JsError::new("invalid secret"))?;
        let hints = hints.iter().filter_map(|h| EndpointId::from_str(h.trim()).ok()).collect();
        begin_join(&self.inner, &space, secret, hints);
        self.spawn("join space", join_space(self.inner.clone(), space, name, secret));
        Ok(())
    }

    /// Starts syncing a space listed by the account; answers with an `entries` event.
    #[wasm_bindgen(js_name = openSpace)]
    pub fn open_space(&self, space: String) {
        self.spawn("open space", open_space(self.inner.clone(), space));
    }

    #[wasm_bindgen(js_name = closeSpace)]
    pub fn close_space(&self, space: String) {
        self.spawn("close space", leave_space(self.inner.clone(), space));
    }

    #[wasm_bindgen(js_name = removeSpace)]
    pub fn remove_space(&self, space: String) {
        self.spawn("remove space", remove_space(self.inner.clone(), space));
    }

    #[wasm_bindgen(js_name = listSpace)]
    pub fn list_space(&self, space: String) {
        let inner = self.inner.clone();
        self.spawn("list space", async move { list_space(&inner, &space).await });
    }

    /// Writes `bytes` as the space's `path`; answers with a `published` event.
    pub fn publish(&self, space: String, path: String, bytes: Vec<u8>) {
        self.spawn("publish", publish_bytes(self.inner.clone(), space, path, bytes));
    }

    pub fn unpublish(&self, space: String, path: String) {
        self.spawn("unpublish", unpublish(self.inner.clone(), space, path));
    }

    /// Keeps a local file's content available to other devices, as files are the browser's blob store.
    pub async fn seed(&self, bytes: Vec<u8>) -> Result<String, JsError> {
        let tag = self.inner.blobs.add_bytes(bytes).await.map_err(|e| js(e.into()))?;
        Ok(tag.hash.to_hex().to_string())
    }

    /// The blob's content; fails while it hasn't arrived.
    #[wasm_bindgen(js_name = readBlob)]
    pub async fn read_blob(&self, hash: String) -> Result<Vec<u8>, JsError> {
        let hash = Hash::from_str(&hash).map_err(|e| JsError::new(&e.to_string()))?;
        let bytes = self.inner.blobs.get_bytes(hash).await.map_err(|e| js(e.into()))?;
        Ok(bytes.to_vec())
    }

    /// Starts live editing of a file shown in an editor; `name` labels this device's cursor elsewhere.
    #[wasm_bindgen(js_name = liveOpen)]
    pub fn live_open(&self, space: String, path: String, text: String, name: String) {
        live::open(&self.inner, &space, &path, &text, &name);
    }

    #[wasm_bindgen(js_name = liveClose)]
    pub fn live_close(&self, space: String, path: String) {
        live::close(&self.inner, &space, &path);
    }

    /// Hands over the editor's text and selection (UTF-16) and returns JSON with remote `edits`, an
    /// `adopted` session to merge into, the other `cursors` and `peers`. `step` 1 undoes, 2 redoes.
    #[wasm_bindgen(js_name = liveSync)]
    pub fn live_sync(&self, space: String, path: String, text: String, location: u32, length: u32, step: i32) -> String {
        let step = match step {
            1 => live::Step::Undo,
            2 => live::Step::Redo,
            _ => live::Step::None,
        };
        live::sync(&self.inner, &space, &path, &text, (location, length), step).to_string()
    }

    /// The account replica and every open space's, for `start` after the page reloads.
    pub async fn snapshot(&self) -> Result<Vec<u8>, JsError> {
        self.snapshot_inner().await.map_err(js)
    }

    async fn snapshot_inner(&self) -> Result<Vec<u8>> {
        let inner = &self.inner;
        let mut docs = vec![(account_namespace(&inner.account).to_bytes(), inner.account_doc.clone())];
        let open: Vec<(String, iroh_docs::api::Doc)> =
            inner.spaces.lock().unwrap().iter().map(|(id, s)| (id.clone(), s.doc.clone())).collect();
        for (id, doc) in open {
            docs.push((inner.namespace(&id), doc));
        }
        let secrets: Vec<[u8; 32]> = docs.iter().map(|(s, _)| *s).collect();
        let signers: Vec<AuthorId> = authors(&inner.account, &secrets).iter().map(|a| a.id()).collect();
        let mut snapshot = Snapshot { replicas: Vec::new(), blobs: Vec::new() };
        let mut carried = std::collections::HashSet::new();
        for (secret, doc) in docs {
            let mut replica = ReplicaSnapshot { secret, entries: Vec::new() };
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
        Ok(postcard::to_allocvec(&snapshot)?)
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
