//! The web app's replica snapshots: browsers can't host the replica database, so the page saves one to origin
//! storage and hands it back on the next start.

use anyhow::Result;
use iroh_blobs::Hash;
use iroh_docs::{Capability, ContentStatus, NamespaceSecret, Record, RecordIdentifier, store::Store};
use serde::{Deserialize, Serialize};

use crate::{account_author, space_author};

/// Blobs up to this size ride along in snapshots: account entries and small node bundles.
pub(crate) const SNAPSHOT_BLOB_LIMIT: u64 = 256 * 1024;
/// Snapshots since shares start with this; older ones (account and space replicas) still read.
pub(crate) const SNAPSHOT_MAGIC: &[u8] = b"tws snapshot v2\n";

#[derive(Serialize, Deserialize)]
pub(crate) struct Snapshot {
    pub(crate) replicas: Vec<ReplicaSnapshot>,
    pub(crate) blobs: Vec<Vec<u8>>,
}

#[derive(Serialize, Deserialize)]
pub(crate) struct ReplicaSnapshot {
    pub(crate) namespace: [u8; 32],
    /// Secret of the author the replica's entries are written as (beside the account's).
    pub(crate) author: [u8; 32],
    /// Author, key, content hash, length and timestamp of every entry.
    pub(crate) entries: Vec<([u8; 32], Vec<u8>, [u8; 32], u64, u64)>,
}

/// Before shares: each replica's namespace secret also derived its author.
#[derive(Serialize, Deserialize)]
struct OldSnapshot {
    replicas: Vec<OldReplica>,
    blobs: Vec<Vec<u8>>,
}

#[derive(Serialize, Deserialize)]
struct OldReplica {
    secret: [u8; 32],
    entries: Vec<([u8; 32], Vec<u8>, [u8; 32], u64, u64)>,
}

fn read_snapshot(bytes: &[u8]) -> Result<Snapshot> {
    if let Some(rest) = bytes.strip_prefix(SNAPSHOT_MAGIC) {
        return Ok(postcard::from_bytes(rest)?);
    }
    let old: OldSnapshot = postcard::from_bytes(bytes)?;
    Ok(Snapshot {
        replicas: old
            .replicas
            .into_iter()
            .map(|r| ReplicaSnapshot { namespace: r.secret, author: r.secret, entries: r.entries })
            .collect(),
        blobs: old.blobs,
    })
}

/// Rebuilds the replicas a snapshot describes; returns the blobs it carried.
pub(crate) async fn restore(store: &mut Store, account: &[u8; 32], bytes: &[u8]) -> Result<Vec<Vec<u8>>> {
    let snapshot = read_snapshot(bytes)?;
    let carried: std::collections::HashSet<Hash> = snapshot.blobs.iter().map(|b| Hash::new(b)).collect();
    let own = account_author(account);
    for replica in &snapshot.replicas {
        let namespace = NamespaceSecret::from_bytes(&replica.namespace);
        let authors = [own.clone(), space_author(&replica.author)];
        store.import_namespace(Capability::Write(namespace.clone()))?;
        let mut open = store.open_replica(&namespace.id())?;
        for (author, key, hash, len, timestamp) in &replica.entries {
            let Some(author) = authors.iter().find(|a| a.id().as_bytes() == author) else { continue };
            // Large content isn't carried; peers send these entries again, so it gets fetched instead of claimed.
            if *len > 0 && !carried.contains(&Hash::from_bytes(*hash)) {
                continue;
            }
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

#[cfg(all(test, not(target_arch = "wasm32")))]
mod tests {
    use super::*;
    use crate::account_namespace;

    fn entry(author: &iroh_docs::Author, key: &str, content: &[u8], timestamp: u64) -> ([u8; 32], Vec<u8>, [u8; 32], u64, u64) {
        (*author.id().as_bytes(), key.as_bytes().to_vec(), *Hash::new(content).as_bytes(), content.len() as u64, timestamp)
    }

    #[tokio::test]
    async fn restores_snapshots_from_before_shares() -> Result<()> {
        let account = [7u8; 32];
        let namespace = account_namespace(&account);
        let space_secret = [9u8; 32];
        let own = account_author(&account);
        let large = vec![1u8; (SNAPSHOT_BLOB_LIMIT + 1) as usize];
        let old = OldSnapshot {
            replicas: vec![
                OldReplica {
                    secret: namespace.to_bytes(),
                    entries: vec![entry(&own, "space/a", br#"{"name":"A"}"#, 10), entry(&own, "member/a/dev", b"1", 11)],
                },
                OldReplica { secret: space_secret, entries: vec![entry(&space_author(&space_secret), "main.typ", b"= Hi", 12)] },
            ],
            blobs: vec![br#"{"name":"A"}"#.to_vec(), b"1".to_vec(), b"= Hi".to_vec(), large],
        };
        let mut store = Store::memory();
        let blobs = restore(&mut store, &account, &postcard::to_allocvec(&old)?).await?;
        assert_eq!(blobs.len(), 4);
        let got = store.get_exact(namespace.id(), own.id(), "space/a", false)?.expect("account entry");
        assert_eq!(got.content_hash(), Hash::new(br#"{"name":"A"}"#));
        assert_eq!(got.timestamp(), 10);
        let space = NamespaceSecret::from_bytes(&space_secret);
        assert!(store.get_exact(space.id(), space_author(&space_secret).id(), "main.typ", false)?.is_some());
        Ok(())
    }

    #[tokio::test]
    async fn leaves_out_entries_whose_content_isnt_carried() -> Result<()> {
        let account = [3u8; 32];
        let secret = [4u8; 32];
        let author = space_author(&secret);
        let large = vec![2u8; (SNAPSHOT_BLOB_LIMIT + 1) as usize];
        let snapshot = Snapshot {
            replicas: vec![ReplicaSnapshot {
                namespace: secret,
                author: secret,
                entries: vec![entry(&author, "head/a", b"bundle", 1), entry(&author, "lfs/big", &large, 2), entry(&author, "gone", b"", 3)],
            }],
            blobs: vec![b"bundle".to_vec()],
        };
        let mut bytes = SNAPSHOT_MAGIC.to_vec();
        bytes.extend(postcard::to_allocvec(&snapshot)?);
        let mut store = Store::memory();
        restore(&mut store, &account, &bytes).await?;
        let namespace = NamespaceSecret::from_bytes(&secret).id();
        assert!(store.get_exact(namespace, author.id(), "head/a", false)?.is_some());
        assert!(store.get_exact(namespace, author.id(), "lfs/big", false)?.is_none());
        assert!(store.get_exact(namespace, author.id(), "gone", true)?.is_some());
        Ok(())
    }
}
