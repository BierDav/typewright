//! The internal jj repository: spaces as top-level folders, local history, conflicts and sync nodes.
//! The C interface (`ffi.rs`, `include/JJBridge.h`) serves the Mac app and, built for wasm32-wasip1, the web app.

mod changes;
mod config;
mod conflicts;
mod deleted;
mod ffi;
mod fsutil;
mod history;
mod lfs;
mod nodes;
mod normalize;
mod repo;
pub mod retention;
mod squash;
#[cfg(test)]
mod cli_tests;
#[cfg(test)]
mod tests;

pub use ffi::*;
pub use repo::{Busy, Committed, Repo};
#[cfg(target_os = "wasi")]
mod wasi;
