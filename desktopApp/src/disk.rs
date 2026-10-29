use std::{fs, path::{Component, Path, PathBuf}, sync::{Arc, Mutex}, collections::HashMap, time::UNIX_EPOCH};
use serde_json::{Value, json};
use tauri::Emitter;
use notify::Watcher;

pub struct Disk {
    pub root: PathBuf,
    written: Mutex<HashMap<PathBuf, Option<std::time::SystemTime>>>,
}

pub fn error(error: std::io::Error) -> String {
    let code = match error.kind() {
        std::io::ErrorKind::NotFound => "ENOENT",
        std::io::ErrorKind::PermissionDenied => "EACCES",
        std::io::ErrorKind::AlreadyExists => "EEXIST",
        std::io::ErrorKind::NotADirectory => "ENOTDIR",
        std::io::ErrorKind::IsADirectory => "EISDIR",
        std::io::ErrorKind::DirectoryNotEmpty => "ENOTEMPTY",
        _ => "EIO",
    };
    format!("{code}: {error}")
}

impl Disk {
    pub fn new(root: PathBuf) -> std::io::Result<Self> {
        fs::create_dir_all(root.join("Spaces"))?;
        Ok(Self { root: root.canonicalize()?, written: Mutex::new(HashMap::new()) })
    }

    pub fn path(&self, relative: &str) -> Result<PathBuf, String> {
        if relative.contains('\\') || relative.contains(':') { return Err("EACCES".into()); }
        let mut path = self.root.clone();
        for (i, part) in Path::new(relative).components().enumerate() {
            let Component::Normal(part) = part else { return Err("EACCES".into()) };
            path.push(if i == 0 && part == "spaces" { std::ffi::OsStr::new("Spaces") } else { part });
        }
        // Only linked packages may resolve outside the library.
        let packages = relative.starts_with("packages/");
        let mut existing = path.as_path();
        while !existing.exists() {
            existing = existing.parent().ok_or("EACCES")?;
        }
        if !existing.canonicalize().map_err(error)?.starts_with(&self.root) && !packages {
            return Err("EACCES".into());
        }
        Ok(path)
    }

    fn remember(&self, path: &Path) {
        self.written.lock().unwrap().insert(path.to_owned(), fs::metadata(path).and_then(|m| m.modified()).ok());
    }

    pub fn run(&self, op: &str, path: &str, to: Option<&str>, recursive: bool, data: &[u8]) -> Result<Value, String> {
        let path = self.path(path)?;
        match op {
            "stat" => match fs::metadata(path) {
                Ok(m) => Ok(json!({ "dir": m.is_dir(), "size": m.len(), "mtime": m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis()).unwrap_or(0) })),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Value::Null),
                Err(e) => Err(error(e)),
            },
            "list" => fs::read_dir(path).map_err(error)?.map(|entry| {
                let entry = entry.map_err(error)?;
                Ok(json!({ "name": entry.file_name().to_string_lossy(), "dir": entry.path().is_dir() }))
            }).collect::<Result<Vec<_>, String>>().map(|v| json!(v)),
            "write" => { fs::write(&path, data).map_err(error)?; self.remember(&path); Ok(Value::Null) },
            "mkdir" => { fs::create_dir_all(path).map_err(error)?; Ok(Value::Null) },
            "remove" => {
                let metadata = fs::symlink_metadata(&path).map_err(error)?;
                if metadata.is_dir() && !metadata.is_symlink() {
                    if recursive { fs::remove_dir_all(&path) } else { fs::remove_dir(&path) }
                } else { fs::remove_file(&path) }.map_err(error)?;
                self.remember(&path);
                Ok(Value::Null)
            },
            "rename" => {
                let to = self.path(to.ok_or("missing destination")?)?;
                fs::rename(&path, &to).map_err(error)?;
                self.remember(&path); self.remember(&to);
                Ok(Value::Null)
            },
            _ => Err("Unknown disk operation".into()),
        }
    }

    pub fn watch(self: &Arc<Self>, app: tauri::AppHandle) -> notify::Result<notify::RecommendedWatcher> {
        let disk = self.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        let mut watcher = notify::recommended_watcher(move |event| { let _ = tx.send(event); })?;
        watcher.watch(&self.root, notify::RecursiveMode::Recursive)?;
        std::thread::spawn(move || {
            while let Ok(first) = rx.recv() {
                let mut events = vec![first];
                while let Ok(event) = rx.recv_timeout(std::time::Duration::from_millis(150)) { events.push(event); }
                let mut paths = std::collections::BTreeSet::new();
                for event in events.into_iter().filter_map(Result::ok) {
                    if matches!(event.kind, notify::EventKind::Access(_)) { continue; }
                    for path in event.paths {
                        let Ok(relative) = path.strip_prefix(&disk.root) else { continue };
                        let relative = relative.to_string_lossy().replace('\\', "/");
                        if relative == "jj-host" || relative.starts_with("jj-host/") || relative == "Spaces/.jj" || relative.starts_with("Spaces/.jj/") { continue; }
                        let own = disk.written.lock().unwrap().get(&path).cloned();
                        let modified = fs::metadata(&path).and_then(|m| m.modified()).ok();
                        if own.is_some_and(|own| own == modified) { continue; }
                        paths.insert(if relative == "Spaces" { "spaces".into() } else if let Some(rest) = relative.strip_prefix("Spaces/") { format!("spaces/{rest}") } else { relative });
                    }
                }
                if !paths.is_empty() { let _ = app.emit("library-changed", paths); }
            }
        });
        Ok(watcher)
    }
}

