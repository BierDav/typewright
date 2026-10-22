#pragma once

#include <stdint.h>

/// The one internal jj repository holding every space as a top-level folder; see `jjBridge/src/lib.rs`.
/// Paths are relative to the repository root with `/` separators (`Thesis/main.typ`); a space is its first component.
/// Every call returning `char *` returns JSON (free with `twj_string_free`); failures are `{"error": "…"}`, with
/// `"busy": true` when another jj process (the CLI) holds the working copy lock for over 2 s: retry later.
/// Calls block; the app calls them off the main thread. One repo handle may be used from one thread at a time.
/// The user may run the jj CLI on the repo at any time. Every mutating call first loads at head (merging concurrent
/// operations) and normalizes: recreates a forgotten workspace, resets sparse patterns to everything, and recovers a
/// stale working copy by snapshotting the disk and carrying its edits onto the current @ (the disk wins where both
/// changed), or with jj's recovery commit if the working copy's operation is gone. Files on disk are never lost.
/// Other workspaces whose @ a call rewrote are refreshed in place when their files still match; otherwise they're
/// left stale and the result gains `"staleWorkspaces": ["name", …]` (`jj workspace update-stale` fixes them).
/// `"wrote": true` when the call first repaired our stale working copy and so rewrote files on disk: reload editors.
/// Folders containing their own `.jj` or `.git` (nested workspaces or repos) are never tracked (jj skips them).
typedef struct TWJRepo TWJRepo;

/// Opens the repository at `root`, creating it (git backend, not colocated) if missing, and tracking the files there.
/// A `.jj` that can't be loaded is moved to `.jj.broken-<YYYYMMDD-HHMMSS>` and replaced by a fresh repository; files
/// are untouched. Writes the managed repo config where jj 0.46 reads it (`jj config path --repo`:
/// `$XDG_CONFIG_HOME/jj` or `~/.config/jj` + `/repos/<id>/config.toml`) unless the user edited it, and lists LFS files and
/// Finder litter in the backing repo's `info/exclude` so the CLI ignores them too. NULL if it can't.
TWJRepo *_Nullable twj_open(const char *_Nonnull root);
void twj_close(TWJRepo *_Nonnull repo);

/// Files above `bytes` are LFS files: never tracked by jj (no history, no diffs), synced whole by hash. Also written
/// to the repo config as `snapshot.max-new-file-size` for the CLI.
void twj_set_lfs_limit(TWJRepo *_Nonnull repo, uint64_t bytes);

/// Snapshots the working copy and, if anything changed, commits @ with `message` and starts a new empty change on it.
/// Commits on top of wherever the user moved @ (`jj new`/`jj edit`, merges); a description the user gave @ is kept,
/// otherwise the message gets the trailer `Typewright-Commit: auto` (hidden in `twj_file_history`).
/// `{"commit": "<id>" | null, "changed": ["Space/a.typ", …]}`; `changed` also lists LFS files that changed on disk
/// (with `commit` null if only those did). Finder and editor litter (`.DS_Store`, `._*`, swap files) is ignored.
/// Binary files (by extension or a NUL byte) and files above the LFS limit are LFS files, also when a tracked file grows
/// past it; they're listed in `.jj/typewright/state.json`, not in the user's folders.
char *_Nonnull twj_commit(TWJRepo *_Nonnull repo, const char *_Nonnull message);

/// Squashes commits older than `days` (author time) into one commit per calendar day (local time). `{"squashed": n}`.
/// Only Typewright's own linear autosaves along @'s first parents: never commits with the user's description,
/// bookmarks or tags, merges, conflicts, divergent changes or ancestors of tags and remote bookmarks. Trees and
/// timestamps don't change; descendants and bookmarks follow.
char *_Nonnull twj_squash(TWJRepo *_Nonnull repo, uint32_t days);

/// Versions of a file along the app workspace's @ (first parents, whichever workspace made them), newest first, at most `limit`:
/// `[{"commit", "time" (unix seconds), "description", "kind": "added"|"modified"|"deleted"|"renamed", "from"?: old path,
///    "added": lines, "removed": lines}]`. Follows the file across renames inside one commit.
char *_Nonnull twj_file_history(TWJRepo *_Nonnull repo, const char *_Nonnull path, uint32_t limit);
/// The file's content in `commit` (any commit, also hidden or abandoned ones): `{"text": "…"}` for UTF-8, `{"data": "<base64>"}` otherwise, `{"missing": true}` if absent
/// (LFS files are always missing). A conflicted file comes with conflict markers.
char *_Nonnull twj_file_at(TWJRepo *_Nonnull repo, const char *_Nonnull commit, const char *_Nonnull path);
/// Writes the file's content from `commit` into the working copy (atomically) and commits "Restore <path>". `{"commit"}`.
char *_Nonnull twj_restore_file(TWJRepo *_Nonnull repo, const char *_Nonnull commit, const char *_Nonnull path);

