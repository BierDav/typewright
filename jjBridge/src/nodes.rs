//! Sync nodes: deterministic git commits of a share's subtree (see ../jj-spares-folder-test). The id depends only on
//! content and parents: pinned identity and date, message = content digest (+ the LFS files, which aren't in the tree).
use std::collections::{BTreeMap, BTreeSet, HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, anyhow, bail};
use gix::ObjectId;
use gix::objs::Kind;
use jj_lib::backend::{CopyId, FileId, MergedTreeValue, SymlinkId, TreeId, TreeValue};
use jj_lib::conflict_labels::ConflictLabels;
use jj_lib::git_backend::GitBackend;
use jj_lib::matchers::PrefixMatcher;
use jj_lib::merge::Merge;
use jj_lib::merged_tree::MergedTree;
use jj_lib::merged_tree_builder::MergedTreeBuilder;
use jj_lib::object_id::ObjectId as _;
use jj_lib::repo::Repo as _;
use jj_lib::repo_path::{RepoPath, RepoPathBuf};
use pollster::FutureExt as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::lfs::LfsFile;
use crate::repo::{Repo, diff_files, repo_path};

/// The single entry of a file share's tree; fixed so the recipient's file name doesn't change the node id.
pub(crate) const FILE_ENTRY: &str = "@file";
const IDENT: &str = "Typewright Sync <sync@typewright.invalid> 1767225600 +0000";
const MESSAGE_PREFIX: &str = "typewright-node ";
const ANCESTRY_LIMIT: usize = 64;

#[derive(Clone, Copy, PartialEq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ShareKind {
    Folder,
    File,
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub(crate) struct ShareState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<ShareKind>,
    /// The last node this share was exported as or merged to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head: Option<String>,
    /// Parents of the merge waiting for conflicts to be resolved.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pending: Vec<String>,
    /// Who imported nodes came from, for conflict sides.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub labels: BTreeMap<String, String>,
}

#[derive(Clone, PartialEq, Debug)]
pub(crate) struct LfsEntry {
    pub mode: String,
    pub size: u64,
    pub blake3: String,
    /// Modification time (unix seconds) when this content was first exported; decides which side is newest.
    pub time: i64,
}

impl LfsEntry {
    fn same_content(a: Option<&LfsEntry>, b: Option<&LfsEntry>) -> bool {
        match (a, b) {
            (Some(a), Some(b)) => a.blake3 == b.blake3 && a.mode == b.mode,
            (None, None) => true,
            _ => false,
        }
    }
}

pub(crate) struct Node {
    pub id: ObjectId,
    pub tree: ObjectId,
    pub parents: Vec<ObjectId>,
    pub lfs: BTreeMap<String, LfsEntry>,
}

struct TreeEntry {
    mode: String,
    name: Vec<u8>,
    oid: ObjectId,
}

pub(crate) fn local_label() -> &'static str { if cfg!(target_os = "macos") { "This Mac" } else { "This Device" } }

pub(crate) fn oid(hex: &str) -> Result<ObjectId> {
    ObjectId::from_hex(hex.as_bytes()).map_err(|_| anyhow!("invalid object id {hex:?}"))
}

fn to_oid(bytes: &[u8]) -> ObjectId { ObjectId::from_bytes_or_panic(bytes) }

fn parse_tree(data: &[u8]) -> Result<Vec<TreeEntry>> {
    let mut entries = Vec::new();
    let mut rest = data;
    while !rest.is_empty() {
        let space = rest.iter().position(|b| *b == b' ').ok_or_else(|| anyhow!("bad tree"))?;
        let nul = rest.iter().position(|b| *b == 0).ok_or_else(|| anyhow!("bad tree"))?;
        if nul < space || rest.len() < nul + 21 {
            bail!("bad tree");
        }
        entries.push(TreeEntry {
            mode: String::from_utf8_lossy(&rest[..space]).into_owned(),
            name: rest[space + 1..nul].to_vec(),
            oid: to_oid(&rest[nul + 1..nul + 21]),
        });
        rest = &rest[nul + 21..];
    }
    Ok(entries)
}

fn encode_tree(mut entries: Vec<TreeEntry>) -> Vec<u8> {
    // Git sorts directories as if their names ended in "/".
    let key = |e: &TreeEntry| {
        let mut k = e.name.clone();
        if e.mode == "40000" {
            k.push(b'/');
        }
        k
    };
    entries.sort_by_key(key);
    let mut out = Vec::new();
    for e in entries {
        out.extend_from_slice(e.mode.as_bytes());
        out.push(b' ');
        out.extend_from_slice(&e.name);
        out.push(0);
        out.extend_from_slice(e.oid.as_bytes());
    }
    out
}

fn digest(files: &BTreeMap<String, (String, ObjectId)>, lfs: &BTreeMap<String, LfsEntry>) -> String {
    let mut lines: BTreeMap<&str, String> = BTreeMap::new();
    for (path, (mode, oid)) in files {
        lines.insert(path, format!("{mode} {path}\0{oid}\n"));
    }
    for (path, e) in lfs {
        lines.insert(path, format!("{} {path}\0lfs:{}\n", e.mode, e.blake3));
    }
    let mut hasher = blake3::Hasher::new();
    for line in lines.values() {
        hasher.update(line.as_bytes());
    }
    format!("blake3:{}", hasher.finalize().to_hex())
}

