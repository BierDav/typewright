//! LFS files: above the size limit or binary. jj never tracks them; sync moves them whole by BLAKE3 hash.
use std::fs;
use std::io::Read as _;
use std::path::Path;
use std::time::UNIX_EPOCH;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::repo::{Repo, repo_path};

/// Kinds that are binary even when their first bytes look like text.
pub(crate) const BINARY_EXTENSIONS: &[&str] = &[
    "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns", "psd", "ai",
    "eps", "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar", "dmg", "iso", "mp3", "m4a", "aac", "wav",
    "aif", "aiff", "flac", "ogg", "opus", "mp4", "mov", "m4v", "avi", "mkv", "webm", "otf", "ttf", "ttc", "woff",
    "woff2", "sqlite", "db", "key", "pages", "numbers", "docx", "xlsx", "pptx", "doc", "xls", "ppt", "wasm", "a",
    "o", "dylib", "so", "exe", "bin", "class", "jar",
];

/// What we know about an LFS file on disk; the hash is recomputed when size or mtime change.
#[derive(Clone, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct LfsFile {
    pub size: u64,
    pub mtime: i128,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blake3: Option<String>,
}

impl LfsFile {
    pub fn stat(path: &Path) -> Option<LfsFile> {
        let meta = fs::symlink_metadata(path).ok()?;
        if !meta.is_file() {
            return None;
        }
        Some(LfsFile { size: meta.len(), mtime: mtime_nanos(&meta), blake3: None })
    }

    pub fn mtime_seconds(&self) -> i64 { (self.mtime / 1_000_000_000) as i64 }
}

fn mtime_nanos(meta: &fs::Metadata) -> i128 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_nanos() as i128)
}

pub(crate) fn has_binary_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| BINARY_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

/// Git's heuristic: a NUL byte in the first 8000 bytes.
pub(crate) fn sniffs_binary(bytes: &[u8]) -> bool { bytes.iter().take(8000).any(|b| *b == 0) }

pub(crate) fn is_lfs(path: &Path, limit: u64) -> bool {
    let Ok(meta) = fs::symlink_metadata(path) else { return false };
    if !meta.is_file() {
        return false;
    }
    if meta.len() > limit || has_binary_extension(path) {
        return true;
    }
    let mut head = [0u8; 8000];
    let Ok(mut file) = fs::File::open(path) else { return false };
    let mut read = 0;
    while read < head.len() {
        match file.read(&mut head[read..]) {
            Ok(0) | Err(_) => break,
            Ok(n) => read += n,
        }
    }
    sniffs_binary(&head[..read])
}

pub(crate) fn hash_file(path: &Path) -> Result<String> {
    let mut hasher = blake3::Hasher::new();
    let mut file = fs::File::open(path)?;
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

impl Repo {
    /// Drops LFS entries that vanished or became small text files (jj tracks those again); returns changed paths.
    pub(crate) fn refresh_lfs(&mut self) -> Result<Vec<String>> {
        let mut changed = Vec::new();
        let limit = self.lfs_limit;
        let paths: Vec<String> = self.state.lfs.keys().cloned().collect();
        for key in paths {
            let disk = self.disk_path(&repo_path(&key)?)?;
            match LfsFile::stat(&disk) {
                None => {
                    self.state.lfs.remove(&key);
                    changed.push(key);
                }
                Some(_) if !is_lfs(&disk, limit) => {
                    self.state.lfs.remove(&key);
                }
                Some(stat) => {
                    let entry = self.state.lfs.get_mut(&key).unwrap();
                    if entry.size != stat.size || entry.mtime != stat.mtime {
                        *entry = stat;
                        changed.push(key);
                    }
                }
            }
        }
        Ok(changed)
    }

    /// The BLAKE3 hash of an LFS file, cached until it changes on disk.
    pub(crate) fn lfs_hash(&mut self, key: &str) -> Result<Option<(LfsFile, String)>> {
        let disk = self.disk_path(&repo_path(key)?)?;
        let Some(stat) = LfsFile::stat(&disk) else { return Ok(None) };
        let entry = self.state.lfs.entry(key.to_owned()).or_default();
        if entry.size != stat.size || entry.mtime != stat.mtime || entry.blake3.is_none() {
            *entry = LfsFile { blake3: Some(hash_file(&disk)?), ..stat };
        }
        let hash = entry.blake3.clone().unwrap();
        Ok(Some((entry.clone(), hash)))
    }
}
