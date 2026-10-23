//! C interface, see `include/JJBridge.h`: a thin JSON layer over `Repo`.
#![allow(clippy::missing_safety_doc)]
use std::ffi::{CStr, CString, c_char};

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::repo::Repo;

pub struct TWJRepo(Repo);

fn to_c(value: Value) -> *mut c_char {
    CString::new(value.to_string()).unwrap_or_else(|_| CString::new("{\"error\":\"nul in output\"}").unwrap()).into_raw()
}

fn respond(result: Result<Value>) -> *mut c_char {
    to_c(result.unwrap_or_else(|e| {
        let mut error = json!({"error": format!("{e:#}")});
        if e.chain().any(|c| c.is::<crate::Busy>()) {
            error["busy"] = json!(true);
        }
        error
    }))
}

unsafe fn text<'a>(ptr: *const c_char) -> Result<&'a str> {
    if ptr.is_null() {
        return Err(anyhow!("missing argument"));
    }
    Ok(unsafe { CStr::from_ptr(ptr) }.to_str()?)
}

unsafe fn repo<'a>(ptr: *mut TWJRepo) -> &'a mut Repo { &mut unsafe { &mut *ptr }.0 }

/// Like `guard`, adding `staleWorkspaces` when the call left other workspaces stale and `wrote` when it rewrote files.
fn guard_repo(ptr: *mut TWJRepo, body: impl FnOnce(&mut Repo) -> Result<Value>) -> *mut c_char {
    guard(|| {
        let repo = unsafe { self::repo(ptr) };
        let mut value = body(repo)?;
        if !repo.stale_workspaces.is_empty() && value.is_object() {
            value["staleWorkspaces"] = json!(repo.stale_workspaces);
        }
        if repo.wrote_files && value.is_object() {
            value["wrote"] = json!(true);
        }
        Ok(value)
    })
}