fn node_body(tree: &ObjectId, parents: &[ObjectId], digest: &str, lfs: &BTreeMap<String, LfsEntry>) -> Vec<u8> {
    let mut body = format!("tree {tree}\n");
    for parent in parents {
        body += &format!("parent {parent}\n");
    }
    body += &format!("author {IDENT}\ncommitter {IDENT}\n\n{MESSAGE_PREFIX}{digest}\n");
    if !lfs.is_empty() {
        body.push('\n');
        for (path, e) in lfs {
            body += &format!("lfs {} {} {} {} {}\n", e.blake3, e.size, e.time, e.mode, path);
        }
    }
    body.into_bytes()
}

fn parse_node(id: ObjectId, data: &[u8]) -> Result<Node> {
    let text = std::str::from_utf8(data).context("node isn't UTF-8")?;
    let (header, message) = text.split_once("\n\n").ok_or_else(|| anyhow!("bad commit {id}"))?;
    let mut tree = None;
    let mut parents = Vec::new();
    for line in header.lines() {
        if let Some(t) = line.strip_prefix("tree ") {
            tree = Some(oid(t)?);
        } else if let Some(p) = line.strip_prefix("parent ") {
            parents.push(oid(p)?);
        }
    }
    if !message.starts_with(MESSAGE_PREFIX) {
        bail!("{id} is not a sync node");
    }
    let mut lfs = BTreeMap::new();
    for line in message.lines().filter_map(|l| l.strip_prefix("lfs ")) {
        let parts: Vec<&str> = line.splitn(5, ' ').collect();
        if parts.len() == 5 {
            lfs.insert(parts[4].to_owned(), LfsEntry {
                blake3: parts[0].to_owned(),
                size: parts[1].parse()?,
                time: parts[2].parse()?,
                mode: parts[3].to_owned(),
            });
        }
    }
    Ok(Node { id, tree: tree.ok_or_else(|| anyhow!("commit {id} has no tree"))?, parents, lfs })
}

fn conflict_name(path: &str, taken: &BTreeSet<String>) -> String {
    let (dir, name) = match path.rfind('/') {
        Some(i) => (&path[..=i], &path[i + 1..]),
        None => ("", path),
    };
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    let mut n = 1;
    loop {
        let suffix = if n == 1 { " (conflict)".to_owned() } else { format!(" (conflict {n})") };
        let candidate = format!("{dir}{stem}{suffix}{ext}");
        if !taken.contains(&candidate) {
            return candidate;
        }
        n += 1;
    }
}

/// Three-way merge of LFS files: one-sided changes apply, the newest of two changes wins, the other becomes a copy.
fn merge_lfs(
    base: &BTreeMap<String, LfsEntry>,
    local: &BTreeMap<String, LfsEntry>,
    remote: &BTreeMap<String, LfsEntry>,
    text_paths: &BTreeSet<String>,
) -> BTreeMap<String, LfsEntry> {
    let paths: BTreeSet<&String> = base.keys().chain(local.keys()).chain(remote.keys()).collect();
    let mut result = BTreeMap::new();
    let mut losers = Vec::new();
    for path in paths {
        let (b, l, r) = (base.get(path), local.get(path), remote.get(path));
        let chosen = if LfsEntry::same_content(l, r) {
            match (l, r) {
                (Some(l), Some(r)) => Some(if l.time <= r.time { l.clone() } else { r.clone() }),
                _ => None,
            }
        } else if LfsEntry::same_content(l, b) {
            r.cloned()
        } else if LfsEntry::same_content(r, b) {
            l.cloned()
        } else {
            match (l, r) {
                (Some(l), Some(r)) => {
                    let (winner, loser) = if (l.time, &l.blake3) >= (r.time, &r.blake3) { (l, r) } else { (r, l) };
                    losers.push((path.clone(), loser.clone()));
                    Some(winner.clone())
                }
                // A change beats a deletion.
                (Some(x), None) | (None, Some(x)) => Some(x.clone()),
                (None, None) => None,
            }
        };
        if let Some(entry) = chosen {
            result.insert(path.clone(), entry);
        }
    }
    let mut taken: BTreeSet<String> = result.keys().cloned().chain(text_paths.iter().cloned()).collect();
    for (path, entry) in losers {
        let name = conflict_name(&path, &taken);
        taken.insert(name.clone());
        result.insert(name, entry);
    }
    // A text file and an LFS file at one path: the LFS one moves aside.
    let clashes: Vec<String> = result.keys().filter(|p| text_paths.contains(*p)).cloned().collect();
    for path in clashes {
        let entry = result.remove(&path).unwrap();
        let name = conflict_name(&path, &taken);
        taken.insert(name.clone());
        result.insert(name, entry);
    }
    result
}

/// What a share holds locally right now.
struct Local {
    kind: ShareKind,
    tree: ObjectId,
    lfs: BTreeMap<String, (LfsFile, String, String)>,
}

struct Odb(gix::Repository);

impl Odb {
    fn read(&self, id: ObjectId) -> Result<(Kind, Vec<u8>)> {
        let object = self.0.find_object(id).map_err(|e| anyhow!("object {id}: {e}"))?;
        Ok((object.kind, object.data.clone()))
    }

    fn has(&self, id: &ObjectId) -> bool { self.0.has_object(id) }

    fn write(&self, kind: Kind, data: &[u8]) -> Result<ObjectId> {
        gix::objs::Write::write_buf(&self.0.objects, kind, data).map_err(|e| anyhow!("write object: {e}"))
    }

