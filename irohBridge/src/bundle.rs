//! Node bundles: one blob carrying a sync node (see `jjBridge`'s `twj_export_node`) with every git object needed to
//! import it, so a peer that has nothing yet can take any head.
//!
//! Layout: `MAGIC`, the manifest's length (u32 LE) and JSON, then per object its 20-byte id, length (u32 LE) and
//! loose-object bytes (`<kind> <len>\0<data>`, as `twj_write_objects` writes them), sorted by id. The manifest keeps
//! only what follows from the node itself, so every device bundling the same node writes the same bytes, and the
//! blob is shared instead of sent again.

use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};

pub const MAGIC: &[u8] = b"typewright-bundle v1\n";

pub struct Bundle {
    pub manifest: Value,
    /// (hex id, loose-object bytes)
    pub objects: Vec<(String, Vec<u8>)>,
}

/// The fields of a manifest that depend on the node only (`unchanged`, `ancestry` and `objects` vary per device).
pub fn canonical(manifest: &Value) -> Result<Value> {
    let node = manifest["node"].as_str().ok_or_else(|| anyhow!("manifest has no node"))?;
    Ok(json!({
        "node": node,
        "tree": manifest["tree"],
        "parents": manifest["parents"],
        "files": manifest["files"],
    }))
}

/// Ids of the LFS files a manifest names, which travel as their own blobs.
pub fn lfs_hashes(manifest: &Value) -> Vec<String> {
    let mut hashes: Vec<String> = manifest["files"]
        .as_object()
        .map(|files| {
            files
                .values()
                .filter(|f| f["lfs"].as_bool() == Some(true))
                .filter_map(|f| f["blake3"].as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    hashes.sort();
    hashes.dedup();
    hashes
}

pub fn encode(manifest: &Value, objects: &[(String, Vec<u8>)]) -> Result<Vec<u8>> {
    let manifest = serde_json::to_vec(&canonical(manifest)?)?;
    let mut objects: Vec<&(String, Vec<u8>)> = objects.iter().collect();
    objects.sort_by(|a, b| a.0.cmp(&b.0));
    objects.dedup_by(|a, b| a.0 == b.0);
    let mut out = Vec::with_capacity(MAGIC.len() + 4 + manifest.len() + objects.iter().map(|o| 24 + o.1.len()).sum::<usize>());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&u32::try_from(manifest.len())?.to_le_bytes());
    out.extend_from_slice(&manifest);
    for (id, bytes) in objects {
        out.extend_from_slice(&oid_bytes(id)?);
        out.extend_from_slice(&u32::try_from(bytes.len())?.to_le_bytes());
        out.extend_from_slice(bytes);
    }
    Ok(out)
}

/// Just the manifest, without copying the objects.
pub fn manifest(bytes: &[u8]) -> Result<Value> {
    let (manifest, _) = header(bytes)?;
    Ok(manifest)
}

pub fn decode(bytes: &[u8]) -> Result<Bundle> {
    let (manifest, mut at) = header(bytes)?;
    let mut objects = Vec::new();
    while at < bytes.len() {
        let id = bytes.get(at..at + 20).ok_or_else(|| anyhow!("bundle cut off in an object id"))?;
        let len = u32::from_le_bytes(take4(bytes, at + 20)?) as usize;
        let start = at + 24;
        let data = bytes.get(start..start + len).ok_or_else(|| anyhow!("bundle cut off in an object"))?;
        objects.push((hex(id), data.to_vec()));
        at = start + len;
    }
    Ok(Bundle { manifest, objects })
}

fn header(bytes: &[u8]) -> Result<(Value, usize)> {
    if !bytes.starts_with(MAGIC) {
        bail!("not a node bundle");
    }
    let len = u32::from_le_bytes(take4(bytes, MAGIC.len())?) as usize;
    let start = MAGIC.len() + 4;
    let json = bytes.get(start..start + len).ok_or_else(|| anyhow!("bundle cut off in its manifest"))?;
    let manifest: Value = serde_json::from_slice(json)?;
    if !manifest["node"].is_string() {
        bail!("bundle manifest has no node");
    }
    Ok((manifest, start + len))
}

fn take4(bytes: &[u8], at: usize) -> Result<[u8; 4]> {
    Ok(bytes.get(at..at + 4).ok_or_else(|| anyhow!("bundle cut off"))?.try_into()?)
}

fn oid_bytes(id: &str) -> Result<[u8; 20]> {
    if id.len() != 40 || !id.is_ascii() {
        bail!("invalid object id {id:?}");
    }
    let mut out = [0u8; 20];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&id[i * 2..i * 2 + 2], 16).map_err(|_| anyhow!("invalid object id {id:?}"))?;
    }
    Ok(out)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Value {
        json!({
            "node": "a".repeat(40), "tree": "b".repeat(40), "parents": ["c".repeat(40)],
            "files": {
                "main.typ": {"mode": "100644", "size": 3, "oid": "d".repeat(40), "lfs": false},
                "img.png": {"mode": "100644", "size": 9, "lfs": true, "blake3": "e".repeat(64), "time": 5},
                "copy.png": {"mode": "100644", "size": 9, "lfs": true, "blake3": "e".repeat(64), "time": 5},
            },
            "unchanged": true, "ancestry": ["c".repeat(40)], "objects": ["a".repeat(40)],
        })
    }

    #[test]
    fn round_trips() {
        let objects = vec![("d".repeat(40), b"blob 3\0abc".to_vec()), ("1".repeat(40), b"tree 0\0".to_vec())];
        let bytes = encode(&manifest(), &objects).unwrap();
        let bundle = decode(&bytes).unwrap();
        assert_eq!(bundle.manifest["node"], "a".repeat(40));
        assert!(bundle.manifest.get("unchanged").is_none() && bundle.manifest.get("ancestry").is_none());
        assert_eq!(bundle.objects.len(), 2);
        assert_eq!(bundle.objects[0], ("1".repeat(40), b"tree 0\0".to_vec()));
        assert_eq!(bundle.objects[1].1, b"blob 3\0abc");
        assert_eq!(super::manifest(&bytes).unwrap(), bundle.manifest);
        assert_eq!(lfs_hashes(&bundle.manifest), vec!["e".repeat(64)]);
    }

    #[test]
    fn same_node_same_bytes() {
        // Per-device fields and object order don't change the blob.
        let mut other = manifest();
        other["ancestry"] = json!([]);
        other.as_object_mut().unwrap().remove("unchanged");
        let a = vec![("d".repeat(40), b"x".to_vec()), ("1".repeat(40), b"y".to_vec())];
        let b = vec![a[1].clone(), a[0].clone(), a[0].clone()];
        assert_eq!(encode(&manifest(), &a).unwrap(), encode(&other, &b).unwrap());
    }

    #[test]
    fn rejects_junk() {
        assert!(decode(b"hello").is_err());
        let bytes = encode(&manifest(), &[("d".repeat(40), b"blob 3\0abc".to_vec())]).unwrap();
        assert!(decode(&bytes[..bytes.len() - 1]).is_err());
        assert!(decode(&bytes[..MAGIC.len() + 2]).is_err());
        assert!(encode(&json!({"files": {}}), &[]).is_err());
        assert!(encode(&manifest(), &[("zz".into(), vec![])]).is_err());
    }
}
