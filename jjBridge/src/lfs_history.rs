//! Local whole-file versions, kept outside jj's trees and sync bundles.
use std::collections::BTreeSet;
use std::fs;

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::lfs::LfsFile;
use crate::repo::{Repo, repo_path};
use crate::retention::{Item, Policy, keep};

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Version {
    pub id: String,
    pub millis: i64,
    pub offset: i32,
    pub description: String,
    pub hash: Option<String>,
    pub stat: Option<LfsFile>,
    pub jj_commit: Option<String>,
    pub from: Option<String>,
}

impl Repo {
    fn version_object(&self, hash: &str) -> std::path::PathBuf {
        self.root().join(".jj/typewright/file-history").join(hash)
    }

    pub(crate) fn record_lfs_versions(&mut self, message: &str, jj_commit: Option<&str>) -> Result<Vec<String>> {
        let paths: BTreeSet<_> = self.state.lfs.keys().chain(self.state.lfs_versions.keys()).cloned().collect();
        let timestamp = self.signature().timestamp;
        let mut changed = Vec::new();
        for path in paths {
            let disk = self.disk_path(&repo_path(&path)?)?;
            let stat = LfsFile::stat(&disk);
            // Small text files return to jj history.
            if stat.is_some() && !self.state.lfs.contains_key(&path) {
                if let Some(last) = self.state.lfs_versions.get_mut(&path).and_then(|v| v.last_mut()) { last.stat = None; }
                continue;
            }
            let versions = self.state.lfs_versions.get(&path);
            let previous = versions.and_then(|v| v.last());
            if previous.is_some_and(|v| v.stat.as_ref().map(|s| (s.size, s.mtime)) == stat.as_ref().map(|s| (s.size, s.mtime))) {
                continue;
            }
            let hash = if stat.is_some() {
                let directory = self.root().join(".jj/typewright/file-history");
                fs::create_dir_all(&directory)?;
                let staged = tempfile::NamedTempFile::new_in(&directory)?;
                fs::copy(&disk, staged.path())?;
                let hash = crate::lfs::hash_file(staged.path())?;
                let object = self.version_object(&hash);
                if !object.exists() { staged.persist(&object)?; }
                Some(hash)
            } else { None };
            if previous.is_some_and(|v| v.hash == hash && v.stat.is_some()) {
                self.state.lfs_versions.get_mut(&path).unwrap().last_mut().unwrap().stat = stat;
                continue;
            }
            if previous.is_none() && hash.is_none() { continue; }
            let candidates: Vec<_> = if previous.is_none() && hash.is_some() {
                self.state.lfs_versions.iter().filter_map(|(old, versions)| {
                    let last = versions.iter().rev().find(|v| v.hash.is_some())?;
                    (old != &path && last.hash == hash && !self.state.lfs.contains_key(old)
                        && !self.root().join(old).exists()).then(|| old.clone())
                }).collect()
            } else { Vec::new() };
            let from = if candidates.len() == 1 { candidates.first().cloned() } else { None };
            if let Some(old) = &from {
                let mut versions = self.state.lfs_versions[old].clone();
                if versions.last().is_some_and(|v| v.hash.is_none()) { versions.pop(); }
                self.state.lfs_versions.insert(path.clone(), versions);
            }
            let versions = self.state.lfs_versions.entry(path.clone()).or_default();
            let id = blake3::hash(&serde_json::to_vec(&(&path, timestamp.timestamp.0, versions.len(), &hash))?).to_hex();
            versions.push(Version {
                id: format!("lfs:{id}"), millis: timestamp.timestamp.0, offset: timestamp.tz_offset,
                description: message.to_owned(), hash, stat, jj_commit: jj_commit.map(str::to_owned), from,
            });
            changed.push(path);
        }
        Ok(changed)
    }

    pub(crate) fn lfs_history(&self, path: &str) -> Vec<Value> {
        let Some(versions) = self.state.lfs_versions.get(path) else { return Vec::new() };
        versions.iter().enumerate().rev().map(|(index, v)| json!({
            "commit": v.id, "time": v.millis as f64 / 1000.0, "description": v.description,
            "kind": if v.from.is_some() { "renamed" } else if v.hash.is_none() { "deleted" } else if index == 0 || versions[index - 1].hash.is_none() { "added" } else { "modified" },
            "from": v.from,
            "added": 0, "removed": 0,
        })).collect()
    }

    pub(crate) fn lfs_version_bytes(&self, path: &str, id: &str) -> Result<Option<Vec<u8>>> {
        let version = self.state.lfs_versions.get(path).and_then(|v| v.iter().find(|v| v.id == id))
            .ok_or_else(|| anyhow!("unknown whole-file version"))?;
        version.hash.as_ref().map(|hash| Ok(fs::read(self.version_object(hash))?)).transpose()
    }

    pub(crate) fn prune_lfs_versions(&mut self, policy: &Policy) -> Result<()> {
        for versions in self.state.lfs_versions.values_mut() {
            let items: Vec<_> = versions.iter().rev().map(|v| Item {
                millis: v.millis, offset: v.offset, pinned: v.description != "Edit",
            }).collect();
            let mut kept = keep(&items, policy);
            if let Some(latest) = kept.first_mut() { *latest = true; }
            kept.reverse();
            let mut index = 0;
            versions.retain(|_| { let keep = kept[index]; index += 1; keep });
        }
        // Save references before deleting objects, so interrupted pruning cannot lose a kept version.
        self.save_state()?;
        let referenced: BTreeSet<_> = self.state.lfs_versions.values().flatten().filter_map(|v| v.hash.as_deref()).collect();
        if let Ok(entries) = fs::read_dir(self.root().join(".jj/typewright/file-history")) {
            for entry in entries {
                let entry = entry?;
                if !referenced.contains(entry.file_name().to_string_lossy().as_ref()) { fs::remove_file(entry.path())?; }
            }
        }
        Ok(())
    }
}
