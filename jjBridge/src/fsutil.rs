//! Atomic file writes (temp file + rename), so watchers and editors never see half-written files.
use std::fs;
use std::io::Write as _;
use std::path::Path;

use anyhow::{Context, Result};

use crate::repo::TEMP_PREFIX;

fn temp_in(dir: &Path) -> Result<tempfile::NamedTempFile> {
    fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    Ok(tempfile::Builder::new().prefix(TEMP_PREFIX).tempfile_in(dir)?)
}

#[cfg(unix)]
fn set_executable(file: &fs::File, executable: bool) -> Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    file.set_permissions(fs::Permissions::from_mode(if executable { 0o755 } else { 0o644 }))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_executable(_file: &fs::File, _executable: bool) -> Result<()> { Ok(()) }

/// Prepares `bytes` next to `path`; `commit()` renames it into place.
pub(crate) struct Staged {
    temp: tempfile::NamedTempFile,
    target: std::path::PathBuf,
}

impl Staged {
    pub fn commit(self) -> Result<()> {
        let target = self.target;
        if let Ok(meta) = fs::symlink_metadata(&target)
            && meta.is_dir()
        {
            fs::remove_dir_all(&target)?;
        }
        self.temp.persist(&target).with_context(|| format!("write {}", target.display()))?;
        Ok(())
    }
}

pub(crate) fn stage_bytes(path: &Path, bytes: &[u8], executable: bool) -> Result<Staged> {
    let mut temp = temp_in(path.parent().unwrap_or(Path::new(".")))?;
    temp.write_all(bytes)?;
    temp.as_file().sync_data().ok();
    set_executable(temp.as_file(), executable)?;
    Ok(Staged { temp, target: path.to_owned() })
}

pub(crate) fn stage_copy(path: &Path, source: &Path, executable: bool) -> Result<Staged> {
    let mut temp = temp_in(path.parent().unwrap_or(Path::new(".")))?;
    let mut input = fs::File::open(source).with_context(|| format!("read {}", source.display()))?;
    std::io::copy(&mut input, temp.as_file_mut())?;
    set_executable(temp.as_file(), executable)?;
    Ok(Staged { temp, target: path.to_owned() })
}

pub(crate) fn write_atomic(path: &Path, bytes: &[u8], executable: bool) -> Result<()> {
    stage_bytes(path, bytes, executable)?.commit()
}

/// Removes a file and then empty folders up to (not including) `stop`.
pub(crate) fn remove_and_prune(path: &Path, stop: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(path)?,
        Ok(_) => fs::remove_file(path)?,
        Err(_) => {}
    }
    let mut dir = path.parent();
    while let Some(d) = dir {
        if d == stop || !d.starts_with(stop) || fs::remove_dir(d).is_err() {
            break;
        }
        dir = d.parent();
    }
    Ok(())
}

#[cfg(unix)]
pub(crate) fn write_symlink(path: &Path, target: &str) -> Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let _ = fs::remove_file(path);
    std::os::unix::fs::symlink(target, path)?;
    Ok(())
}

#[cfg(not(unix))]
pub(crate) fn write_symlink(_path: &Path, _target: &str) -> Result<()> { Ok(()) }