    fn tree(&self, id: ObjectId) -> Result<Vec<TreeEntry>> {
        let (kind, data) = self.read(id)?;
        if kind != Kind::Tree {
            bail!("{id} is not a tree");
        }
        parse_tree(&data)
    }

    fn empty_tree(&self) -> Result<ObjectId> { self.write(Kind::Tree, b"") }

    fn node(&self, id: ObjectId) -> Result<Node> {
        let (kind, data) = self.read(id)?;
        if kind != Kind::Commit {
            bail!("{id} is not a commit");
        }
        parse_node(id, &data)
    }

    /// Every file of a tree by path: (mode, blob id).
    fn files(&self, tree: ObjectId, prefix: &str, out: &mut BTreeMap<String, (String, ObjectId)>) -> Result<()> {
        for e in self.tree(tree)? {
            let path = format!("{prefix}{}", String::from_utf8_lossy(&e.name));
            match e.mode.as_str() {
                "40000" => self.files(e.oid, &format!("{path}/"), out)?,
                "160000" => {}
                _ => {
                    out.insert(path, (e.mode, e.oid));
                }
            }
        }
        Ok(())
    }

    /// Trees and blobs reachable from `tree`, skipping those in `known` (and below known trees).
    fn closure(&self, tree: ObjectId, known: &HashSet<ObjectId>, out: &mut Vec<ObjectId>, seen: &mut HashSet<ObjectId>) -> Result<()> {
        if known.contains(&tree) || !seen.insert(tree) {
            return Ok(());
        }
        out.push(tree);
        for e in self.tree(tree)? {
            match e.mode.as_str() {
                "40000" => self.closure(e.oid, known, out, seen)?,
                "160000" => {}
                _ => {
                    if !known.contains(&e.oid) && seen.insert(e.oid) {
                        out.push(e.oid);
                    }
                }
            }
        }
        Ok(())
    }

    fn missing_in_tree(&self, tree: ObjectId, missing: &mut Vec<ObjectId>) -> Result<()> {
        if !self.has(&tree) {
            missing.push(tree);
            return Ok(());
        }
        for e in self.tree(tree)? {
            match e.mode.as_str() {
                "40000" => self.missing_in_tree(e.oid, missing)?,
                "160000" => {}
                _ => {
                    if !self.has(&e.oid) {
                        missing.push(e.oid);
                    }
                }
            }
        }
        Ok(())
    }

    /// Ancestors (including `start`) in breadth-first order, newest first; missing commits end a path.
    fn ancestors(&self, start: &[ObjectId], limit: usize) -> Vec<ObjectId> {
        let mut seen = HashSet::new();
        let mut queue: VecDeque<ObjectId> = start.iter().copied().collect();
        let mut out = Vec::new();
        while let Some(id) = queue.pop_front() {
            if out.len() >= limit {
                break;
            }
            if !seen.insert(id) {
                continue;
            }
            let Ok(node) = self.node(id) else { continue };
            out.push(id);
            queue.extend(node.parents);
        }
        out
    }

    fn set_ref(&self, name: &str, target: ObjectId) -> Result<()> {
        self.0
            .reference(name, target, gix::refs::transaction::PreviousValue::Any, "typewright sync")
            .map_err(|e| anyhow!("update {name}: {e}"))?;
        Ok(())
    }
}

fn ref_component(share: &str) -> String {
    share
        .bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

fn tree_id(oid: &ObjectId) -> TreeId { TreeId::new(oid.as_bytes().to_vec()) }

fn file_value(entry: &TreeEntry) -> Option<TreeValue> {
    match entry.mode.as_str() {
        "100644" | "100755" => Some(TreeValue::File {
            id: FileId::new(entry.oid.as_bytes().to_vec()),
            executable: entry.mode == "100755",
            copy_id: CopyId::placeholder(),
        }),
        "120000" => Some(TreeValue::Symlink(SymlinkId::new(entry.oid.as_bytes().to_vec()))),
        _ => None,
    }
}

#[cfg(unix)]
fn disk_mode(path: &Path) -> String {
    use std::os::unix::fs::PermissionsExt as _;
    match fs::metadata(path) {
        Ok(meta) if meta.permissions().mode() & 0o111 != 0 => "100755".into(),
        _ => "100644".into(),
    }
}

#[cfg(not(unix))]
fn disk_mode(_path: &Path) -> String { "100644".into() }

fn manifest_ids(manifest: &Value, key: &str) -> Vec<String> {
    manifest[key].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()).unwrap_or_default()
}

impl Repo {
    fn odb(&self) -> Result<Odb> {
        let repo = self.head()?;
        let backend = repo.store().backend_impl::<GitBackend>().ok_or_else(|| anyhow!("not a git backend"))?;
        Ok(Odb(backend.git_repo()))
    }

    fn share_state(&self, share: &str) -> ShareState { self.state.shares.get(share).cloned().unwrap_or_default() }

    fn lfs_key(kind: ShareKind, path: &str, rel: &str) -> String {
        match kind {
            ShareKind::Folder => format!("{path}/{rel}"),
            ShareKind::File => path.to_owned(),
        }
    }

