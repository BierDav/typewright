#pragma once

#include <stdint.h>

/// Syncs space folders between the devices of one account; see `irohBridge/src/lib.rs`.
typedef struct TWSyncNode TWSyncNode;

/// Receives JSON events on arbitrary threads: `status`, `spaces`, `entries`, `remote`, `published`, `exported`, `error`.
typedef void (*TWSyncEventCallback)(void *_Nullable context, const char *_Nonnull event);

/// Starts syncing for the account; `account` is 32 bytes. NULL (after an `error` event) if it can't start.
TWSyncNode *_Nullable tws_start(const char *_Nonnull data_dir, const uint8_t *_Nonnull account,
                                TWSyncEventCallback _Nonnull callback, void *_Nullable context);
void tws_stop(TWSyncNode *_Nonnull node);
/// Free with `tws_string_free`.
char *_Nonnull tws_device_id(const TWSyncNode *_Nonnull node);

/// Lists the space for all devices of the account and starts syncing it here.
void tws_share_space(const TWSyncNode *_Nonnull node, const char *_Nonnull space, const char *_Nonnull name);
/// Starts syncing a space listed by the account; answers with an `entries` event.
void tws_open_space(const TWSyncNode *_Nonnull node, const char *_Nonnull space);
/// Stops syncing a space on this device; the other devices keep it.
void tws_close_space(const TWSyncNode *_Nonnull node, const char *_Nonnull space);
/// Re-sends the space's entries as an `entries` event.
void tws_list_space(const TWSyncNode *_Nonnull node, const char *_Nonnull space);

/// Imports `file` as the space's `path`; answers with a `published` event.
void tws_publish(const TWSyncNode *_Nonnull node, const char *_Nonnull space, const char *_Nonnull path,
                 const char *_Nonnull file);
/// Marks the space's `path` deleted; answers with a `published` event.
void tws_unpublish(const TWSyncNode *_Nonnull node, const char *_Nonnull space, const char *_Nonnull path);
/// Writes a blob to `target`; answers with an `exported` event carrying `request`.
void tws_export(const TWSyncNode *_Nonnull node, const char *_Nonnull hash, const char *_Nonnull target, int64_t request);

/// BLAKE3 of a file as blob hashes are written; NULL if unreadable. Free with `tws_string_free`.
char *_Nullable tws_hash_file(const char *_Nonnull path);
void tws_string_free(char *_Nullable string);
