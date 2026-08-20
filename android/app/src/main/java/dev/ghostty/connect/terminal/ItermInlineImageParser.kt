package dev.ghostty.connect.terminal

import java.io.ByteArrayOutputStream
import java.util.Base64

internal class ItermInlineImageParser(
    private val onBytes: (ByteArray) -> Unit,
    private val onImage: (ItermInlineImage) -> Unit,
) {
    private val plain = ByteArrayOutputStream()
    private val control = ByteArrayOutputStream()
    private var prefixIndex = 0
    private var capturing = false
    private var pendingEscape = false
    private var draining = false
    private var multipart: Multipart? = null

    fun feed(bytes: ByteArray) {
        bytes.forEach(::accept)
        flushPlain()
    }

    fun reset() {
        plain.reset()
        control.reset()
        prefixIndex = 0
        capturing = false
        pendingEscape = false
        draining = false
        multipart = null
    }

    private fun accept(value: Byte) {
        if (capturing) {
            when {
                pendingEscape && value == ST_END -> finishControl(byteArrayOf(ESC, ST_END))
                pendingEscape -> {
                    appendControl(ESC)
                    pendingEscape = false
                    when (value) {
                        BEL -> finishControl(byteArrayOf(BEL))
                        ESC -> pendingEscape = true
                        else -> appendControl(value)
                    }
                }
                value == BEL -> finishControl(byteArrayOf(BEL))
                value == ESC -> pendingEscape = true
                else -> appendControl(value)
            }
            return
        }

        if (value == PREFIX[prefixIndex]) {
            prefixIndex++
            if (prefixIndex == PREFIX.size) {
                flushPlain()
                prefixIndex = 0
                capturing = true
                control.reset()
            }
            return
        }

        if (prefixIndex > 0) {
            plain.write(PREFIX, 0, prefixIndex)
            prefixIndex = 0
            if (value == PREFIX[0]) {
                prefixIndex = 1
                return
            }
        }
        plain.write(value.toInt())
    }

    private fun appendControl(value: Byte) {
        if (draining) return
        if (control.size() >= MAX_CONTROL_BYTES) {
            draining = true
            control.reset()
            multipart = null
            return
        }
        control.write(value.toInt())
    }

    private fun finishControl(terminator: ByteArray) {
        if (!draining) {
            val content = control.toByteArray()
            if (!handleControl(content)) {
                plain.write(PREFIX)
                plain.write(content)
                plain.write(terminator)
            }
        }
        control.reset()
        capturing = false
        pendingEscape = false
        draining = false
    }

    private fun handleControl(content: ByteArray): Boolean {
        return when {
            content.startsWith(FILE) -> {
                val separator = (FILE.size until content.size).firstOrNull { content[it] == COLON } ?: -1
                if (separator < 0 || separator > MAX_HEADER_BYTES) return true
                val options = parseOptions(content.copyOfRange(FILE.size, separator)) ?: return true
                complete(options, content.copyOfRange(separator + 1, content.size))
                true
            }
            content.startsWith(MULTIPART_FILE) -> {
                multipart = parseOptions(content.copyOfRange(MULTIPART_FILE.size, content.size))
                    ?.let { Multipart(it) }
                true
            }
            content.startsWith(FILE_PART) -> {
                multipart?.append(content, FILE_PART.size)
                true
            }
            content.contentEquals(FILE_END) -> {
                multipart?.let { complete(it.options, it.encoded.toByteArray()) }
                multipart = null
                true
            }
            else -> false
        }
    }

    private fun complete(options: Map<String, String>, encoded: ByteArray) {
        if (options["inline"] != "1") return
        val declaredSize = options["size"]?.toLongOrNull()
        if (declaredSize != null && declaredSize !in 0..MAX_IMAGE_BYTES.toLong()) return
        val compact = encoded.filterNot { it == '\r'.code.toByte() || it == '\n'.code.toByte() }.toByteArray()
        if (compact.size > MAX_ENCODED_BYTES || compact.any { !it.isBase64Byte() }) return
        val decoded = runCatching { Base64.getDecoder().decode(compact) }.getOrNull() ?: return
        if (decoded.size > MAX_IMAGE_BYTES || declaredSize?.let { it != decoded.size.toLong() } == true) return
        onImage(ItermInlineImage(options, decoded))
    }

    private fun parseOptions(bytes: ByteArray): Map<String, String>? = runCatching {
        if (bytes.size > MAX_HEADER_BYTES) return null
        val text = bytes.toString(Charsets.US_ASCII)
        if (text.isEmpty()) return emptyMap()
        buildMap {
            text.split(';').forEach { argument ->
                val split = argument.indexOf('=')
                require(split > 0)
                val key = argument.substring(0, split)
                require(key in SUPPORTED_OPTIONS && key !in this)
                put(key, argument.substring(split + 1))
            }
        }
    }.getOrNull()

    private fun flushPlain() {
        if (plain.size() == 0) return
        onBytes(plain.toByteArray())
        plain.reset()
    }

    private fun ByteArray.startsWith(prefix: ByteArray): Boolean =
        size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }

    private fun Byte.isBase64Byte(): Boolean {
        val character = toInt().toChar()
        return character in 'A'..'Z' || character in 'a'..'z' || character in '0'..'9' ||
            character == '+' || character == '/' || character == '='
    }

    private inner class Multipart(val options: Map<String, String>) {
        val encoded = ByteArrayOutputStream()

        fun append(content: ByteArray, offset: Int) {
            val length = content.size - offset
            if (length < 0 || encoded.size() > MAX_ENCODED_BYTES - length) {
                multipart = null
                return
            }
            encoded.write(content, offset, length)
        }
    }

    companion object {
        private val PREFIX = "\u001b]1337;".toByteArray()
        private val FILE = "File=".toByteArray()
        private val MULTIPART_FILE = "MultipartFile=".toByteArray()
        private val FILE_PART = "FilePart=".toByteArray()
        private val FILE_END = "FileEnd".toByteArray()
        private val SUPPORTED_OPTIONS = setOf("name", "size", "width", "height", "preserveAspectRatio", "inline")
        private const val MAX_HEADER_BYTES = 4096
        private const val MAX_IMAGE_BYTES = 4 * 1024 * 1024
        private const val MAX_ENCODED_BYTES = 6 * 1024 * 1024
        private const val MAX_CONTROL_BYTES = MAX_ENCODED_BYTES + MAX_HEADER_BYTES
        private const val BEL: Byte = 0x07
        private const val ESC: Byte = 0x1b
        private const val ST_END: Byte = 0x5c
        private const val COLON: Byte = 0x3a
    }
}

internal data class ItermInlineImage(
    val options: Map<String, String>,
    val data: ByteArray,
)
