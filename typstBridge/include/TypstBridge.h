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

/// Syntax highlighting runs for `text` (markup, or code if `code`): `count` values, three per run of
/// UTF-16 start, UTF-16 length and tag (low byte) with style flags (bold 1, italic 2, math 4) from bit 8.
uint32_t *_Nonnull tw_highlight(const uint8_t *_Nullable text, size_t len, bool code, size_t *_Nonnull count);
void tw_highlight_free(uint32_t *_Nonnull runs, size_t count);

/// Downloads a package like `@preview/cetz:0.3.1` (or the newest `@preview/cetz`) into typst's package cache.
/// Returns "ok:<spec>" or "error:<message>"; free with `tw_string_free`. Blocks on the network.
char *_Nonnull tw_package_download(const char *_Nonnull spec);
void tw_string_free(char *_Nonnull string);

/// Refactors typst markup. The request is JSON `{op, text, start, length, all}` with UTF-16 offsets; `op` is
/// "candidates" (expressions to extract at the caret or selection), "extract" (into a variable; `all` replaces
/// every occurrence) or "inline" (the variable at `start`). The response is JSON `{error?, candidates, edits,
/// names, count}`, edits as `{start, length, text}` in the old text, names as `[start, length]` in the new one.
/// Free with `tw_string_free`.
char *_Nonnull tw_refactor(const char *_Nonnull request);

/// GitHub flavored Markdown as HTML, math as MathML and code with syntect classes; free with `tw_string_free`.
char *_Nonnull tw_markdown_html(const uint8_t *_Nullable text, size_t len);
/// CSS for the code classes in `tw_markdown_html`, light and dark; free with `tw_string_free`.
char *_Nonnull tw_markdown_code_css(void);
