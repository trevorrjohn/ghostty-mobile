package dev.ghostty.connect.terminal.bridge

import java.nio.ByteBuffer
import java.nio.ByteOrder

class GhosttyTerminal(columns: Int = 80, rows: Int = 24) : AutoCloseable {
    private var handle = nativeCreate(columns, rows)

    fun write(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size) {
        check(handle != 0L) { "Ghostty terminal is closed" }
        nativeWrite(handle, bytes, offset, length)
    }

    fun write(text: String) = write(text.toByteArray(Charsets.UTF_8))

    fun resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        check(handle != 0L) { "Ghostty terminal is closed" }
        nativeResize(handle, columns, rows, cellWidth, cellHeight)
    }

    fun snapshot(): TerminalSnapshot {
        check(handle != 0L) { "Ghostty terminal is closed" }
        return decode(nativeSnapshot(handle))
    }

    override fun close() {
        val current = handle
        handle = 0
        if (current != 0L) nativeDestroy(current)
    }

    private fun decode(bytes: ByteArray): TerminalSnapshot {
        val input = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        check(input.int == SNAPSHOT_MAGIC) { "Unsupported Ghostty snapshot" }
        val columns = input.int
        val rows = input.int
        require(columns in 1..4096 && rows in 1..4096) { "Invalid Ghostty grid" }
        val background = input.int
        val foreground = input.int
        val cursorColor = input.int
        val cursorX = input.int
        val cursorY = input.int
        val cursorStyle = input.int
        val cells = ArrayList<TerminalCell>(columns * rows)
        repeat(columns * rows) {
            val cellForeground = input.int
            val cellBackground = input.int
            val flags = input.int
            val textLength = input.int
            require(textLength in 0..input.remaining()) { "Invalid Ghostty cell text" }
            val textBytes = ByteArray(textLength)
            input.get(textBytes)
            cells += TerminalCell(
                text = textBytes.toString(Charsets.UTF_8),
                foreground = cellForeground,
                background = cellBackground,
                bold = flags and 1 != 0,
                italic = flags and 2 != 0,
                faint = flags and 4 != 0,
                underline = flags and 8 != 0,
                strikeThrough = flags and 16 != 0,
                invisible = flags and 32 != 0,
            )
        }
        return TerminalSnapshot(
            columns = columns,
            rows = rows,
            background = background,
            foreground = foreground,
            cursorColor = cursorColor,
            cursorX = cursorX,
            cursorY = cursorY,
            cursorStyle = cursorStyle,
            cells = cells,
        )
    }

    private external fun nativeCreate(columns: Int, rows: Int): Long
    private external fun nativeWrite(handle: Long, data: ByteArray, offset: Int, length: Int)
    private external fun nativeResize(handle: Long, columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)
    private external fun nativeSnapshot(handle: Long): ByteArray
    private external fun nativeDestroy(handle: Long)

    companion object {
        private const val SNAPSHOT_MAGIC = 0x47565431

        init {
            System.loadLibrary("ghostty_android")
        }
    }
}

data class TerminalSnapshot(
    val columns: Int,
    val rows: Int,
    val background: Int,
    val foreground: Int,
    val cursorColor: Int,
    val cursorX: Int,
    val cursorY: Int,
    val cursorStyle: Int,
    val cells: List<TerminalCell>,
)

data class TerminalCell(
    val text: String,
    val foreground: Int,
    val background: Int,
    val bold: Boolean,
    val italic: Boolean,
    val faint: Boolean,
    val underline: Boolean,
    val strikeThrough: Boolean,
    val invisible: Boolean,
)