    fn local(&mut self, odb: &Odb, share: &str, path: &str, hint: Option<ShareKind>) -> Result<Local> {
        let repo = self.head()?;
        let tree = self.wc_commit(&repo)?.tree();
        let rpath = repo_path(path)?;
        if tree.conflicts_matching(&PrefixMatcher::new([&rpath])).next().is_some() {
            bail!("{path} has unresolved conflicts");
        }
        let value = tree.path_value(&rpath).block_on()?;
        let disk = self.disk_path(&rpath)?;
        let value = value.into_resolved().map_err(|_| anyhow!("{path} has unresolved conflicts"))?;
        let kind = self.share_state(share).kind.unwrap_or_else(|| match &value {
            Some(TreeValue::File { .. }) => ShareKind::File,
            Some(_) => ShareKind::Folder,
            None if disk.is_file() => ShareKind::File,
            None if disk.is_dir() => ShareKind::Folder,
            None => hint.unwrap_or(ShareKind::Folder),
        });
        let text_tree = match (kind, &value) {
            (_, None) => odb.empty_tree()?,
            (ShareKind::Folder, Some(TreeValue::Tree(id))) => to_oid(id.as_bytes()),
            (ShareKind::File, Some(TreeValue::File { id, executable, .. })) => {
                let entry = TreeEntry {
                    mode: if *executable { "100755" } else { "100644" }.into(),
                    name: FILE_ENTRY.as_bytes().to_vec(),
                    oid: to_oid(id.as_bytes()),
                };
                odb.write(Kind::Tree, &encode_tree(vec![entry]))?
            }
            _ => bail!("{path} is not a {}", if kind == ShareKind::File { "file" } else { "folder" }),
        };
        let lfs = self.local_lfs(kind, path)?;
        Ok(Local { kind, tree: text_tree, lfs })
    }

    /// The share's LFS files on disk by path inside the share.
    fn local_lfs(&mut self, kind: ShareKind, path: &str) -> Result<BTreeMap<String, (LfsFile, String, String)>> {
        let keys: Vec<(String, String)> = self
            .state
            .lfs
            .keys()
            .filter_map(|key| match kind {
                ShareKind::Folder => key.strip_prefix(&format!("{path}/")).map(|rel| (key.clone(), rel.to_owned())),
                ShareKind::File => (key == path).then(|| (key.clone(), FILE_ENTRY.to_owned())),
            })
            .collect();
        let mut lfs = BTreeMap::new();
        for (key, rel) in keys {
            if let Some((stat, hash)) = self.lfs_hash(&key)? {
                let mode = disk_mode(&self.disk_path(&repo_path(&key)?)?);
                lfs.insert(rel, (stat, hash, mode));
            }
        }
        Ok(lfs)
    }

    fn write_node(&self, odb: &Odb, tree: ObjectId, mut parents: Vec<ObjectId>, lfs: &BTreeMap<String, LfsEntry>) -> Result<ObjectId> {
        parents.sort();
        parents.dedup();
        let mut files = BTreeMap::new();
        odb.files(tree, "", &mut files)?;
        let body = node_body(&tree, &parents, &digest(&files, lfs), lfs);
        odb.write(Kind::Commit, &body)
    }

    fn record_node(&mut self, odb: &Odb, share: &str, node: ObjectId) -> Result<()> {
        odb.set_ref(&format!("refs/typewright/shares/{}/nodes/{node}", ref_component(share)), node)
    }

    fn set_head(&mut self, odb: &Odb, share: &str, kind: ShareKind, head: ObjectId) -> Result<()> {
        let state = self.state.shares.entry(share.to_owned()).or_default();
        state.kind = Some(kind);
        state.head = Some(head.to_string());
        state.pending.clear();
        odb.set_ref(&format!("refs/typewright/shares/{}/head", ref_component(share)), head)?;
        self.record_node(odb, share, head)?;
        self.save_state()
    }

    /// Exports the local content as a node on top of the head (or the pending merge); returns (node, unchanged).
    fn export(&mut self, odb: &Odb, share: &str, path: &str) -> Result<(ObjectId, bool)> {
        let local = self.local(odb, share, path, None)?;
        let state = self.share_state(share);
        let head = state.head.as_deref().map(oid).transpose()?;
        let parents: Vec<ObjectId> = if state.pending.is_empty() {
            head.into_iter().collect()
        } else {
            state.pending.iter().map(|p| oid(p)).collect::<Result<_>>()?
        };
        let parent_nodes: Vec<Node> = parents.iter().filter_map(|p| odb.node(*p).ok()).collect();
        let lfs: BTreeMap<String, LfsEntry> = local
            .lfs
            .iter()
            .map(|(rel, (stat, hash, mode))| {
                // Unchanged content keeps its time, so re-exports of synced files reproduce the same node.
                let time = parent_nodes
                    .iter()
                    .filter_map(|n| n.lfs.get(rel))
                    .filter(|e| &e.blake3 == hash)
                    .map(|e| e.time)
                    .min()
                    .unwrap_or_else(|| stat.mtime_seconds());
                (rel.clone(), LfsEntry { mode: mode.clone(), size: stat.size, blake3: hash.clone(), time })
            })
            .collect();
        if state.pending.is_empty()
            && let Some(head) = parent_nodes.first()
            && head.tree == local.tree
            && head.lfs == lfs
        {
            return Ok((head.id, true));
        }
        let node = self.write_node(odb, local.tree, parents, &lfs)?;
        self.set_head(odb, share, local.kind, node)?;
        Ok((node, false))
    }

