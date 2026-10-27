/// How a space file is opened; `id` matches the Swift enum's raw values.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Enum))]
pub enum FileKind {
    Folder,
    Typst,
    Text,
    Pdf,
    Font,
    /// Office files Quick Look can show: Word, Excel, PowerPoint, Pages, Numbers, Keynote.
    Document,
    Image,
    Binary,
}

const KINDS: [FileKind; 8] = [
    FileKind::Folder,
    FileKind::Typst,
    FileKind::Text,
    FileKind::Pdf,
    FileKind::Font,
    FileKind::Document,
    FileKind::Image,
    FileKind::Binary,
];

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
impl FileKind {
    pub fn id(&self) -> String {
        self.name().to_string()
    }

    pub fn is_editable(&self) -> bool {
        matches!(self, FileKind::Typst | FileKind::Text)
    }

    pub fn is_openable(&self) -> bool {
        !matches!(self, FileKind::Folder | FileKind::Binary)
    }
}

impl FileKind {
    pub fn name(self) -> &'static str {
        match self {
            FileKind::Folder => "folder",
            FileKind::Typst => "typst",
            FileKind::Text => "text",
            FileKind::Pdf => "pdf",
            FileKind::Font => "font",
            FileKind::Document => "document",
            FileKind::Image => "image",
            FileKind::Binary => "binary",
        }
    }
}

const TEXT: &[&str] = &[
    "bib", "yml", "yaml", "toml", "txt", "csv", "tsv", "json", "xml", "md", "svg", "html", "css", "js", "tex", "sty",
    "cls", "csl", "lua", "py", "sh", "swift", "rs", "c", "h", "ini", "cfg", "log", "gitignore",
];
const FONT: &[&str] = &["ttf", "otf", "ttc", "otc", "woff", "woff2"];
const DOCUMENT: &[&str] = &[
    "doc", "docx", "docm", "dot", "dotx", "xls", "xlsx", "xlsm", "xlt", "xltx", "ppt", "pptx", "pptm", "pot", "potx",
    "pps", "ppsx", "pages", "numbers", "key", "odt", "ods", "odp", "rtf",
];
const IMAGE: &[&str] = &["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico"];
const BINARY: &[&str] = &["zip", "gz", "tar", "dmg", "mp3", "mp4", "mov", "wav"];

/// The kind with the Swift enum's raw value `id`.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn file_kind_for_id(id: &str) -> Option<FileKind> {
    KINDS.into_iter().find(|kind| kind.name() == id)
}

/// None for unknown extensions; the caller sniffs the contents then.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn file_kind_for_extension(ext: &str) -> Option<FileKind> {
    let ext = ext.to_lowercase();
    let e = ext.as_str();
    Some(match e {
        "typ" => FileKind::Typst,
        "pdf" => FileKind::Pdf,
        _ if FONT.contains(&e) => FileKind::Font,
        _ if DOCUMENT.contains(&e) => FileKind::Document,
        _ if TEXT.contains(&e) => FileKind::Text,
        _ if IMAGE.contains(&e) => FileKind::Image,
        _ if BINARY.contains(&e) => FileKind::Binary,
        _ => return None,
    })
}

/// `path` relative to the space `root`, or None outside it.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn space_relative_path(path: &str, root: &str) -> Option<String> {
    let prefix = format!("{}/", root.trim_end_matches('/'));
    path.strip_prefix(&prefix).map(str::to_string)
}

