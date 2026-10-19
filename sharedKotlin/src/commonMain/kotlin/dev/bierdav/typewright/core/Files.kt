@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** How a space file is opened; `id` matches the Swift enum's raw values. */
enum class FileKind(val id: String) {
    Folder("folder"), Typst("typst"), Text("text"), Pdf("pdf"), Font("font"),

    /** Office files Quick Look can show: Word, Excel, PowerPoint, Pages, Numbers, Keynote. */
    Document("document"), Image("image"), Binary("binary");

    val isEditable: Boolean get() = this == Typst || this == Text
    val isOpenable: Boolean get() = this != Folder && this != Binary
}

object FileKinds {
    private val text = setOf(
        "bib", "yml", "yaml", "toml", "txt", "csv", "tsv", "json", "xml", "md", "svg", "html", "css", "js",
        "tex", "sty", "cls", "csl", "lua", "py", "sh", "swift", "rs", "c", "h", "ini", "cfg", "log", "gitignore",
    )
    private val font = setOf("ttf", "otf", "ttc", "otc", "woff", "woff2")
    private val document = setOf(
        "doc", "docx", "docm", "dot", "dotx", "xls", "xlsx", "xlsm", "xlt", "xltx", "ppt", "pptx", "pptm", "pot", "potx",
        "pps", "ppsx", "pages", "numbers", "key", "odt", "ods", "odp", "rtf",
    )
    private val image = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico")
    private val binary = setOf("zip", "gz", "tar", "dmg", "mp3", "mp4", "mov", "wav")

    /** null for unknown extensions; the caller sniffs the contents then. */
    fun forExtension(ext: String): FileKind? = when (val e = ext.lowercase()) {
        "typ" -> FileKind.Typst
        "pdf" -> FileKind.Pdf
        in font -> FileKind.Font
        in document -> FileKind.Document
        in text -> FileKind.Text
        in image -> FileKind.Image
        in binary -> FileKind.Binary
        else -> null
    }
}

object Paths {
    /** `path` relative to the space `root`, or null outside it. */
    fun relative(path: String, root: String): String? {
        val prefix = root.trimEnd('/') + "/"
        return if (path.startsWith(prefix)) path.removePrefix(prefix) else null
    }

    fun isInside(path: String, root: String): Boolean = relative(path, root) != null

    /**
     * The first free name for a new item: `name`, then `name 2` for folders or `name-2` for files.
     * Returns the file name including `ext`.
     */
    fun uniqueName(name: String, ext: String?, exists: (String) -> Boolean): String {
        fun make(n: String) = if (ext == null) n else "$n.$ext"
        var candidate = make(name)
        var i = 2
        while (exists(candidate)) {
            candidate = make(if (ext == null) "$name $i" else "$name-$i")
            i++
        }
        return candidate
    }

    /** The branch from a `.git/HEAD` file, or the short commit when detached. */
    fun gitBranch(head: String): String {
        val ref = head.trim()
        return if (ref.startsWith("ref: refs/heads/")) ref.removePrefix("ref: refs/heads/") else ref.take(7)
    }
}
