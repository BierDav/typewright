use std::{ffi::{CStr, CString}, path::{Path, PathBuf}, sync::mpsc};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use jj_bridge::*;

type Reply = tokio::sync::oneshot::Sender<Value>;
pub struct Repository(mpsc::Sender<(Value, Reply)>);

fn take(ptr: *mut std::ffi::c_char) -> Result<Value> {
    if ptr.is_null() { return Err(anyhow!("Empty repository response")); }
    let result = serde_json::from_slice(unsafe { CStr::from_ptr(ptr) }.to_bytes());
    unsafe { twj_string_free(ptr) };
    Ok(result?)
}

fn filename(root: &Path, name: &str) -> Result<PathBuf> {
    if name.is_empty() || name.contains(['/', '\\', ':']) || name == "." || name == ".." { return Err(anyhow!("Invalid transport file")); }
    Ok(root.join(name))
}

unsafe fn call(repo: *mut TWJRepo, request: &Value) -> Result<Value> {
    let args = request["args"].as_array().cloned().unwrap_or_default();
    let text = |i: usize| -> Result<CString> { Ok(CString::new(args.get(i).and_then(Value::as_str).ok_or_else(|| anyhow!("Missing argument {i}"))?)?) };
    let number = |i: usize| args.get(i).and_then(Value::as_u64).unwrap_or_default();
    unsafe {
        take(match request["fn"].as_str().unwrap_or_default() {
            "twj_commit" => twj_commit(repo, text(0)?.as_ptr()),
            "twj_working_copy_changes" => twj_working_copy_changes(repo),
            "twj_squash" => twj_squash(repo, text(0)?.as_ptr()),
            "twj_file_history" => twj_file_history(repo, text(0)?.as_ptr(), number(1) as u32),
            "twj_file_at" => twj_file_at(repo, text(0)?.as_ptr(), text(1)?.as_ptr()),
            "twj_restore_file" => twj_restore_file(repo, text(0)?.as_ptr(), text(1)?.as_ptr()),
            "twj_delete" => twj_delete(repo, text(0)?.as_ptr(), text(1)?.as_ptr()),
            "twj_deleted" => twj_deleted(repo, text(0)?.as_ptr(), number(1) as u32),
            "twj_restore_deleted" => twj_restore_deleted(repo, text(0)?.as_ptr(), text(1)?.as_ptr()),
            "twj_conflicts" => twj_conflicts(repo, text(0)?.as_ptr()),
            "twj_conflict" => twj_conflict(repo, text(0)?.as_ptr()),
            "twj_resolve" => {
                let resolution = args.get(1).and_then(Value::as_str).map(CString::new).transpose()?;
                twj_resolve(repo, text(0)?.as_ptr(), resolution.as_ref().map_or(std::ptr::null(), |s| s.as_ptr()), number(2) as i32)
            },
            "twj_export_node" => twj_export_node(repo, text(0)?.as_ptr(), text(1)?.as_ptr()),
            "twj_node" => twj_node(repo, text(0)?.as_ptr(), text(1)?.as_ptr()),
            "twj_missing_objects" => twj_missing_objects(repo, text(0)?.as_ptr()),
            "twj_set_lfs_limit" => { twj_set_lfs_limit(repo, number(0)); return Ok(Value::Null); },
            _ => return Err(anyhow!("Unknown repository call")),
        })
    }
}

fn files(root: &Path, values: &Value) -> Result<()> {
    std::fs::create_dir_all(root)?;
    for entry in values.as_array().ok_or_else(|| anyhow!("Missing transport files"))? {
        let name = entry[0].as_str().ok_or_else(|| anyhow!("Invalid transport file"))?;
        let bytes: Vec<u8> = serde_json::from_value(entry[1].clone())?;
        std::fs::write(filename(root, name)?, bytes)?;
    }
    Ok(())
}

