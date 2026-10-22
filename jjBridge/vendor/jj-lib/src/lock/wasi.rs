// Typewright: WASI has no file locks; in the web app one tab (a Web Lock) owns the repository.

#![expect(missing_docs)]

use std::fs::File;
use std::path::PathBuf;

use super::FileLockError;

pub struct FileLock {
    path: PathBuf,
    _file: File,
}

impl FileLock {
    pub fn lock(path: PathBuf) -> Result<Self, FileLockError> {
        let file = File::create(&path).map_err(|err| FileLockError {
            message: "Failed to open lock file",
            path: path.clone(),
            err,
        })?;
        Ok(Self { path, _file: file })
    }

    pub fn try_lock(path: PathBuf) -> Result<Option<Self>, FileLockError> {
        Self::lock(path).map(Some)
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        std::fs::remove_file(&self.path).ok();
    }
}