    fn manifest(&self, odb: &Odb, node: &Node) -> Result<Value> {
        let mut files = serde_json::Map::new();
        let mut text = BTreeMap::new();
        odb.files(node.tree, "", &mut text)?;
        for (path, (mode, id)) in &text {
            let size = odb.0.find_header(*id).map(|h| h.size()).unwrap_or(0);
            files.insert(path.clone(), json!({"mode": mode, "size": size, "oid": id.to_string(), "lfs": false}));
        }
        for (path, e) in &node.lfs {
            files.insert(path.clone(), json!({"mode": e.mode, "size": e.size, "lfs": true, "blake3": e.blake3, "time": e.time}));
        }
        // Objects the parents don't have: what a peer holding the parents needs.
        let mut known = HashSet::new();
        for parent in &node.parents {
            if let Ok(p) = odb.node(*parent) {
                let mut seen = HashSet::new();
                let mut out = Vec::new();
                odb.closure(p.tree, &HashSet::new(), &mut out, &mut seen)?;
                known.extend(out);
            }
        }
        let mut objects = vec![node.id];
        odb.closure(node.tree, &known, &mut objects, &mut HashSet::new())?;
        let ancestry: Vec<String> = odb.ancestors(&node.parents, ANCESTRY_LIMIT).iter().map(|a| a.to_string()).collect();
        Ok(json!({
            "node": node.id.to_string(),
            "tree": node.tree.to_string(),
            "parents": node.parents.iter().map(|p| p.to_string()).collect::<Vec<_>>(),
            "files": files,
            "objects": objects.iter().map(|o| o.to_string()).collect::<Vec<_>>(),
            "ancestry": ancestry,
        }))
    }

    pub fn export_node(&mut self, share: &str, path: &str) -> Result<Value> {
        self.commit("Edit")?;
        let odb = self.odb()?;
        let (node, unchanged) = self.export(&odb, share, path)?;
        let mut manifest = self.manifest(&odb, &odb.node(node)?)?;
        if unchanged {
            manifest["unchanged"] = json!(true);
        }
        Ok(manifest)
    }

    pub fn node(&self, _share: &str, node: &str) -> Result<Value> {
        let odb = self.odb()?;
        self.manifest(&odb, &odb.node(oid(node)?)?)
    }

    pub fn missing_objects(&self, manifest: &str) -> Result<Value> {
        let manifest: Value = serde_json::from_str(manifest)?;
        let odb = self.odb()?;
        let mut wanted: Vec<String> = Vec::new();
        for key in ["node", "tree"] {
            if let Some(id) = manifest[key].as_str() {
                wanted.push(id.to_owned());
            }
        }
        wanted.extend(manifest_ids(&manifest, "parents"));
        wanted.extend(manifest_ids(&manifest, "objects"));
        if let Some(files) = manifest["files"].as_object() {
            for file in files.values() {
                if file["lfs"].as_bool() != Some(true)
                    && let Some(id) = file["oid"].as_str()
                {
                    wanted.push(id.to_owned());
                }
            }
        }
        let mut seen = HashSet::new();
        let mut missing = Vec::new();
        for hex in wanted {
            let id = oid(&hex)?;
            if seen.insert(id) && !odb.has(&id) {
                missing.push(hex);
            }
        }
        Ok(json!(missing))
    }

    /// Writes loose-object bytes (`<kind> <len>\0<data>`) per oid; a commit brings its whole tree along.
    pub fn write_objects(&self, oids: &str, dir: &str) -> Result<Value> {
        let oids: Vec<String> = serde_json::from_str(oids)?;
        let odb = self.odb()?;
        let dir = PathBuf::from(dir);
        fs::create_dir_all(&dir)?;
        let mut queue: Vec<ObjectId> = oids.iter().map(|o| oid(o)).collect::<Result<_>>()?;
        let mut seen = HashSet::new();
        let mut written = 0;
        while let Some(id) = queue.pop() {
            if !seen.insert(id) {
                continue;
            }
            let (kind, data) = odb.read(id)?;
            if kind == Kind::Commit
                && let Ok(node) = parse_node(id, &data)
            {
                let mut out = Vec::new();
                odb.closure(node.tree, &HashSet::new(), &mut out, &mut HashSet::new())?;
                queue.extend(out);
            }
            let mut bytes = format!("{} {}\0", kind, data.len()).into_bytes();
            bytes.extend_from_slice(&data);
            fs::write(dir.join(id.to_string()), bytes)?;
            written += 1;
        }
        Ok(json!({"written": written}))
    }

