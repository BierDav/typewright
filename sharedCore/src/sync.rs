/// Files above this many bytes are LFS files by default: never in jj's history, synced whole by hash.
pub const DEFAULT_LFS_THRESHOLD: f64 = 1_048_576.0;

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn default_lfs_threshold() -> f64 {
    DEFAULT_LFS_THRESHOLD
}
