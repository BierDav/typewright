#pragma once

#include <stdint.h>

/// Syncs shares (folders and files of the space repository, as jj nodes) between the devices of one account and the
/// accounts they invite; see `irohBridge/src/lib.rs` and `shares.rs`. Live editing keys sessions by share id and the
/// path inside the share (`@file` for a file share).
typedef struct TWSyncNode TWSyncNode;

/// Receives JSON events on arbitrary threads: `status`, `shares`, `head`, `published-node`, `fetched`,
/// `exported`, `live`, `error` (plus `spaces`, the web app's path-by-path listing).
typedef void (*TWSyncEventCallback)(void *_Nullable context, const char *_Nonnull event);

/// Starts syncing for the account; `account` is 32 bytes. NULL (after an `error` event) if it can't start.
TWSyncNode *_Nullable tws_start(const char *_Nonnull data_dir, const uint8_t *_Nonnull account,
                                TWSyncEventCallback _Nonnull callback, void *_Nullable context);
void tws_stop(TWSyncNode *_Nonnull node);
/// Free with `tws_string_free`.
char *_Nonnull tws_device_id(const TWSyncNode *_Nonnull node);

/// Lists the share (`kind` "space", "folder" or "file") for all devices of the account and starts syncing it here; `device`
/// names this device on the others (conflict sides).
void tws_add_share(const TWSyncNode *_Nonnull node, const char *_Nonnull share, const char *_Nonnull name,
                   const char *_Nonnull kind, const char *_Nonnull device);
/// The hex secret an invite link carries; marks the share shared for all devices of the account. Free with `tws_string_free`.
char *_Nonnull tws_share_invite(const TWSyncNode *_Nonnull node, const char *_Nonnull share, const char *_Nonnull name,
                                const char *_Nonnull kind);
/// Starts syncing a share from another account's invite; `hints` are comma separated endpoint ids to dial first.
void tws_join_share(const TWSyncNode *_Nonnull node, const char *_Nonnull share, const char *_Nonnull name,
                    const char *_Nonnull kind, const char *_Nonnull secret, const char *_Nonnull hints,
                    const char *_Nonnull device);
/// Starts syncing a share listed by the account; answers with `head` events for the other devices' heads.
void tws_open_share(const TWSyncNode *_Nonnull node, const char *_Nonnull share, const char *_Nonnull device);
/// Stops syncing a share on this device; the other devices keep it. A share nobody syncs leaves the account.
void tws_close_share(const TWSyncNode *_Nonnull node, const char *_Nonnull share);
/// Stops syncing a share on every device of the account; the files stay everywhere.
void tws_remove_share(const TWSyncNode *_Nonnull node, const char *_Nonnull share);
/// Re-sends the other devices' ready heads as `head` events (`share`, `device`, `node`, `name`, `parents`).
void tws_list_heads(const TWSyncNode *_Nonnull node, const char *_Nonnull share);
/// Publishes a node as this device's head: `manifest` from `twj_export_node`, `objects` the folder `twj_write_objects`
/// filled with the node (removed afterwards), `lfs` a JSON array of `{"blake3", "path"}` locating the manifest's LFS
/// files. Answers with `published-node`.
void tws_publish_node(const TWSyncNode *_Nonnull node, const char *_Nonnull share, const char *_Nonnull manifest,
                      const char *_Nonnull objects, const char *_Nonnull lfs);
/// Unpacks `device`'s head into `dir` (`manifest.json`, `objects/`, `lfs/<blake3>` except those in the JSON array
/// `skip`); answers with a `fetched` event carrying `request`, `ok` and the `node`.
void tws_fetch_node(const TWSyncNode *_Nonnull node, const char *_Nonnull share, const char *_Nonnull device,
                    const char *_Nonnull dir, const char *_Nonnull skip, int64_t request);

/// Starts live editing of a file shown in an editor; `name` labels this device's cursor elsewhere.
void tws_live_open(const TWSyncNode *_Nonnull node, const char *_Nonnull space, const char *_Nonnull path,
                   const char *_Nonnull text, const char *_Nonnull name);
void tws_live_close(const TWSyncNode *_Nonnull node, const char *_Nonnull space, const char *_Nonnull path);
/// Hands over the editor's text and selection (UTF-16) and returns JSON with remote `edits`, an `adopted`
/// session to merge into, the other `cursors` and `peers`. `step` 1 undoes, 2 redoes. Free with `tws_string_free`.
char *_Nonnull tws_live_sync(const TWSyncNode *_Nonnull node, const char *_Nonnull space, const char *_Nonnull path,
                             const char *_Nonnull text, uint32_t location, uint32_t length, int32_t step);

/// Writes a blob to `target`; answers with an `exported` event carrying `request`.
void tws_export(const TWSyncNode *_Nonnull node, const char *_Nonnull hash, const char *_Nonnull target, int64_t request);

/// BLAKE3 of a file as blob hashes are written; NULL if unreadable. Free with `tws_string_free`.
char *_Nullable tws_hash_file(const char *_Nonnull path);
void tws_string_free(char *_Nullable string);