    pub fn import_node(&mut self, share: &str, manifest: &str, dir: &str, label: &str) -> Result<Value> {
        let manifest: Value = serde_json::from_str(manifest)?;
        let node_hex = manifest["node"].as_str().ok_or_else(|| anyhow!("manifest has no node"))?;
        let node_id = oid(node_hex)?;
        let odb = self.odb()?;
        if let Ok(entries) = fs::read_dir(dir) {
            for entry in entries {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                let Ok(expected) = oid(&name) else { continue };
                if odb.has(&expected) {
                    continue;
                }
                let bytes = fs::read(entry.path())?;
                let nul = bytes.iter().position(|b| *b == 0).ok_or_else(|| anyhow!("object {name} has no header"))?;
                let header = std::str::from_utf8(&bytes[..nul])?;
                let (kind, len) = header.split_once(' ').ok_or_else(|| anyhow!("object {name} has a bad header"))?;
                let kind = Kind::from_bytes(kind.as_bytes()).map_err(|_| anyhow!("object {name} has a bad kind"))?;
                let data = &bytes[nul + 1..];
                if len.parse::<usize>()? != data.len() {
                    bail!("object {name} is truncated");
                }
                let id = gix::objs::compute_hash(gix::hash::Kind::Sha1, kind, data).map_err(|e| anyhow!("{e}"))?;
                if id != expected {
                    bail!("object {name} doesn't match its id");
                }
                odb.write(kind, data)?;
            }
        }
        let node = odb.node(node_id).with_context(|| format!("node {node_hex} is missing"))?;
        if let Some(tree) = manifest["tree"].as_str()
            && oid(tree)? != node.tree
        {
            bail!("node {node_hex} doesn't have the manifest's tree");
        }
        let parents = manifest_ids(&manifest, "parents");
        if manifest.get("parents").is_some() && parents != node.parents.iter().map(|p| p.to_string()).collect::<Vec<_>>() {
            bail!("node {node_hex} doesn't have the manifest's parents");
        }
        let mut missing = Vec::new();
        odb.missing_in_tree(node.tree, &mut missing)?;
        if !missing.is_empty() {
            bail!("node {node_hex} lacks {} objects, like {}", missing.len(), missing[0]);
        }
        self.record_node(&odb, share, node_id)?;
        self.state.shares.entry(share.to_owned()).or_default().labels.insert(node_hex.to_owned(), label.to_owned());
        self.save_state()?;
        Ok(json!({"node": node_hex}))
    }

    /// The tree value a node puts at the share's path.
    fn node_value(&self, odb: &Odb, kind: ShareKind, tree: ObjectId) -> Result<Option<TreeValue>> {
        let entries = odb.tree(tree)?;
        Ok(match kind {
            _ if entries.is_empty() => None,
            ShareKind::Folder => Some(TreeValue::Tree(tree_id(&tree))),
            ShareKind::File => entries.iter().find(|e| e.name == FILE_ENTRY.as_bytes()).and_then(file_value),
        })
    }

