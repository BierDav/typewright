//! The internal jj repository: spaces as top-level folders, local history, conflicts and sync nodes.
//! The C interface (`ffi.rs`, `include/JJBridge.h`) serves the Mac app and, built for wasm32-wasip1, the web app.

mod ffi;
pub use ffi::*;
