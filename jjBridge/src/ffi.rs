//! C interface, see `include/JJBridge.h`. Stubs until the jj-lib implementation lands.
use std::ffi::{CString, c_char};

pub struct TWJRepo;
fn json(value: serde_json::Value) -> *mut c_char { CString::new(value.to_string()).unwrap().into_raw() }
fn unimplemented() -> *mut c_char { json(serde_json::json!({"error": "unimplemented"})) }

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_open(_root: *const c_char) -> *mut TWJRepo {
    Box::into_raw(Box::new(TWJRepo))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_close(_repo: *mut TWJRepo) {
    if !_repo.is_null() { drop(unsafe { Box::from_raw(_repo) }); }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_set_lfs_limit(_repo: *mut TWJRepo, _bytes: u64) {
    
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_commit(_repo: *mut TWJRepo, _message: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_squash(_repo: *mut TWJRepo, _days: u32) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_file_history(_repo: *mut TWJRepo, _path: *const c_char, _limit: u32) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_file_at(_repo: *mut TWJRepo, _commit: *const c_char, _path: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_restore_file(_repo: *mut TWJRepo, _commit: *const c_char, _path: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_conflicts(_repo: *mut TWJRepo, _prefix: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_conflict(_repo: *mut TWJRepo, _path: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_resolve(_repo: *mut TWJRepo, _path: *const c_char, _text: *const c_char, _side: i32) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_export_node(_repo: *mut TWJRepo, _share: *const c_char, _path: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_node(_repo: *mut TWJRepo, _share: *const c_char, _node: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_missing_objects(_repo: *mut TWJRepo, _manifest: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_write_objects(_repo: *mut TWJRepo, _oids: *const c_char, _dir: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_import_node(_repo: *mut TWJRepo, _share: *const c_char, _manifest: *const c_char, _dir: *const c_char, _label: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_merge_node(_repo: *mut TWJRepo, _share: *const c_char, _path: *const c_char, _node: *const c_char, _lfs_dir: *const c_char) -> *mut c_char {
    unimplemented()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_string_free(string: *mut c_char) {
    if !string.is_null() { drop(unsafe { CString::from_raw(string) }); }
}
