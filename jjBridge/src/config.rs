//! The managed jj repo config (read by the CLI and the bridge) and the backend's `info/exclude` listing LFS files.
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::Result;
use jj_lib::git_backend::GitBackend;
use jj_lib::repo::Repo as _;

use crate::repo::{BASE_IGNORES, Repo, State};

const TEMPLATE: &str = include_str!("repo_config.toml");
#[cfg(test)]
const VERSION_PREFIX: &str = "# typewright-config-version: ";
const EXCLUDE_BEGIN: &str = "# >>> typewright (managed, rewritten on every change)";
const EXCLUDE_END: &str = "# <<< typewright";

fn hash(bytes: &[u8]) -> String { blake3::hash(bytes).to_hex().to_string() }

#[cfg(test)]
pub(crate) fn version(text: &str) -> Option<&str> { text.lines().next()?.strip_prefix(VERSION_PREFIX) }

fn human(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 20 && b % (1 << 20) == 0 => format!("{} MiB", b >> 20),
        b if b >= 1 << 10 && b % (1 << 10) == 0 => format!("{} KiB", b >> 10),
        b => format!("{b} bytes"),
    }
}

/// The real home, also inside the sandbox (whose `HOME` is the container).
#[cfg(unix)]
pub(crate) fn real_home() -> Option<PathBuf> {
    // SAFETY: getpwuid returns a pointer into static storage or null; we copy the string out right away.
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() || (*pw).pw_dir.is_null() {
            return std::env::var_os("HOME").map(PathBuf::from);
        }
        let dir = std::ffi::CStr::from_ptr((*pw).pw_dir);
        Some(PathBuf::from(std::ffi::OsStr::from_encoded_bytes_unchecked(dir.to_bytes())))
    }
}

/// jj's config root, as the CLI picks it (etcetera's XDG strategy, also on macOS): `$XDG_CONFIG_HOME/jj` or
/// `~/.config/jj`. None where there's no CLI to read it.
#[cfg(unix)]
pub(crate) fn jj_config_root() -> Option<PathBuf> {
    match std::env::var_os("XDG_CONFIG_HOME") {
        Some(dir) if Path::new(&dir).is_absolute() => Some(PathBuf::from(dir).join("jj")),
        _ => real_home().map(|home| home.join(".config/jj")),
    }
}

#[cfg(not(unix))]
pub(crate) fn jj_config_root() -> Option<PathBuf> { None }

fn render(root: &Path, config_path: &Path, limit: u64) -> String {
    TEMPLATE
        .replace("{{ROOT}}", &root.display().to_string())
        .replace("{{LIMIT_HUMAN}}", &human(limit))
        .replace("{{LIMIT}}", &limit.to_string())
        .replace("{{CONFIG_PATH}}", &config_path.display().to_string().replace('\\', "\\\\").replace('"', "\\\""))
}

/// Writes the managed config where jj 0.46 reads repo config (`<jj config root>/repos/<config-id>/config.toml`,
/// the id in `.jj/repo/config-id`); returns its path. Never fails the caller: problems are logged.
pub(crate) fn ensure_repo_config(repo_dir: &Path, state: &mut State, limit: u64) -> Option<PathBuf> {
    match try_ensure_repo_config(repo_dir, state, limit) {
        Ok(path) => path,
        Err(e) => {
            eprintln!("jj: can't write the repo config: {e:#}");
            None
        }
    }
}

fn try_ensure_repo_config(repo_dir: &Path, state: &mut State, limit: u64) -> Result<Option<PathBuf>> {
    let Some(root) = jj_config_root() else { return Ok(None) };
    use rand_chacha::rand_core::SeedableRng as _;
    let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos() as u64)
        ^ u64::from(std::process::id()) << 32;
    let mut rng = rand_chacha::ChaCha20Rng::seed_from_u64(seed);
    let secure = jj_lib::secure_config::SecureConfig::new_repo(repo_dir.to_owned());
    let loaded = secure.load_config(&mut rng, &root.join("repos"))?;
    let Some(path) = loaded.config_file else { return Ok(None) };
    let workspace_root = repo_dir.parent().and_then(Path::parent).unwrap_or(repo_dir);
    let rendered = render(workspace_root, &path, limit);
    let current = fs::read_to_string(&path).ok().filter(|c| !c.trim().is_empty());
    match current {
        None => write(&path, &rendered, state)?,
        Some(c) if Some(hash(c.as_bytes())) == state.config_hash => {
            if c != rendered {
                write(&path, &rendered, state)?;
            }
        }
        Some(_) => {
            // The user edited it: leave their file alone, only keep the LFS limit current.
            let mut file = jj_lib::config::ConfigFile::load_or_empty(jj_lib::config::ConfigSource::Repo, &path)?;
            let key = "snapshot.max-new-file-size";
            let current_limit = file.layer().look_up_item(key).ok().flatten().and_then(|v| v.as_integer());
            if current_limit != Some(limit as i64) {
                file.set_value(key, limit as i64)?;
                file.save()?;
            }
        }
    }
    Ok(Some(path))
}