/// Conflicted files of the working-copy commit under `prefix` ("" for all): `["Space/a.typ", …]`.
char *_Nonnull twj_conflicts(TWJRepo *_Nonnull repo, const char *_Nonnull prefix);
/// A conflicted file split into hunks: `{"path", "binary": bool, "sides": ["This Mac", "Laptop"], "hunks": [
///   {"text": "…"} | {"conflict": {"base": "…", "sides": ["…", "…"]}}]}`; more than two sides are possible (`base` is then
///   the first base). Side 0 is this device ("This Mac"), the others are labelled by `twj_import_node`'s `label`.
char *_Nonnull twj_conflict(TWJRepo *_Nonnull repo, const char *_Nonnull path);
/// Resolves a conflict with `text` (or for binary files `side` index if `text` is NULL) and commits "Resolve <path>".
char *_Nonnull twj_resolve(TWJRepo *_Nonnull repo, const char *_Nonnull path, const char *_Nullable text, int32_t side);

// MARK: - Sync nodes
// A share is a folder or file path in a repo. Its states travel as nodes: deterministic git commits whose tree is the
// share's subtree (for a file share, a tree with that one file), pinned author/date, message = content digest, so two
// repos with the same content and parents compute the same node id (see ../jj-spares-folder-test). Nodes are kept
// under `refs/typewright/shares/<share>/…` and are independent of the local history, so squashing never touches them.

/// Exports the current content of `path` as a node on top of the share's last synced node(s); returns the manifest:
/// `{"node", "tree", "parents": [..], "files": {"rel/path": {"mode": "100644"|"100755", "size", "oid", "lfs": bool,
///   "blake3"?: hex for LFS files}}}`; `"unchanged": true` if equal to the last synced node.
/// Commits pending changes first; fails while `path` has conflicts. A file share's tree holds the file as `@file`, so
/// its name doesn't matter. LFS files aren't in the tree: they have no `oid` but `blake3` and `time` (when the content
/// was first exported, to pick the newest on conflicts) and are listed in the node's message. `"objects"` lists the
/// objects the parents don't have (node first), `"ancestry"` as in `twj_node`.
char *_Nonnull twj_export_node(TWJRepo *_Nonnull repo, const char *_Nonnull share, const char *_Nonnull path);
/// A stored node's manifest (same shape), including its ancestors' ids in `"ancestry"` (newest first, up to 64).
char *_Nonnull twj_node(TWJRepo *_Nonnull repo, const char *_Nonnull share, const char *_Nonnull node);
/// Git objects a manifest needs that the repo lacks: `["<oid>", …]` (LFS files never appear here). A missing parent
/// shows up as its commit id; `twj_write_objects` sends a commit together with its whole tree.
char *_Nonnull twj_missing_objects(TWJRepo *_Nonnull repo, const char *_Nonnull manifest);
/// Writes the raw objects (zlib-free canonical bytes: `blob <len>\0…`, trees, commits) named by `oids` (JSON array)
/// into `dir` as files named by oid, for transport; node commits bring their tree's objects along. `{"written": n}`.
char *_Nonnull twj_write_objects(TWJRepo *_Nonnull repo, const char *_Nonnull oids, const char *_Nonnull dir);
/// Imports a remote node: `manifest` plus objects as files named by oid in `dir`; verifies the ids. `{"node"}`.
char *_Nonnull twj_import_node(TWJRepo *_Nonnull repo, const char *_Nonnull share, const char *_Nonnull manifest,
                               const char *_Nonnull dir, const char *_Nonnull label);
/// Merges an imported node into the share's local content at `path` (3-way, base = the nodes' merge base), writes
/// changed files atomically (LFS files: the newest by `time` wins, the other is kept as `name (conflict).ext`;
/// their bytes must already be at the path given in `lfs_dir/<blake3>`), and commits "Sync <share>".
/// Fast-forwards when one node descends from the other; a merge node's parents are sorted, so devices merging the
/// same two nodes get the same id. `{"node": merged node id | null if conflicted, "changed": [..], "conflicts": [..]}`;
/// with conflicts the merged content stays a jj conflict in the working copy until `twj_resolve`, after which
/// `twj_export_node` publishes it with both parents. Fails while `path` already has unresolved conflicts.
char *_Nonnull twj_merge_node(TWJRepo *_Nonnull repo, const char *_Nonnull share, const char *_Nonnull path,
                              const char *_Nonnull node, const char *_Nonnull lfs_dir);

void twj_string_free(char *_Nullable string);