/// Runs `body`, turning panics into errors so they never unwind into Swift.
fn guard(body: impl FnOnce() -> Result<Value>) -> *mut c_char {
    respond(std::panic::catch_unwind(std::panic::AssertUnwindSafe(body)).unwrap_or_else(|panic| {
        let message = panic.downcast_ref::<String>().cloned().or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()));
        Err(anyhow!("panic: {}", message.unwrap_or_default()))
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_open(root: *const c_char) -> *mut TWJRepo {
    let Ok(root) = (unsafe { text(root) }) else { return std::ptr::null_mut() };
    match std::panic::catch_unwind(|| Repo::open(std::path::Path::new(root))) {
        Ok(Ok(repo)) => Box::into_raw(Box::new(TWJRepo(repo))),
        Ok(Err(e)) => {
            eprintln!("jj: open {root}: {e:#}");
            std::ptr::null_mut()
        }
        Err(_) => std::ptr::null_mut(),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_close(repo: *mut TWJRepo) {
    if !repo.is_null() {
        drop(unsafe { Box::from_raw(repo) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_set_lfs_limit(repo: *mut TWJRepo, bytes: u64) { unsafe { self::repo(repo) }.set_lfs_limit(bytes) }

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_set_utc_offset(repo: *mut TWJRepo, minutes: i32) { unsafe { self::repo(repo) }.set_utc_offset(minutes) }

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_commit(repo: *mut TWJRepo, message: *const c_char) -> *mut c_char {
    guard_repo(repo, |r| {
        let c = r.commit(unsafe { text(message) }?)?;
        Ok(json!({"commit": c.commit, "changed": c.changed}))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_squash(repo: *mut TWJRepo, policy: *const c_char) -> *mut c_char {
    guard_repo(repo, |r| {
        let policy = crate::retention::Policy::parse(unsafe { text(policy) }?)?;
        let (squashed, kept) = r.squash(&policy)?;
        Ok(json!({"squashed": squashed, "kept": kept}))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_file_history(repo: *mut TWJRepo, path: *const c_char, limit: u32) -> *mut c_char {
    guard(|| unsafe { self::repo(repo) }.file_history(unsafe { text(path) }?, limit))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_file_at(repo: *mut TWJRepo, commit: *const c_char, path: *const c_char) -> *mut c_char {
    guard(|| unsafe { self::repo(repo) }.file_at(unsafe { text(commit) }?, unsafe { text(path) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_restore_file(repo: *mut TWJRepo, commit: *const c_char, path: *const c_char) -> *mut c_char {
    guard_repo(repo, |r| r.restore_file(unsafe { text(commit) }?, unsafe { text(path) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_deleted(repo: *mut TWJRepo, prefix: *const c_char, limit: u32) -> *mut c_char {
    guard(|| unsafe { self::repo(repo) }.deleted(unsafe { text(prefix) }?, limit))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_delete(repo: *mut TWJRepo, paths: *const c_char, message: *const c_char) -> *mut c_char {
    guard_repo(repo, |r| {
        let paths: Vec<String> = serde_json::from_str(unsafe { text(paths) }?)?;
        r.delete(&paths, unsafe { text(message) }?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_restore_deleted(repo: *mut TWJRepo, entry: *const c_char, dest: *const c_char) -> *mut c_char {
    guard_repo(repo, |r| r.restore_deleted(unsafe { text(entry) }?, unsafe { text(dest) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_conflicts(repo: *mut TWJRepo, prefix: *const c_char) -> *mut c_char {
    guard(|| Ok(json!(unsafe { self::repo(repo) }.conflicts(unsafe { text(prefix) }?)?)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_conflict(repo: *mut TWJRepo, path: *const c_char) -> *mut c_char {
    guard(|| unsafe { self::repo(repo) }.conflict(unsafe { text(path) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_resolve(repo: *mut TWJRepo, path: *const c_char, text: *const c_char, side: i32) -> *mut c_char {
    guard_repo(repo, |r| {
        let resolution = if text.is_null() { None } else { Some(unsafe { self::text(text) }?) };
        r.resolve(unsafe { self::text(path) }?, resolution, side)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_export_node(repo: *mut TWJRepo, share: *const c_char, path: *const c_char) -> *mut c_char {
    guard_repo(repo, |r| r.export_node(unsafe { text(share) }?, unsafe { text(path) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_node(repo: *mut TWJRepo, share: *const c_char, node: *const c_char) -> *mut c_char {
    guard(|| unsafe { self::repo(repo) }.node(unsafe { text(share) }?, unsafe { text(node) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_missing_objects(repo: *mut TWJRepo, manifest: *const c_char) -> *mut c_char {
    guard(|| unsafe { self::repo(repo) }.missing_objects(unsafe { text(manifest) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_write_objects(repo: *mut TWJRepo, oids: *const c_char, dir: *const c_char) -> *mut c_char {
    guard(|| unsafe { self::repo(repo) }.write_objects(unsafe { text(oids) }?, unsafe { text(dir) }?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_import_node(
    repo: *mut TWJRepo,
    share: *const c_char,
    manifest: *const c_char,
    dir: *const c_char,
    label: *const c_char,
) -> *mut c_char {
    guard(|| {
        let r = unsafe { self::repo(repo) };
        r.import_node(unsafe { text(share) }?, unsafe { text(manifest) }?, unsafe { text(dir) }?, unsafe { text(label) }?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_merge_node(
    repo: *mut TWJRepo,
    share: *const c_char,
    path: *const c_char,
    node: *const c_char,
    lfs_dir: *const c_char,
) -> *mut c_char {
    unsafe { twj_merge_node_keeping(repo, share, path, node, lfs_dir, std::ptr::null()) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_merge_node_keeping(
    repo: *mut TWJRepo,
    share: *const c_char,
    path: *const c_char,
    node: *const c_char,
    lfs_dir: *const c_char,
    keep: *const c_char,
) -> *mut c_char {
    guard_repo(repo, |r| {
        let keep: Vec<String> = if keep.is_null() { Vec::new() } else { serde_json::from_str(unsafe { text(keep) }?)? };
        r.merge_node(unsafe { text(share) }?, unsafe { text(path) }?, unsafe { text(node) }?, unsafe { text(lfs_dir) }?, &keep)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn twj_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}
