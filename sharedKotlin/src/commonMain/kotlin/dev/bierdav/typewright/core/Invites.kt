@file:JsExport
@file:OptIn(ExperimentalEncodingApi::class)

package dev.bierdav.typewright.core

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.js.JsExport

/**
 * Everything another account needs to sync a space: its replica's namespace secret (hex), the space's
 * id and name, and endpoint ids (hex) of devices syncing it, to dial before the space's record resolves.
 */
data class SpaceInvite(val id: String, val name: String, val secret: String, val hints: List<String>)

/** `typewright://join/<payload>` links; the payload is base64url of a small binary layout. */
object SpaceInvites {
    const val SCHEME = "typewright"
    private const val PREFIX = "$SCHEME://join/"
    private const val VERSION: Byte = 1
    /** Keeps links short enough for chat apps. */
    const val MAX_HINTS = 3
    private const val MAX_NAME_BYTES = 120
    private val base64 = Base64.UrlSafe.withPadding(Base64.PaddingOption.ABSENT_OPTIONAL)

    /** Layout: version, 32-byte secret, id and name (each length-prefixed UTF-8), then 32-byte hints. */
    fun link(invite: SpaceInvite): String? {
        val secret = hex(invite.secret)?.takeIf { it.size == 32 } ?: return null
        if (!isValidID(invite.id)) return null
        val id = invite.id.encodeToByteArray()
        val name = truncate(folderName(invite.name), MAX_NAME_BYTES).encodeToByteArray()
        val hints = invite.hints.mapNotNull { hint -> hex(hint)?.takeIf { it.size == 32 } }.take(MAX_HINTS)
        val bytes = byteArrayOf(VERSION) + secret + byteArrayOf(id.size.toByte()) + id +
            byteArrayOf(name.size.toByte()) + name + hints.fold(ByteArray(0)) { all, hint -> all + hint }
        return PREFIX + base64.encode(bytes)
    }

    /** Null for anything that isn't a well-formed invite link. */
    fun parse(link: String): SpaceInvite? {
        val payload = link.trim().takeIf { it.startsWith(PREFIX) }?.removePrefix(PREFIX)?.trimEnd('/') ?: return null
        val bytes = try { base64.decode(payload) } catch (_: IllegalArgumentException) { return null }
        if (bytes.size < 35 || bytes[0] != VERSION) return null
        var at = 33
        fun field(): String? {
            val length = bytes.getOrNull(at)?.toInt()?.and(0xFF) ?: return null
            if (at + 1 + length > bytes.size) return null
            val text = bytes.copyOfRange(at + 1, at + 1 + length).decodeToString()
            at += 1 + length
            return text
        }
        val id = field()?.takeIf(::isValidID) ?: return null
        val name = field()?.let(::folderName) ?: return null
        if ((bytes.size - at) % 32 != 0) return null
        val hints = (at until bytes.size step 32).map { hex(bytes.copyOfRange(it, it + 32)) }
        return SpaceInvite(id, name, hex(bytes.copyOfRange(1, 33)), hints)
    }

    /** Ids name keys in replicas, so they stay plain. */
    fun isValidID(id: String): Boolean =
        id.length in 1..64 && id.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' }

    /** The name works as a folder name: no separators, never empty or hidden. */
    fun folderName(name: String): String {
        val clean = name.map { if (it == '/' || it == ':' || it.code < 0x20) '-' else it }.joinToString("").trim().trimStart('.')
        return clean.ifEmpty { "Shared Space" }
    }

    private fun truncate(text: String, maxBytes: Int): String {
        var result = text
        // Drop whole characters, so no UTF-8 sequence is cut.
        while (result.encodeToByteArray().size > maxBytes) result = result.dropLast(if (result.last().isLowSurrogate()) 2 else 1)
        return result
    }

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }

    private fun hex(text: String): ByteArray? {
        if (text.length % 2 != 0 || !text.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
        return ByteArray(text.length / 2) { i -> text.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }
}
