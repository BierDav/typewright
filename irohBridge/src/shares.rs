//! Shares: a folder or file synced as jj nodes (see `bundle` and `jjBridge`) instead of path by path.
//!
//! The account replica lists them as `share/<id>` → `{"name", "kind": "space"|"folder"|"file", "shared"?, "secret"?}`, with
//! the same `member/<id>/<device>` and `removed/<id>` entries spaces have. Spaces listed under `space/<id>` (the
//! path-by-path sync before shares) become `space` shares with the same id and keys.
//!
//! Each share has its own replica, keyed by its secret like a space's but in a different namespace, so devices still
//! syncing the old way never see it. It holds:
//! - `head/<device>` → the node bundle of the device's current node,
//! - `lfs/<blake3>` → an LFS file the heads name (iroh blob hashes are BLAKE3, so the key is the content's hash),
//! - `name/<device>` → the device's name, for conflict sides.
//!
//! A head is reported (`head` event) once its bundle and LFS files are local, so applying it never waits.
// The web app doesn't sync shares yet.
#![cfg_attr(target_arch = "wasm32", allow(dead_code))]

use std::{collections::HashMap, str::FromStr, sync::Arc};

use anyhow::{Result, anyhow};
use bytes::Bytes;
use iroh_blobs::Hash;
use iroh_docs::{Capability, NamespaceSecret, api::Doc, engine::LiveEvent, store::Query};
use n0_future::{StreamExt, task::spawn};
use serde_json::json;

use crate::{
    Inner, Space, bundle, derive, hex, latest, live, member_key, pkarr_client, refresh_space_directory, space_author,
    space_directory_key, sync_space, track, update_record,
};

/// Kept apart from spaces' replicas, which map paths to files.
pub(crate) fn share_namespace(secret: &[u8; 32]) -> NamespaceSecret {
    NamespaceSecret::from_bytes(&derive("typewright 2026-10 share replica v1", &[secret]))
}

fn head_key(device: &str) -> String {
    format!("head/{device}")
}

fn lfs_key(hash: &str) -> String {
    format!("lfs/{hash}")
}

/// The share's replica, opened, watched and syncing on first use.
pub(crate) async fn share_doc(inner: &Arc<Inner>, id: &str) -> Result<Space> {
    let _guard = inner.opening.lock().await;
    if let Some(share) = inner.shares.lock().unwrap().get(id).cloned() {
        return Ok(share);
    }
    let secret = inner.namespace(id);
    let author = space_author(&secret);
    inner.docs.author_import(author.clone()).await?;
    let doc = inner.docs.import_namespace(Capability::Write(share_namespace(&secret))).await?;
    let events = doc.subscribe().await?;
    spawn(watch_share(inner.clone(), id.to_string(), doc.clone(), events));
    let share = Space { doc: doc.clone(), author: author.id() };
    inner.shares.lock().unwrap().insert(id.to_string(), share.clone());
    inner.account_doc.set_bytes(inner.author, member_key(inner, id), b"1".to_vec()).await?;
    live::join(inner, id).await?;
    sync_space(inner, id, &doc).await?;
    if inner.is_shared(id) {
        let inner = inner.clone();
        let id = id.to_string();
        spawn(async move {
            let Ok(client) = pkarr_client(&inner) else { return };
            refresh_space_directory(&inner, &client, &id, false).await;
            let _ = sync_space(&inner, &id, &doc).await;
        });
    }
    Ok(share)
}

/// Starts syncing a share listed by the account, labelled `name` on the other devices; reports the heads it has.
pub(crate) async fn open_share(inner: Arc<Inner>, id: String, name: String) -> Result<()> {
    let share = share_doc(&inner, &id).await?;
    let key = format!("name/{}", inner.endpoint.id());
    let current = latest(&share.doc, key.as_bytes()).await?;
    let unchanged = match &current {
        Some(entry) => inner.blobs.get_bytes(entry.content_hash()).await.is_ok_and(|b| b == name.as_bytes()),
        None => false,
    };
    if !unchanged && !name.is_empty() {
        share.doc.set_bytes(share.author, key, name.into_bytes()).await?;
    }
    list_heads(&inner, &id).await
}

