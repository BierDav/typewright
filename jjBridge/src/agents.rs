use std::fs::OpenOptions;
use std::io::{ErrorKind, Write as _};
use std::path::Path;

const TEMPLATE: &str = include_str!("agents.txt");

pub(crate) fn ensure(root: &Path) {
    #[cfg(target_os = "macos")]
    if let Ok(executable) = std::env::current_exe()
        && executable.parent().is_some_and(|p| p.ends_with("Contents/MacOS"))
    {
        if let Err(e) = ensure_cli(root, &executable) {
            eprintln!("jj: can't install the Typewright CLI wrapper: {e:#}");
        }
    }
    let result = (|| -> std::io::Result<()> {
        // Exclusive creation preserves edits, empty files and symlinks, even with concurrent agents.
        match OpenOptions::new().write(true).create_new(true).open(root.join("AGENTS.md")) {
            Ok(mut file) => file.write_all(TEMPLATE.as_bytes()),
            Err(e) if e.kind() == ErrorKind::AlreadyExists => Ok(()),
            Err(e) => Err(e),
        }
    })();
    if let Err(e) = result {
        eprintln!("jj: can't create AGENTS.md: {e}");
    }
}

#[cfg(target_os = "macos")]
fn ensure_cli(root: &Path, executable: &Path) -> anyhow::Result<()> {
    let path = root.join(".jj/typewright/bin/typewright");
    let quoted = executable.to_string_lossy().replace('\'', "'\\''");
    let script = format!("#!/bin/sh\nexec '{quoted}' --cli \"$@\"\n");
    if std::fs::read_to_string(&path).ok().as_deref() != Some(&script) {
        std::fs::create_dir_all(path.parent().unwrap())?;
        crate::fsutil::write_atomic(&path, script.as_bytes(), true)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    use crate::Repo;

    #[cfg(target_os = "macos")]
    #[test]
    fn cli_wrapper_quotes_the_app_path_and_preserves_arguments() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let executable = root.join("Typewright's App.app/Contents/MacOS/Typewright");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        crate::fsutil::write_atomic(&executable, b"#!/bin/sh\nprintf '%s\\n' \"$@\"\n", true).unwrap();
        ensure_cli(root, &executable).unwrap();
        let wrapper = root.join(".jj/typewright/bin/typewright");
        let result = std::process::Command::new(&wrapper).args(["path with spaces", "$(literal)"]).output().unwrap();
        assert!(result.status.success());
        assert_eq!(String::from_utf8(result.stdout).unwrap(), "--cli\npath with spaces\n$(literal)\n");
        fs::remove_file(&wrapper).unwrap();
        ensure_cli(root, &executable).unwrap();
        assert!(wrapper.exists());
    }

    #[test]
    fn opening_and_checking_changes_restore_missing_guidance() {
        crate::tests::setup();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("AGENTS.md");
        let mut repo = Repo::open(dir.path()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), TEMPLATE);
        assert!(repo.commit("Initial").unwrap().changed.is_empty());

        fs::remove_file(&path).unwrap();
        repo.working_copy_changes().unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), TEMPLATE);

        fs::remove_file(&path).unwrap();
        repo.commit("Check").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), TEMPLATE);

        drop(repo);
        fs::remove_file(&path).unwrap();
        Repo::open(dir.path()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), TEMPLATE);
    }

    #[test]
    fn existing_guidance_is_preserved_and_only_root_guidance_is_ignored() {
        crate::tests::setup();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("AGENTS.md");
        fs::write(&path, "My instructions").unwrap();
        let mut repo = Repo::open(dir.path()).unwrap();
        repo.commit("Check").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "My instructions");

        fs::write(&path, "").unwrap();
        repo.working_copy_changes().unwrap();
        drop(repo);
        let mut repo = Repo::open(dir.path()).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "");

        fs::create_dir(dir.path().join("Space")).unwrap();
        fs::write(dir.path().join("Space/AGENTS.md"), "Space instructions").unwrap();
        assert_eq!(repo.commit("Add instructions").unwrap().changed, vec!["Space/AGENTS.md"]);
    }

    #[cfg(unix)]
    #[test]
    fn existing_symlinks_are_preserved_even_when_the_target_is_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("AGENTS.md");
        let target = dir.path().join("instructions");
        std::os::unix::fs::symlink(&target, &path).unwrap();
        ensure(dir.path());
        assert_eq!(fs::read_link(&path).unwrap(), target);
        assert!(!target.exists());
        fs::write(&target, "Custom instructions").unwrap();
        ensure(dir.path());
        assert_eq!(fs::read_to_string(&target).unwrap(), "Custom instructions");
    }
}