fn write(path: &Path, text: &str, state: &mut State) -> Result<()> {
    crate::fsutil::write_atomic(path, text.as_bytes(), false)?;
    state.config_hash = Some(hash(text.as_bytes()));
    Ok(())
}

/// The backing git repo's `info/exclude`, which the jj CLI reads for non-colocated repos too.
pub(crate) fn exclude_path(repo: &Repo) -> Option<PathBuf> {
    let head = repo.head().ok()?;
    let backend = head.store().backend_impl::<GitBackend>()?;
    Some(backend.git_repo_path().join("info").join("exclude"))
}

/// `info/exclude` without our block (the bridge has its own rules for LFS files).
pub(crate) fn user_excludes(repo: &Repo) -> Option<Vec<u8>> {
    let text = fs::read_to_string(exclude_path(repo)?).ok()?;
    let mut kept = String::new();
    let mut inside = false;
    for line in text.lines() {
        if line == EXCLUDE_BEGIN {
            inside = true;
        } else if line == EXCLUDE_END {
            inside = false;
        } else if !inside {
            kept.push_str(line);
            kept.push('\n');
        }
    }
    Some(kept.into_bytes())
}

/// `core.excludesFile` from git's config, which the CLI honours as well.
pub(crate) fn global_excludes_file(repo: &Repo) -> Option<PathBuf> {
    let head = repo.head().ok()?;
    let backend = head.store().backend_impl::<GitBackend>()?;
    let git = backend.git_repo();
    let config = git.config_snapshot();
    let value = config.string("core.excludesFile")?;
    let value = std::str::from_utf8(&value).ok()?.to_owned();
    let path = match value.strip_prefix("~/") {
        Some(rest) => home()?.join(rest),
        None => PathBuf::from(value),
    };
    path.is_file().then_some(path)
}

#[cfg(unix)]
fn home() -> Option<PathBuf> { real_home() }
#[cfg(not(unix))]
fn home() -> Option<PathBuf> { None }

/// Anchored, escaped gitignore pattern for one repo path.
fn pattern(path: &str) -> String {
    let mut out = String::from("/");
    for c in path.chars() {
        if matches!(c, '*' | '?' | '[' | ']' | '\\' | '!' | '#') {
            out.push('\\');
        }
        out.push(c);
    }
    if out.ends_with(' ') {
        out.insert(out.len() - 1, '\\');
    }
    out
}

impl Repo {
    /// Rewrites our block of `info/exclude`: Finder litter and every LFS file, so the CLI never tracks them either.
    pub(crate) fn write_excludes(&self) -> Result<()> {
        #[cfg(target_os = "macos")]
        crate::colocation::ensure_layout(self.root())?;
        let Some(path) = exclude_path(self) else { return Ok(()) };
        let existing = fs::read_to_string(&path).unwrap_or_default();
        let mut kept = String::new();
        let mut inside = false;
        for line in existing.lines() {
            if line == EXCLUDE_BEGIN {
                inside = true;
            } else if line == EXCLUDE_END {
                inside = false;
            } else if !inside {
                kept.push_str(line);
                kept.push('\n');
            }
        }
        let mut block = format!("{EXCLUDE_BEGIN}\n{BASE_IGNORES}");
        // New binary files stay invisible to the CLI; the bridge reads this file without this block and lists them.
        for ext in crate::lfs::BINARY_EXTENSIONS {
            let class: String = ext
                .chars()
                .map(|c| if c.is_ascii_alphabetic() { format!("[{}{}]", c.to_ascii_lowercase(), c.to_ascii_uppercase()) } else { c.to_string() })
                .collect();
            block.push_str(&format!("*.{class}\n"));
        }
        for key in self.state.lfs.keys() {
            block.push_str(&pattern(key));
            block.push('\n');
        }
        block.push_str(EXCLUDE_END);
        block.push('\n');
        let text = format!("{kept}{block}");
        if text != existing {
            fs::create_dir_all(path.parent().unwrap())?;
            crate::fsutil::write_atomic(&path, text.as_bytes(), false)?;
        }
        Ok(())
    }
}

#[cfg(test)]
pub(crate) fn test_pattern(path: &str) -> String { pattern(path) }