    /// `keep`: repo paths whose working-copy content stays (files edited live with the peer, whose edits arrive
    /// through the CRDT instead); conflicts there resolve to the local side.
    pub fn merge_node(&mut self, share: &str, path: &str, node: &str, lfs_dir: &str, keep: &[String]) -> Result<Value> {
        self.commit("Edit")?;
        let odb = self.odb()?;
        let remote = odb.node(oid(node)?).with_context(|| format!("node {node} isn't imported"))?;
        let state = self.share_state(share);
        let mut remote_files = BTreeMap::new();
        odb.files(remote.tree, "", &mut remote_files)?;
        // Live content survives edits, but must not resurrect a peer's deletions.
        let live: Vec<RepoPathBuf> = keep.iter().map(|k| repo_path(k)).collect::<Result<_>>()?;
        let keep: Vec<RepoPathBuf> = keep.iter().filter(|key| {
            let rel = match state.kind.unwrap_or(ShareKind::Folder) {
                ShareKind::Folder => key.strip_prefix(&format!("{path}/")),
                ShareKind::File => (key.as_str() == path).then_some(FILE_ENTRY),
            };
            rel.is_some_and(|rel| remote_files.contains_key(rel) || remote.lfs.contains_key(rel))
        }).map(|k| repo_path(k)).collect::<Result<_>>()?;
        if !state.pending.is_empty() {
            // A peer resolved the conflict this share is waiting on: take its resolution.
            let ancestors: HashSet<ObjectId> = odb.ancestors(&[remote.id], usize::MAX).into_iter().collect();
            let pending: Vec<ObjectId> = state.pending.iter().map(|p| oid(p)).collect::<Result<_>>()?;
            if !pending.iter().all(|p| ancestors.contains(p)) {
                bail!("{path} has unresolved conflicts");
            }
            let kind = state.kind.unwrap_or(ShareKind::Folder);
            let old_lfs: BTreeMap<String, LfsEntry> = self
                .local_lfs(kind, path)?
                .into_iter()
                .map(|(rel, (stat, blake3, mode))| (rel, LfsEntry { mode, size: stat.size, blake3, time: 0 }))
                .collect();
            let repo = self.head()?;
            let wc_tree = self.wc_commit(&repo)?.tree();
            let value = self.node_value(&odb, kind, remote.tree)?;
            let lfs_dir = PathBuf::from(lfs_dir);
            let (tree, changed) =
                self.apply(path, kind, &wc_tree, Merge::resolved(value), None, &old_lfs, &remote.lfs, &lfs_dir, &keep)?;
            self.commit_tree(tree, &format!("Sync {share}"))?;
            self.set_head(&odb, share, kind, remote.id)?;
            return Ok(json!({"node": remote.id.to_string(), "changed": changed, "conflicts": []}));
        }
        let remote_entries = odb.tree(remote.tree)?;
        let hint = (remote_entries.len() == 1 && remote_entries[0].name == FILE_ENTRY.as_bytes()
            || remote.lfs.len() == 1 && remote.lfs.contains_key(FILE_ENTRY))
            .then_some(ShareKind::File);
        let local = self.local(&odb, share, path, hint)?;
        let kind = local.kind;
        let state = self.share_state(share);
        let empty = odb.empty_tree()?;
        let local_node = if state.head.is_none() && local.tree == empty && local.lfs.is_empty() {
            None
        } else {
            Some(odb.node(self.export(&odb, share, path)?.0)?)
        };
        let lfs_dir = PathBuf::from(lfs_dir);
        let rpath = repo_path(path)?;
        let repo = self.head()?;
        let store = repo.store().clone();
        let wc_tree = self.wc_commit(&repo)?.tree();

        let fast_forward = match &local_node {
            None => true,
            Some(a) if a.id == remote.id || odb.ancestors(&[a.id], usize::MAX).contains(&remote.id) => {
                return Ok(json!({"node": a.id.to_string(), "changed": [], "conflicts": []}));
            }
            Some(a) => odb.ancestors(&[remote.id], usize::MAX).contains(&a.id),
        };
        let old_lfs = local_node.as_ref().map(|a| a.lfs.clone()).unwrap_or_default();
        if fast_forward {
            let value = self.node_value(&odb, kind, remote.tree)?;
            let (tree, changed) =
                self.apply(path, kind, &wc_tree, Merge::resolved(value), None, &old_lfs, &remote.lfs, &lfs_dir, &keep)?;
            self.commit_tree(tree, &format!("Sync {share}"))?;
            self.set_head(&odb, share, kind, remote.id)?;
            return Ok(json!({"node": remote.id.to_string(), "changed": changed, "conflicts": []}));
        }

        let a = local_node.unwrap();
        let a_ancestors: HashSet<ObjectId> = odb.ancestors(&[a.id], usize::MAX).into_iter().collect();
        let base = odb.ancestors(&[remote.id], usize::MAX).into_iter().find(|id| a_ancestors.contains(id));
        let base = base.map(|b| odb.node(b)).transpose()?;
        let base_tree = base.as_ref().map_or(empty, |b| b.tree);
        let remote_label = state.labels.get(node).cloned().unwrap_or_else(|| "Remote".into());
        let resolved = |id: ObjectId| MergedTree::resolved(store.clone(), tree_id(&id));
        let merged = MergedTree::merge(Merge::from_vec(vec![
            (resolved(a.tree), local_label().to_owned()),
            (resolved(base_tree), "Base".to_owned()),
            (resolved(remote.tree), remote_label.clone()),
        ]))
        .block_on()?;
        let merged = self.keep_local(merged, kind, path, &a, &live, &keep)?;
        let value: MergedTreeValue = match kind {
            ShareKind::Folder => merged.tree_ids().map(|id| (id != store.empty_tree_id()).then(|| TreeValue::Tree(id.clone()))),
            ShareKind::File => merged.path_value(RepoPath::from_internal_string(FILE_ENTRY).unwrap()).block_on()?,
        };
        let mut text_paths = BTreeSet::new();
        for (p, _) in merged.entries() {
            text_paths.insert(p.as_internal_file_string().to_owned());
        }
        let empty_lfs = BTreeMap::new();
        let new_lfs = merge_lfs(base.as_ref().map_or(&empty_lfs, |b| &b.lfs), &a.lfs, &remote.lfs, &text_paths);
        let labels = merged.labels().clone();
        let (tree, changed) = self.apply(path, kind, &wc_tree, value, Some(labels), &old_lfs, &new_lfs, &lfs_dir, &keep)?;
        let conflicts: Vec<String> = tree
            .conflicts_matching(&PrefixMatcher::new([&rpath]))
            .map(|(p, _)| p.as_internal_file_string().to_owned())
            .collect();
        self.commit_tree(tree, &format!("Sync {share}"))?;
        if conflicts.is_empty() {
            let merged_tree = merged.tree_ids().as_resolved().map(|id| to_oid(id.as_bytes())).ok_or_else(|| anyhow!("unresolved merge"))?;
            let m = self.write_node(&odb, merged_tree, vec![a.id, remote.id], &new_lfs)?;
            self.set_head(&odb, share, kind, m)?;
            Ok(json!({"node": m.to_string(), "changed": changed, "conflicts": []}))
        } else {
            let state = self.state.shares.entry(share.to_owned()).or_default();
            let mut pending = vec![a.id.to_string(), remote.id.to_string()];
            pending.sort();
            state.pending = pending;
            self.save_state()?;
            Ok(json!({"node": null, "changed": changed, "conflicts": conflicts}))
        }
    }

    /// Resolves conflicts at kept paths to the local side `a`, so live-edited files never block a merge.
    fn keep_local(&self, merged: MergedTree, kind: ShareKind, path: &str, a: &Node, live: &[RepoPathBuf], keep: &[RepoPathBuf]) -> Result<MergedTree> {
        let store = merged.store().clone();
        let local = MergedTree::resolved(store, tree_id(&a.tree));
        let mut builder = MergedTreeBuilder::new(merged.clone());
        let mut touched = false;
        for k in live {
            let key = k.as_internal_file_string();
            let rel = match kind {
                ShareKind::Folder => key.strip_prefix(&format!("{path}/")).map(str::to_owned),
                ShareKind::File => (key == path).then(|| FILE_ENTRY.to_owned()),
            };
            let Some(rel) = rel else { continue };
            let rel = repo_path(&rel)?;
            if !merged.path_value(&rel).block_on()?.is_resolved() {
                let value = if keep.contains(k) { local.path_value(&rel).block_on()? } else { Merge::resolved(None) };
                builder.set_or_remove(rel.clone(), value);
                touched = true;
            }
        }
        if !touched {
            return Ok(merged);
        }
        let labels = merged.labels().clone();
        let tree = builder.write_tree().block_on()?;
        Ok(if tree.tree_ids().is_resolved() { tree } else { MergedTree::new(merged.store().clone(), tree.tree_ids().clone(), labels) })
    }