/// Lists the share for every device of the account and starts syncing it here.
pub(crate) async fn add_share(inner: Arc<Inner>, id: String, name: String, kind: String, device: String) -> Result<()> {
    // Membership lands before the listing, so no device sees the share without members.
    inner.account_doc.set_bytes(inner.author, member_key(&inner, &id), b"1".to_vec()).await?;
    let info = serde_json::to_vec(&json!({"name": name, "kind": kind}))?;
    inner.account_doc.set_bytes(inner.author, format!("share/{id}"), info).await?;
    open_share(inner, id, device).await
}

/// Marks an own share shared, so all devices of the account list themselves in its record.
pub(crate) async fn invite_share(inner: Arc<Inner>, id: String, name: String, kind: String) -> Result<()> {
    let key = format!("share/{id}");
    let stored = match latest(&inner.account_doc, key.as_bytes()).await? {
        Some(entry) => inner.blobs.get_bytes(entry.content_hash()).await.ok(),
        None => None,
    };
    let mut info: serde_json::Value =
        stored.and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_else(|| json!({"name": name, "kind": kind}));
    if info["shared"].as_bool() != Some(true) {
        info["shared"] = json!(true);
        inner.account_doc.set_bytes(inner.author, key, serde_json::to_vec(&info)?).await?;
    }
    inner.infos.lock().unwrap().entry(id.clone()).or_default().shared = true;
    live::retopic(&inner).await;
    refresh_space_directory(&inner, &pkarr_client(&inner)?, &id, true).await;
    Ok(())
}

/// Starts syncing a share from another account's invite; the account replica keeps its secret for the other devices.
pub(crate) async fn join_share(
    inner: Arc<Inner>,
    id: String,
    name: String,
    kind: String,
    secret: [u8; 32],
    device: String,
) -> Result<()> {
    // Joining again after "Remove From All Devices" brings it back.
    inner.account_doc.del(inner.author, format!("removed/{id}")).await?;
    inner.account_doc.set_bytes(inner.author, member_key(&inner, &id), b"1".to_vec()).await?;
    let info = serde_json::to_vec(&json!({"name": name, "kind": kind, "secret": hex(&secret), "shared": true}))?;
    inner.account_doc.set_bytes(inner.author, format!("share/{id}"), info).await?;
    open_share(inner, id, device).await
}

/// Stops syncing here; a share nobody syncs anymore leaves the account.
pub(crate) async fn leave_share(inner: Arc<Inner>, id: String) -> Result<()> {
    live::leave(&inner, &id);
    let share = inner.shares.lock().unwrap().remove(&id);
    inner.waiting.lock().unwrap().remove(&id);
    if let Some(share) = share {
        share.doc.leave().await?;
    }
    if inner.is_shared(&id) {
        let key = space_directory_key(&inner.namespace(&id));
        if let Err(err) = update_record(&inner, &pkarr_client(&inner)?, &key, false, true).await {
            inner.error("share directory", err);
        }
        inner.space_devices.lock().unwrap().remove(&id);
    }
    inner.account_doc.del(inner.author, member_key(&inner, &id)).await?;
    let others = inner.account_doc.get_many(Query::single_latest_per_key().key_prefix(format!("member/{id}/")).build()).await?;
    tokio::pin!(others);
    if others.next().await.is_none() {
        // The space it was migrated from goes too, or the next listing would bring the share back.
        inner.account_doc.del(inner.author, format!("share/{id}")).await?;
        inner.account_doc.del(inner.author, format!("space/{id}")).await?;
    }
    Ok(())
}

/// Takes the share off every device; each keeps its files.
pub(crate) async fn remove_share(inner: Arc<Inner>, id: String) -> Result<()> {
    inner.account_doc.set_bytes(inner.author, format!("removed/{id}"), b"1".to_vec()).await?;
    inner.account_doc.del(inner.author, format!("share/{id}")).await?;
    inner.account_doc.del(inner.author, format!("space/{id}")).await?;
    inner.account_doc.del(inner.author, format!("member/{id}/")).await?;
    leave_share(inner, id).await
}

