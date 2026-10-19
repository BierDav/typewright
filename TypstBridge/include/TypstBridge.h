#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// An in-memory typst world for one project root; not thread safe, use from one thread at a time.
typedef struct TWWorld TWWorld;

typedef enum : uint8_t {
    TWFormatPDF = 0,
    TWFormatHTML = 1,
    /// Pages as SVG documents separated by NUL bytes.
    TWFormatSVG = 2,
} TWFormat;

typedef struct {
    /// Exported document, NULL if compilation failed.
    uint8_t *_Nullable data;
    size_t len;
    /// JSON array of `{path, line, column, severity, message}`; detached diagnostics have an empty path.
    char *_Nonnull diagnostics;
} TWResult;

/// Typst version linked into the app.
const char *_Nonnull tw_version(void);

/// Scans fonts and builds the standard library ahead of the first compile.
void tw_warm_up(void);

TWWorld *_Nonnull tw_world_new(const char *_Nonnull root);
void tw_world_free(TWWorld *_Nonnull world);

/// Rescans the folders searched for fonts before the system's; returns whether the world's fonts changed.
bool tw_world_set_font_paths(TWWorld *_Nonnull world, const char *_Nonnull const *_Nullable paths, size_t count);

/// Sets the main file, relative to the root.
void tw_world_set_main(TWWorld *_Nonnull world, const char *_Nonnull path);

/// Serves `text` for the file at `path` (relative to the root) instead of its disk contents.
void tw_world_set_overlay(TWWorld *_Nonnull world, const char *_Nonnull path, const uint8_t *_Nonnull text, size_t len);
void tw_world_remove_overlay(TWWorld *_Nonnull world, const char *_Nonnull path);

/// Forgets cached disk contents so the next compile picks up external changes.
void tw_world_reset(TWWorld *_Nonnull world);

TWResult tw_world_compile(TWWorld *_Nonnull world, TWFormat format);
void tw_result_free(TWResult result);