    /// Puts `value` at the share's path and the LFS files on disk (atomic writes); returns the new working-copy tree.
    #[allow(clippy::too_many_arguments)]
    fn apply(
        &mut self,
        path: &str,
        kind: ShareKind,
        wc_tree: &MergedTree,
        value: MergedTreeValue,
        labels: Option<ConflictLabels>,
        old_lfs: &BTreeMap<String, LfsEntry>,
        new_lfs: &BTreeMap<String, LfsEntry>,
        lfs_dir: &Path,
        keep: &[RepoPathBuf],
    ) -> Result<(MergedTree, Vec<String>)> {
        let store = wc_tree.store().clone();
        let rpath = repo_path(path)?;
        let mut builder = MergedTreeBuilder::new(wc_tree.clone());
        builder.set_or_remove(rpath.clone(), value);
        let mut tree = builder.write_tree().block_on()?;
        let kept: Vec<&RepoPathBuf> = keep.iter().filter(|k| k.starts_with(&rpath)).collect();
        if !kept.is_empty() {
            let mut builder = MergedTreeBuilder::new(tree.clone());
            for k in kept {
                builder.set_or_remove(k.clone(), wc_tree.path_value(k).block_on()?);
            }
            tree = builder.write_tree().block_on()?;
        }
        if let Some(labels) = labels
            && !tree.tree_ids().is_resolved()
            && !wc_tree.labels().has_labels()
            && labels.num_sides() == Some(tree.tree_ids().num_sides())
        {
            tree = MergedTree::new(store.clone(), tree.tree_ids().clone(), labels);
        }
        let stop = match kind {
            ShareKind::Folder => self.disk_path(&rpath)?,
            ShareKind::File => self.root().to_owned(),
        };
        let mut staged = Vec::new();
        let mut removals = Vec::new();
        let mut links = Vec::new();
        let mut changed = Vec::new();
        for (p, after) in diff_files(wc_tree, &tree, &PrefixMatcher::new([&rpath]))? {
            let disk = self.disk_path(&p)?;
            match after.as_resolved() {
                Some(None) => removals.push(disk),
                Some(Some(TreeValue::File { id, executable, .. })) => {
                    let bytes = crate::history::read_file(&store, &p, id)?;
                    staged.push(crate::fsutil::stage_bytes(&disk, &bytes, *executable)?);
                }
                Some(Some(TreeValue::Symlink(id))) => links.push((disk, store.read_symlink(&p, id).block_on()?)),
                Some(Some(_)) => continue,
                None => {
                    let bytes = crate::conflicts::materialize(&store, &p, &after, tree.labels())?;
                    staged.push(crate::fsutil::stage_bytes(&disk, &bytes, false)?);
                }
            }
            changed.push(p.as_internal_file_string().to_owned());
        }
        let mut lfs_written = Vec::new();
        let mut lfs_removed = Vec::new();
        let rels: BTreeSet<&String> = old_lfs.keys().chain(new_lfs.keys()).collect();
        for rel in rels {
            let key = Self::lfs_key(kind, path, rel);
            if keep.iter().any(|k| k.as_internal_file_string() == key) {
                continue;
            }
            let disk = self.disk_path(&repo_path(&key)?)?;
            match (old_lfs.get(rel), new_lfs.get(rel)) {
                (old, Some(new)) if old.map(|o| &o.blake3) != Some(&new.blake3) => {
                    let mut source = lfs_dir.join(&new.blake3);
                    if !source.is_file() {
                        // A conflict copy of a local file comes from the local file.
                        let local = old_lfs.iter().find(|(_, e)| e.blake3 == new.blake3).map(|(r, _)| Self::lfs_key(kind, path, r));
                        source = match local {
                            Some(k) => self.disk_path(&repo_path(&k)?)?,
                            None => bail!("LFS file {} is missing from {}", new.blake3, lfs_dir.display()),
                        };
                    }
                    staged.push(crate::fsutil::stage_copy(&disk, &source, new.mode == "100755")?);
                    lfs_written.push((key.clone(), new.blake3.clone(), disk));
                    changed.push(key);
                }
                (Some(_), None) => {
                    // No trash: LFS files have no history, so they wait in the stash for Recently Deleted.
                    self.stash_merged_away(&key, &disk, lfs_removed.len())?;
                    removals.push(disk);
                    lfs_removed.push(key.clone());
                    changed.push(key);
                }
                _ => {}
            }
        }
        for disk in removals {
            crate::fsutil::remove_and_prune(&disk, &stop)?;
        }
        for file in staged {
            file.commit()?;
        }
        for (disk, target) in links {
            crate::fsutil::write_symlink(&disk, &target)?;
        }
        for key in lfs_removed {
            self.state.lfs.remove(&key);
        }
        for (key, hash, disk) in lfs_written {
            let stat = LfsFile::stat(&disk).unwrap_or_default();
            self.state.lfs.insert(key, LfsFile { blake3: Some(hash), ..stat });
        }
        self.save_state()?;
        changed.sort();
        changed.dedup();
        Ok((tree, changed))
    }
}

#[cfg(test)]
pub(crate) fn test_conflict_name(path: &str) -> String { conflict_name(path, &BTreeSet::new()) }
