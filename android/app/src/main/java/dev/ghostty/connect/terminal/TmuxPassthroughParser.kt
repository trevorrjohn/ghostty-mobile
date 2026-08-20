package dev.ghostty.connect.terminal

import java.io.ByteArrayOutputStream

internal class TmuxPassthroughParser(private val onBytes: (ByteArray) -> Unit) {
    private val plain = ByteArrayOutputStream()
    private val passthrough = ByteArrayOutputStream()
    private var prefixIndex = 0
    private var capturing = false
    private var pendingEscape = false
    private var draining = false

    fun feed(bytes: ByteArray) {
        bytes.forEach(::accept)
        flushPlain()
    }

    fun reset() {
        plain.reset()
        passthrough.reset()
        prefixIndex = 0
        capturing = false
        pendingEscape = false
        draining = false
    }

    private fun accept(value: Byte) {
        if (capturing) {
            if (pendingEscape) {
                pendingEscape = false
                when (value) {
                    ESC -> append(ESC) // tmux escapes payload ESC bytes by doubling them.
                    ST_END -> finishPassthrough()
                    else -> {
                        append(ESC)
                        append(value)
                    }
                }
            } else if (value == ESC) {
                pendingEscape = true
            } else {
                append(value)
            }
            return
        }

        if (value == PREFIX[prefixIndex]) {
            prefixIndex++
            if (prefixIndex == PREFIX.size) {
                flushPlain()
                prefixIndex = 0
                capturing = true
                passthrough.reset()
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

    private fun append(value: Byte) {
        if (draining) return
        if (passthrough.size() >= MAX_PASSTHROUGH_BYTES) {
            draining = true
            passthrough.reset()
        } else {
            passthrough.write(value.toInt())
        }
    }

    private fun finishPassthrough() {
        if (!draining) onBytes(passthrough.toByteArray())
        passthrough.reset()
        capturing = false
        draining = false
    }

    private fun flushPlain() {
        if (plain.size() == 0) return
        onBytes(plain.toByteArray())
        plain.reset()
    }

    companion object {
        private val PREFIX = "\u001bPtmux;".toByteArray()
        private const val MAX_PASSTHROUGH_BYTES = 7 * 1024 * 1024
        private const val ESC: Byte = 0x1b
        private const val ST_END: Byte = 0x5c
    }
}
