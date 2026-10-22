//! wasm32-wasip1 only: lets the web app's worker pass C strings into the `twj_*` exports.
use std::alloc::{Layout, alloc, dealloc};

/// A buffer of `len` bytes for the caller to fill (a NUL-terminated string); free with `twj_dealloc`.
#[unsafe(no_mangle)]
pub extern "C" fn twj_alloc(len: usize) -> *mut u8 {
    unsafe { alloc(Layout::from_size_align(len.max(1), 1).unwrap()) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_dealloc(ptr: *mut u8, len: usize) {
    unsafe { dealloc(ptr, Layout::from_size_align(len.max(1), 1).unwrap()) }
}