/// Reports every other device's head that is ready, and waits for the rest.
pub(crate) async fn list_heads(inner: &Arc<Inner>, id: &str) -> Result<()> {
    let doc = share_doc(inner, id).await?.doc;
    let stream = doc.get_many(Query::single_latest_per_key().key_prefix("head/").build()).await?;
    tokio::pin!(stream);
    let mut heads = Vec::new();
    while let Some(entry) = stream.next().await {
        let entry = entry?;
        let device = String::from_utf8_lossy(&entry.key()[5..]).into_owned();
        heads.push((device, entry.content_hash()));
    }
    for (device, hash) in heads {
        check_head(inner, id, &doc, &device, hash).await;
    }
    Ok(())
}

/// Emits `head` once the bundle and its LFS files are local, or remembers it until they are.
async fn check_head(inner: &Inner, id: &str, doc: &Doc, device: &str, bundle_hash: Hash) {
    if device == inner.endpoint.id().to_string() {
        return;
    }
    let ready = async {
        if !inner.blobs.has(bundle_hash).await? {
            return Ok::<_, anyhow::Error>(None);
        }
        let bytes = inner.blobs.get_bytes(bundle_hash).await?;
        let manifest = bundle::manifest(&bytes)?;
        for hash in bundle::lfs_hashes(&manifest) {
            if !inner.blobs.has(Hash::from_str(&hash)?).await? {
                return Ok(None);
            }
        }
        Ok(Some(manifest))
    }
    .await;
    match ready {
        Ok(Some(manifest)) => {
            inner.waiting.lock().unwrap().entry(id.to_string()).or_default().remove(device);
            let name = match latest(doc, format!("name/{device}").as_bytes()).await {
                Ok(Some(entry)) => inner.blobs.get_bytes(entry.content_hash()).await.ok().map(|b| String::from_utf8_lossy(&b).into_owned()),
                _ => None,
            };
            inner.emit(json!({
                "type": "head", "share": id, "device": device, "node": manifest["node"], "name": name,
                "parents": manifest["parents"],
            }));
        }
        Ok(None) => {
            inner.waiting.lock().unwrap().entry(id.to_string()).or_default().insert(device.to_string(), bundle_hash);
        }
        Err(err) => inner.error("share head", err),
    }
}

/// Reports heads as their content arrives.
async fn watch_share(
    inner: Arc<Inner>,
    id: String,
    doc: Doc,
    mut events: impl n0_future::Stream<Item = Result<LiveEvent>> + Unpin,
) {
    while let Some(event) = events.next().await {
        let event = match event {
            Ok(event) => event,
            Err(err) => return inner.error("share replica", err),
        };
        match event {
            LiveEvent::InsertRemote { entry, .. } => {
                if let Some(device) = entry.key().strip_prefix(b"head/") {
                    let device = String::from_utf8_lossy(device).into_owned();
                    check_head(&inner, &id, &doc, &device, entry.content_hash()).await;
                }
            }
            LiveEvent::ContentReady { .. } => {
                // A bundle or one of its LFS files arrived; check what was waiting.
                let waiting: Vec<(String, Hash)> =
                    inner.waiting.lock().unwrap().get(&id).map(|w| w.iter().map(|(d, h)| (d.clone(), *h)).collect()).unwrap_or_default();
                for (device, hash) in waiting {
                    check_head(&inner, &id, &doc, &device, hash).await;
                }
            }
            LiveEvent::NeighborUp(peer) => track(&inner, peer, true),
            LiveEvent::NeighborDown(peer) => track(&inner, peer, false),
            _ => {}
        }
    }
}