#[tauri::command]
pub async fn disk_op(disk: tauri::State<'_, Arc<Disk>>, op: String, path: String, to: Option<String>, recursive: Option<bool>, data: Option<Vec<u8>>) -> Result<Value, String> {
    let disk = disk.inner().clone();
    tauri::async_runtime::spawn_blocking(move || disk.run(&op, &path, to.as_deref(), recursive.unwrap_or(false), &data.unwrap_or_default())).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn disk_read(disk: tauri::State<'_, Arc<Disk>>, path: String) -> Result<tauri::ipc::Response, String> {
    let path = disk.path(&path)?;
    tauri::async_runtime::spawn_blocking(move || fs::read(path).map(tauri::ipc::Response::new).map_err(error)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn disk_write(disk: tauri::State<'_, Arc<Disk>>, request: tauri::ipc::Request<'_>) -> Result<(), String> {
    let path = request.headers().get("x-typewright-path").and_then(|h| h.to_str().ok()).ok_or("Missing path")?;
    let path = percent_encoding::percent_decode_str(path).decode_utf8().map_err(|e| e.to_string())?.into_owned();
    let tauri::ipc::InvokeBody::Raw(data) = request.body() else { return Err("Expected file bytes".into()) };
    let data = data.clone();
    let disk = disk.inner().clone();
    tauri::async_runtime::spawn_blocking(move || disk.run("write", &path, None, false, &data).map(|_| ())).await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn maps_spaces_and_rejects_escape() {
        let temp = tempfile::tempdir().unwrap();
        let disk = Disk::new(temp.path().to_owned()).unwrap();
        assert_eq!(disk.path("spaces/test.typ").unwrap(), temp.path().canonicalize().unwrap().join("Spaces/test.typ"));
        for path in ["../outside", "/outside", "spaces/../../outside", "C:/outside", "spaces\\..\\outside"] { assert!(disk.path(path).is_err(), "{path}"); }
    }
    #[test]
    fn writes_renames_and_removes_native_files() {
        let temp = tempfile::tempdir().unwrap();
        let disk = Disk::new(temp.path().to_owned()).unwrap();
        disk.run("write", "spaces/a.typ", None, false, b"Hello").unwrap();
        disk.run("rename", "spaces/a.typ", Some("spaces/b.typ"), false, &[]).unwrap();
        assert_eq!(fs::read(temp.path().join("Spaces/b.typ")).unwrap(), b"Hello");
        disk.run("remove", "spaces/b.typ", None, false, &[]).unwrap();
        assert_eq!(disk.run("stat", "spaces/b.typ", None, false, &[]).unwrap(), Value::Null);
    }
}
