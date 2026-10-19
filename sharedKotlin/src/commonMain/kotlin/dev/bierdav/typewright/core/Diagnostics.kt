@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

enum class Severity { Error, Warning }

/** A compiler message at a one-based line and UTF-16 column. */
data class Diagnostic(
    val path: String,
    val line: Int,
    val column: Int,
    val severity: Severity,
    val message: String,
) {
    /** Package paths look like `@preview/name:1.0.0/lib.typ`. */
    val isFromPackage: Boolean get() = path.startsWith("@")
}

object Diagnostics {
    private val pattern = Regex("""^(.+?):(\d+):(\d+): (error|warning): (.*)$""")
    private val duration = Regex("""in ([\d.]+) ?(µs|ms|s)\b""")

    /** Parses typst's `--diagnostic-format short` output. */
    fun parse(output: String): List<Diagnostic> = output.lines().mapNotNull { line ->
        val m = pattern.find(line.trimEnd('\r')) ?: return@mapNotNull null
        val (path, row, column, severity, message) = m.destructured
        Diagnostic(
            path = path,
            line = row.toIntOrNull() ?: 1,
            column = column.toIntOrNull() ?: 1,
            severity = if (severity == "warning") Severity.Warning else Severity.Error,
            message = message,
        )
    }

    /** Seconds from `typst watch`'s `compiled successfully in 15.81 ms`. */
    fun compileDuration(status: String): Double? {
        val m = duration.find(status) ?: return null
        val value = m.groupValues[1].toDoubleOrNull() ?: return null
        return when (m.groupValues[2]) {
            "µs" -> value / 1_000_000
            "ms" -> value / 1000
            else -> value
        }
    }
}