/// Publishes a node as this device's head: `bundle` from `bundle::encode`, plus the LFS files it names that the
/// replica doesn't hold yet, which `lfs` provides (`(blake3, source)`, read by `add`).
pub(crate) async fn publish_node<F, Fut>(inner: Arc<Inner>, id: String, bundle_bytes: Vec<u8>, lfs: Vec<String>, add: F) -> Result<()>
where
    F: Fn(Doc, iroh_docs::AuthorId, String) -> Fut,
    Fut: Future<Output = Result<Hash>>,
{
    let share = share_doc(&inner, &id).await?;
    let manifest = bundle::manifest(&bundle_bytes)?;
    for hash in lfs {
        let key = lfs_key(&hash);
        if latest(&share.doc, key.as_bytes()).await?.is_some() {
            continue;
        }
        let expected = Hash::from_str(&hash)?;
        if inner.blobs.has(expected).await? {
            let size = inner.blobs.get_bytes(expected).await?.len() as u64;
            share.doc.set_hash(share.author, Bytes::from(key.into_bytes()), expected, size).await?;
            continue;
        }
        let added = add(share.doc.clone(), share.author, key).await?;
        if added != expected {
            return Err(anyhow!("LFS file {hash} changed while it was published"));
        }
    }
    let size = bundle_bytes.len() as u64;
    let tag = inner.blobs.add_bytes(bundle_bytes).await?;
    let key = head_key(&inner.endpoint.id().to_string());
    share.doc.set_hash(share.author, Bytes::from(key.into_bytes()), tag.hash, size).await?;
    inner.emit(json!({"type": "published-node", "share": id, "node": manifest["node"]}));
    Ok(())
}

/// The current bundle of `device`'s head in the share.
pub(crate) async fn head_bundle(inner: &Arc<Inner>, id: &str, device: &str) -> Result<bundle::Bundle> {
    let doc = share_doc(inner, id).await?.doc;
    let entry = latest(&doc, head_key(device).as_bytes()).await?.ok_or_else(|| anyhow!("{device} has no head"))?;
    let bytes = inner.blobs.get_bytes(entry.content_hash()).await?;
    bundle::decode(&bytes)
}

/// Lists the account's shares with their members, migrating spaces listed the old way to folder shares.
pub(crate) fn share_list(
    shares: Vec<(String, serde_json::Value)>,
    spaces: &[(String, serde_json::Value)],
    members: &HashMap<String, Vec<String>>,
) -> (Vec<serde_json::Value>, Vec<(String, serde_json::Value)>) {
    let mut listed: HashMap<String, serde_json::Value> = shares.into_iter().collect();
    let mut migrate = Vec::new();
    for (id, info) in spaces {
        if !listed.contains_key(id) {
            let mut info = info.clone();
            info["kind"] = json!("space");
            migrate.push((id.clone(), info.clone()));
            listed.insert(id.clone(), info);
        }
    }
    let mut out: Vec<serde_json::Value> = listed
        .into_iter()
        .map(|(id, mut info)| {
            info["shared"] = json!(info["shared"].as_bool().unwrap_or(false) || info["secret"].is_string());
            if let Some(fields) = info.as_object_mut() {
                fields.remove("secret");
            }
            if !info["kind"].is_string() {
                info["kind"] = json!("space");
            }
            info["members"] = json!(members.get(&id).cloned().unwrap_or_default());
            info["id"] = json!(id);
            info
        })
        .collect();
    out.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    (out, migrate)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn share_replicas_are_apart_from_space_replicas() {
        let secret = [9u8; 32];
        assert_ne!(share_namespace(&secret).id(), NamespaceSecret::from_bytes(&secret).id());
    }

    #[test]
    fn lists_shares_and_migrates_spaces() {
        let members = HashMap::from([("a".to_string(), vec!["d1".to_string()])]);
        let shares = vec![("b".to_string(), json!({"name": "Notes", "kind": "file", "secret": "00"}))];
        let spaces = vec![
            ("a".to_string(), json!({"name": "Thesis", "shared": true})),
            ("b".to_string(), json!({"name": "Old name"})),
        ];
        let (list, migrate) = share_list(shares, &spaces, &members);
        assert_eq!(migrate.len(), 1);
        assert_eq!(migrate[0].0, "a");
        assert_eq!(migrate[0].1["kind"], "space");
        assert_eq!(list[0]["id"], "a");
        assert_eq!(list[0]["members"], json!(["d1"]));
        assert_eq!(list[0]["shared"], true);
        assert_eq!(list[1]["name"], "Notes");
        assert_eq!(list[1]["kind"], "file");
        assert_eq!(list[1]["shared"], true);
        assert!(list[1].get("secret").is_none());
    }
}
