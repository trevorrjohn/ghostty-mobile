package dev.ghostty.connect.terminal

/**
 * Makes a terminal byte stream safe for the temporary plain TextView renderer.
 *
 * Escape sequences may be split across SSH packets, so this is deliberately
 * stateful. Ghostty will eventually consume the original byte stream directly;
 * this decoder exists only for the fallback text renderer.
 */
class PlainTerminalDecoder {
    private enum class State { TEXT, ESCAPE, CSI, OSC, OSC_ESCAPE }

    private var state = State.TEXT

    fun decode(input: String): String = buildString(input.length) {
        input.forEach { character ->
            when (state) {
                State.TEXT -> when (character) {
                    ESC -> state = State.ESCAPE
                    '\r' -> Unit // A TextView cannot apply carriage-return cursor movement.
                    '\u0000' -> Unit
                    else -> if (character == '\n' || character >= ' ') append(character)
                }

                State.ESCAPE -> when (character) {
                    '[' -> state = State.CSI
                    ']' -> state = State.OSC
                    ESC -> Unit
                    else -> state = State.TEXT // Single-character escape command.
                }

                State.CSI -> {
                    // CSI ends with a final byte in the ASCII 0x40–0x7e range.
                    if (character.code in 0x40..0x7e) state = State.TEXT
                }

                State.OSC -> when (character) {
                    '\u0007' -> state = State.TEXT // BEL terminator
                    ESC -> state = State.OSC_ESCAPE
                }

                State.OSC_ESCAPE -> state = if (character == '\\') State.TEXT else State.OSC
            }
        }
    }

    private companion object {
        const val ESC = '\u001b'
    }
}