impl Repository {
    pub fn new(root: PathBuf) -> Self {
        let (tx, rx) = mpsc::channel::<(Value, Reply)>();
        std::thread::spawn(move || {
            let mut repo: *mut TWJRepo = std::ptr::null_mut();
            for (request, reply) in rx {
                let result = (|| -> Result<Value> {
                    let op = request["op"].as_str().unwrap_or_default();
                    if op == "open" {
                        if repo.is_null() {
                            repo = unsafe { twj_open(CString::new(root.to_string_lossy().as_bytes())?.as_ptr()) };
                        }
                        if repo.is_null() { return Err(anyhow!("Can't open the repository")); }
                        unsafe { twj_set_lfs_limit(repo, request["lfsLimit"].as_u64().unwrap_or(1 << 20)) };
                        return Ok(json!({ "mode": "native" }));
                    }
                    if repo.is_null() { return Err(anyhow!("The repository isn't open")); }
                    unsafe { twj_set_utc_offset(repo, request["utcOffset"].as_i64().unwrap_or_default() as i32) };
                    match op {
                        "invalidate" => Ok(Value::Null),
                        "call" => unsafe { call(repo, &request) },
                        "nodeObjects" => {
                            let temp = tempfile::tempdir()?;
                            let node = request["node"].as_str().ok_or_else(|| anyhow!("Missing node"))?;
                            let result = take(unsafe { twj_write_objects(repo, CString::new(json!([node]).to_string())?.as_ptr(), CString::new(temp.path().to_string_lossy().as_bytes())?.as_ptr()) })?;
                            if result.get("error").is_some() { return Ok(result); }
                            let mut objects = vec![];
                            for entry in std::fs::read_dir(temp.path())? {
                                let entry = entry?;
                                if entry.file_type()?.is_file() { objects.push(json!([entry.file_name().to_string_lossy(), std::fs::read(entry.path())?])); }
                            }
                            Ok(json!(objects))
                        },
                        "mergeNode" => {
                            let temp = tempfile::tempdir()?;
                            let objects = temp.path().join("objects");
                            let lfs = temp.path().join("lfs");
                            files(&objects, &request["objects"])?;
                            files(&lfs, &request["lfs"])?;
                            let s = |key: &str| -> Result<CString> { Ok(CString::new(request[key].as_str().ok_or_else(|| anyhow!("Missing {key}"))?)?) };
                            let imported = take(unsafe { twj_import_node(repo, s("share")?.as_ptr(), s("manifest")?.as_ptr(), CString::new(objects.to_string_lossy().as_bytes())?.as_ptr(), s("label")?.as_ptr()) })?;
                            if imported.get("error").is_some() { return Ok(imported); }
                            let node = CString::new(imported["node"].as_str().ok_or_else(|| anyhow!("Missing imported node"))?)?;
                            take(unsafe { twj_merge_node_keeping(repo, s("share")?.as_ptr(), s("path")?.as_ptr(), node.as_ptr(), CString::new(lfs.to_string_lossy().as_bytes())?.as_ptr(), CString::new(request["keep"].to_string())?.as_ptr()) })
                        },
                        _ => Err(anyhow!("Unknown repository operation")),
                    }
                })();
                let response = match result {
                    Ok(value) if value.get("error").is_some() && value.get("exists").is_none() => json!({ "ok": false, "error": value["error"], "busy": value["busy"] }),
                    Ok(value) => json!({ "ok": true, "value": value, "written": [] }),
                    Err(error) => json!({ "ok": false, "error": format!("{error:#}") }),
                };
                let _ = reply.send(response);
            }
            unsafe { twj_close(repo) };
        });
        Self(tx)
    }
}

#[tauri::command]
pub async fn repository(state: tauri::State<'_, Repository>, request: Value) -> Result<Value, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    state.0.send((request, tx)).map_err(|e| e.to_string())?;
    rx.await.map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(repo: &Repository, value: Value) -> Value {
        let (tx, rx) = tokio::sync::oneshot::channel();
        repo.0.send((value, tx)).unwrap();
        let response = rx.blocking_recv().unwrap();
        assert_eq!(response["ok"], true, "{response}");
        response["value"].clone()
    }
    #[test]
    fn native_history_and_sync_objects_use_the_existing_library() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("Spaces");
        std::fs::create_dir_all(root.join("Paper")).unwrap();
        std::fs::write(root.join("Paper/main.typ"), "First").unwrap();
        let repo = Repository::new(root.clone());
        assert_eq!(request(&repo, json!({"op":"open","lfsLimit":1048576}))["mode"], "native");
        request(&repo, json!({"op":"call","fn":"twj_commit","args":["Initial"]}));
        std::fs::write(root.join("Paper/main.typ"), "Second").unwrap();
        let commit = request(&repo, json!({"op":"call","fn":"twj_commit","args":["Edit"]}));
        assert!(commit["changed"].as_array().unwrap().contains(&json!("Paper/main.typ")));
        let history = request(&repo, json!({"op":"call","fn":"twj_file_history","args":["Paper/main.typ",10]}));
        assert!(history.as_array().unwrap().len() >= 2);
        let exported = request(&repo, json!({"op":"call","fn":"twj_export_node","args":["test-share","Paper"]}));
        let objects = request(&repo, json!({"op":"nodeObjects","node":exported["node"]}));
        assert!(!objects.as_array().unwrap().is_empty());
        assert_eq!(std::fs::read_to_string(root.join("Paper/main.typ")).unwrap(), "Second");
    }
}
