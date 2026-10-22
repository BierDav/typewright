//! The internal jj repository: spaces as top-level folders, local history, conflicts and sync nodes.
//! The C interface (`ffi.rs`, `include/JJBridge.h`) serves the Mac app and, built for wasm32-wasip1, the web app.

mod conflicts;
mod ffi;
mod fsutil;
mod history;
mod lfs;
mod nodes;
mod repo;
#[cfg(test)]
mod tests;

pub use ffi::*;
pub use repo::{Committed, Repo};
