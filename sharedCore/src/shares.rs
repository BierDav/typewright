//! Decisions of the share sync loop (see `irohBridge`'s `shares`): which share a path belongs to, whether a remote
//! head needs merging, and what a share's status is.

/// A share synced on this device: its id, its path in the space repository and whether it's a single file.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct SharePath {
    pub id: String,
    pub path: String,
    pub file: bool,
}

/// Where a repository path lies in a share: the share's id and the path inside it, as live sessions name files.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct SharePlace {
    pub id: String,
    pub inside: String,
}

/// A file share's file inside its node, whatever it's called on each device.
pub const FILE_ENTRY: &str = "@file";

fn inside(share: &SharePath, path: &str) -> Option<String> {
    if share.file {
        return (path == share.path).then(|| FILE_ENTRY.to_string());
    }
    if share.path.is_empty() {
        return Some(path.to_string());
    }
    path.strip_prefix(&share.path)?.strip_prefix('/').map(str::to_string)
}

/// The innermost share holding `path`; a file share nested in a shared folder wins.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn share_place(shares: Vec<SharePath>, path: &str) -> Option<SharePlace> {
    shares
        .iter()
        .filter_map(|share| inside(share, path).map(|rel| (share, rel)))
        .max_by_key(|(share, _)| (share.path.len(), share.file))
        .map(|(share, rel)| SharePlace { id: share.id.clone(), inside: rel })
}

/// The repository path of `inside` (as `share_place` names it) in a share.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn share_file_path(share: SharePath, inside: &str) -> String {
    if share.file || share.path.is_empty() {
        return if share.file { share.path } else { inside.to_string() };
    }
    format!("{}/{inside}", share.path)
}

/// Shares whose content any of `changed` (repository paths, as commits report them) touches.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn shares_touched(shares: Vec<SharePath>, changed: Vec<String>) -> Vec<String> {
    let mut ids: Vec<String> = shares
        .iter()
        .filter(|share| changed.iter().any(|path| inside(share, path).is_some() || (!share.file && *path == share.path)))
        .map(|share| share.id.clone())
        .collect();
    ids.sort();
    ids.dedup();
    ids
}

/// A remote head needs merging unless this device already has it: it is the current node or one of its ancestors.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn needs_merge(head: Option<String>, ancestry: Vec<String>, remote: &str) -> bool {
    head.as_deref() != Some(remote) && !ancestry.iter().any(|a| a == remote)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Enum))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub enum ShareStatus {
    /// Every connected device has this device's node (or no other device syncs the share).
    Synced,
    /// Nodes are on their way, or connected devices are at different nodes.
    Syncing,
    /// A merge left conflicts here; resolving them publishes the merge.
    Conflicts,
    /// Other devices sync the share but none is connected.
    Offline,
}

/// Another device's head as this device last saw it.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
#[cfg_attr(not(target_arch = "wasm32"), derive(uniffi::Record))]
#[cfg_attr(target_arch = "wasm32", derive(serde::Serialize, serde::Deserialize, tsify::Tsify))]
pub struct PeerHead {
    pub device: String,
    pub node: String,
    pub connected: bool,
}

/// `working`: an export, publish or merge is pending or running; `others`: devices besides this one syncing it.
#[cfg_attr(not(target_arch = "wasm32"), uniffi::export)]
pub fn share_status(
    head: Option<String>,
    peers: Vec<PeerHead>,
    others: u32,
    conflicted: bool,
    working: bool,
) -> ShareStatus {
    if conflicted {
        return ShareStatus::Conflicts;
    }
    if working {
        return ShareStatus::Syncing;
    }
    let connected: Vec<&PeerHead> = peers.iter().filter(|p| p.connected).collect();
    if connected.is_empty() {
        return if others == 0 { ShareStatus::Synced } else { ShareStatus::Offline };
    }
    // A peer behind this device still has to merge, one ahead or diverged this device; either way it's in flight.
    if connected.iter().all(|p| head.as_deref() == Some(p.node.as_str())) { ShareStatus::Synced } else { ShareStatus::Syncing }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn share(id: &str, path: &str, file: bool) -> SharePath {
        SharePath { id: id.into(), path: path.into(), file }
    }

    #[test]
    fn finds_the_innermost_share() {
        let shares = vec![share("s", "Thesis", false), share("c", "Thesis/chapters", false), share("f", "Thesis/notes.typ", true)];
        let place = |p: &str| share_place(shares.clone(), p).map(|p| (p.id, p.inside));
        assert_eq!(place("Thesis/main.typ"), Some(("s".into(), "main.typ".into())));
        assert_eq!(place("Thesis/chapters/a.typ"), Some(("c".into(), "a.typ".into())));
        assert_eq!(place("Thesis/notes.typ"), Some(("f".into(), FILE_ENTRY.into())));
        assert_eq!(place("Thesis2/main.typ"), None);
        assert_eq!(place("Other/main.typ"), None);
        assert_eq!(share_file_path(shares[1].clone(), "a.typ"), "Thesis/chapters/a.typ");
        assert_eq!(share_file_path(shares[2].clone(), FILE_ENTRY), "Thesis/notes.typ");
    }

    #[test]
    fn routes_commits_to_shares() {
        let shares = vec![share("s", "Thesis", false), share("f", "Notes/a.typ", true), share("o", "Other", false)];
        let changed = vec!["Thesis/main.typ".to_string(), "Notes/a.typ".to_string(), "Notes/b.typ".to_string()];
        assert_eq!(shares_touched(shares.clone(), changed), vec!["f".to_string(), "s".to_string()]);
        // Removing a shared folder itself touches it too.
        assert_eq!(shares_touched(shares, vec!["Other".into()]), vec!["o".to_string()]);
    }

    #[test]
    fn merges_only_unknown_heads() {
        let ancestry = vec!["b".to_string(), "a".to_string()];
        assert!(!needs_merge(Some("c".into()), ancestry.clone(), "c"));
        assert!(!needs_merge(Some("c".into()), ancestry.clone(), "a"));
        assert!(needs_merge(Some("c".into()), ancestry, "d"));
        assert!(needs_merge(None, vec![], "a"));
    }

    #[test]
    fn statuses() {
        let peer = |node: &str, connected| PeerHead { device: "d".into(), node: node.into(), connected };
        let head = Some("n".to_string());
        assert_eq!(share_status(head.clone(), vec![peer("x", true)], 1, true, false), ShareStatus::Conflicts);
        assert_eq!(share_status(head.clone(), vec![peer("n", true)], 1, false, true), ShareStatus::Syncing);
        assert_eq!(share_status(head.clone(), vec![peer("n", true)], 1, false, false), ShareStatus::Synced);
        assert_eq!(share_status(head.clone(), vec![peer("m", true)], 1, false, false), ShareStatus::Syncing);
        // A peer behind still has to catch up.
        assert_eq!(share_status(head.clone(), vec![peer("m", true)], 1, false, false), ShareStatus::Syncing);
        assert_eq!(share_status(head.clone(), vec![peer("m", false)], 1, false, false), ShareStatus::Offline);
        assert_eq!(share_status(head.clone(), vec![], 2, false, false), ShareStatus::Offline);
        assert_eq!(share_status(head, vec![], 0, false, false), ShareStatus::Synced);
    }
}