/// A new file's normalized path inside a space.
#[derive(Clone, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
pub struct NewFilePath {
    pub path: String,
    pub adds_typ_extension: bool,
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn new_file_path(input: &str) -> Option<NewFilePath> {
    let input = input.trim();
    if input.starts_with('/') || input.contains('\0') {
        return None;
    }
    let mut parts = Vec::new();
    for part in input.split('/') {
        match part {
            ".." => return None,
            "" | "." => continue,
            _ => parts.push(part),
        }
    }
    if input.ends_with('/') || parts.is_empty() {
        parts.push("untitled");
    }
    let name = parts.last()?;
    let adds_typ_extension = !name.rsplit_once('.').is_some_and(|(stem, ext)| !stem.is_empty() && !ext.is_empty());
    let mut path = parts.join("/");
    if adds_typ_extension {
        path.push_str(".typ");
    }
    Some(NewFilePath { path, adds_typ_extension })
}

#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn file_folder_suggestions(input: &str, folders: Vec<String>) -> Vec<String> {
    let input = input.trim().to_lowercase();
    let mut matches: Vec<_> = folders.into_iter().map(|folder| format!("{}/", folder.trim_matches('/')))
        .filter(|folder| folder != "/" && folder.to_lowercase().starts_with(&input) && folder.to_lowercase() != input)
        .collect();
    matches.sort_by_key(|folder| folder.to_lowercase());
    matches.dedup();
    matches.truncate(20);
    matches
}

/// The first free name for a new item: `name`, then `name 2` for folders or `name-2` for files.
/// Returns the file name including `ext`.
pub fn unique_name(name: &str, ext: Option<&str>, exists: impl Fn(&str) -> bool) -> String {
    let make = |n: &str| match ext {
        Some(ext) => format!("{n}.{ext}"),
        None => n.to_string(),
    };
    let mut candidate = make(name);
    let mut i = 2;
    while exists(&candidate) {
        candidate = make(&if ext.is_none() { format!("{name} {i}") } else { format!("{name}-{i}") });
        i += 1;
    }
    candidate
}

/// The branch from a `.git/HEAD` file, or the short commit when detached.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn git_branch(head: &str) -> String {
    let reference = head.trim();
    match reference.strip_prefix("ref: refs/heads/") {
        Some(branch) => branch.to_string(),
        None => reference.chars().take(7).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_file_paths_keep_folders_and_default_the_extension() {
        assert_eq!(new_file_path("test/hello-world"), Some(NewFilePath {
            path: "test/hello-world.typ".into(), adds_typ_extension: true,
        }));
        assert_eq!(new_file_path("test.v1/hello-world.txt"), Some(NewFilePath {
            path: "test.v1/hello-world.txt".into(), adds_typ_extension: false,
        }));
        assert_eq!(new_file_path("test/").unwrap().path, "test/untitled.typ");
        assert_eq!(new_file_path("").unwrap().path, "untitled.typ");
        assert_eq!(new_file_path("./test//hello-world").unwrap().path, "test/hello-world.typ");
        assert_eq!(new_file_path("test/../outside"), None);
        assert_eq!(new_file_path("/outside"), None);
    }

    #[test]
    fn folder_suggestions_complete_space_relative_prefixes() {
        let folders = vec!["chapters".into(), "chapters/figures".into(), "fonts".into()];
        assert_eq!(file_folder_suggestions("CH", folders.clone()), ["chapters/", "chapters/figures/"]);
        assert_eq!(file_folder_suggestions("chapters/", folders.clone()), ["chapters/figures/"]);
        assert!(file_folder_suggestions("chapters/new-file", folders).is_empty());
    }

    #[test]
    fn names_and_paths() {
        let taken = ["untitled.typ", "untitled-2.typ", "Folder"];
        assert_eq!("untitled-3.typ", unique_name("untitled", Some("typ"), |n| taken.contains(&n)));
        assert_eq!("Folder 2", unique_name("Folder", None, |n| taken.contains(&n)));
        assert_eq!(Some("sub/a.typ".into()), space_relative_path("/space/sub/a.typ", "/space"));
        assert_eq!(None, space_relative_path("/spaces/a.typ", "/space"));
        assert_eq!("main", git_branch("ref: refs/heads/main\n"));
        assert_eq!("abcdef1", git_branch("abcdef1234567\n"));
        assert_eq!(Some(FileKind::Typst), file_kind_for_extension("TYP"));
        assert_eq!(None, file_kind_for_extension("weird"));
        assert_eq!(Some(FileKind::Document), file_kind_for_id("document"));
    }
}
