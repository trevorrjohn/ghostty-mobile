package dev.ghostty.connect.terminal.bridge

import java.nio.ByteBuffer
import java.nio.ByteOrder

class GhosttyTerminal(
    columns: Int = 80,
    rows: Int = 24,
    foreground: Int = 0xfff1f3f8.toInt(),
    background: Int = 0xff0a0c10.toInt(),
    cursor: Int = 0xff8be9b3.toInt(),
    restoredState: ByteArray? = null,
) : AutoCloseable {
    private var handle = restoredState?.let(::nativeRestore)
        ?: nativeCreate(columns, rows, foreground, background, cursor)
    private var cachedColumns = 0
    private var cachedRows = 0
    private var cachedCells = mutableListOf<TerminalCell>()
    private var kittyGeneration = 0L
    private var kittyImages = emptyMap<Int, KittyImage>()

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

    fun scrollRows(deltaRows: Int) {
        if (deltaRows == 0) return
        check(handle != 0L) { "Ghostty terminal is closed" }
        nativeScroll(handle, deltaRows)
    }

    fun scrollToBottom() {
        check(handle != 0L) { "Ghostty terminal is closed" }
        nativeScrollToBottom(handle)
    }

    fun encodeKey(
        key: String,
        text: String = "",
        modifiers: Int = 0,
        action: Int = KEY_ACTION_PRESS,
    ): ByteArray {
        check(handle != 0L) { "Ghostty terminal is closed" }
        return nativeEncodeKey(handle, key, text, modifiers, action)
    }

    fun isPasteSafe(text: String): Boolean = nativePasteIsSafe(text)

    fun encodePaste(text: String): ByteArray {
        check(handle != 0L) { "Ghostty terminal is closed" }
        return nativeEncodePaste(handle, text)
    }

    fun isMouseTracking(): Boolean {
        check(handle != 0L) { "Ghostty terminal is closed" }
        return nativeIsMouseTracking(handle)
    }

    fun encodeMouse(
        action: Int,
        button: Int,
        x: Float,
        y: Float,
        modifiers: Int,
        width: Int,
        height: Int,
        cellWidth: Int,
        cellHeight: Int,
        anyPressed: Boolean,
    ): ByteArray = nativeEncodeMouse(
        handle, action, button, x, y, modifiers, width, height, cellWidth, cellHeight, anyPressed,
    )

    fun selectWord(column: Int, row: Int): Boolean = nativeSelectWord(handle, column, row)

    fun extendSelection(column: Int, row: Int): Boolean = nativeExtendSelection(handle, column, row)

    fun selectedText(): String = nativeSelectedText(handle)

    fun clearSelection() = nativeClearSelection(handle)

    fun hyperlink(column: Int, row: Int): String = nativeHyperlink(handle, column, row)

    fun drainEffects(): TerminalEffects {
        val input = ByteBuffer.wrap(nativeDrainEffects(handle)).order(ByteOrder.LITTLE_ENDIAN)
        return TerminalEffects(
            bells = input.int,
            progressState = input.int,
            progress = input.int,
            clipboard = readString(input),
            notificationTitle = readString(input),
            notificationBody = readString(input),
            unknownSequences = input.int,
            processingError = input.int != 0,
            ptyWrite = readBytes(input),
        )
    }

    fun encodeState(): ByteArray = nativeEncodeState(handle)

    fun kittyFrame(): KittyFrame {
        val input = ByteBuffer.wrap(nativeKittyFrame(handle, kittyGeneration)).order(ByteOrder.LITTLE_ENDIAN)
        val generation = input.long
        val imageCount = input.int
        require(imageCount in 0..1024) { "Invalid Kitty image count" }
        val images = if (generation != kittyGeneration) mutableMapOf<Int, KittyImage>() else kittyImages.toMutableMap()
        repeat(imageCount) {
            val id = input.int
            val imageGeneration = input.long
            val width = input.int
            val height = input.int
            val format = input.int
            val length = input.int
            require(width in 1..4096 && height in 1..4096 && length in 0..input.remaining()) {
                "Invalid Kitty image"
            }
            if (length > 0) {
                val bytesPerPixel = when (format) { 0 -> 3; 1 -> 4; 3 -> 2; 4 -> 1; else -> 0 }
                require(bytesPerPixel > 0 && length == width * height * bytesPerPixel) { "Invalid Kitty pixels" }
                images[id] = KittyImage(id, imageGeneration, width, height, format, ByteArray(length).also(input::get))
            }
        }
        val placementCount = input.int
        require(placementCount in 0..4096) { "Invalid Kitty placement count" }
        val placements = List(placementCount) {
            KittyPlacement(
                imageId = input.int,
                z = input.int,
                xOffset = input.int,
                yOffset = input.int,
                pixelWidth = input.int,
                pixelHeight = input.int,
                viewportColumn = input.int,
                viewportRow = input.int,
                sourceX = input.int,
                sourceY = input.int,
                sourceWidth = input.int,
                sourceHeight = input.int,
            )
        }
        kittyGeneration = generation
        kittyImages = images
        return KittyFrame(generation, images, placements)
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
        val scrollTotal = input.int
        val scrollOffset = input.int
        val scrollVisible = input.int
        val cursorFlags = input.int
        val title = readString(input)
        val pwd = readString(input)
        val dirty = input.int
        val updatedRows = input.int
        if (columns != cachedColumns || rows != cachedRows || dirty == DIRTY_FULL) {
            cachedColumns = columns
            cachedRows = rows
            cachedCells = MutableList(columns * rows) { TerminalCell.empty(foreground, background) }
        }
        require(updatedRows in 0..rows) { "Invalid Ghostty dirty row count" }
        repeat(updatedRows) {
            val row = input.int
            require(row in 0 until rows) { "Invalid Ghostty dirty row" }
            repeat(columns) { column ->
            val cellForeground = input.int
            val cellBackground = input.int
            val flags = input.int
            val textLength = input.int
            require(textLength in 0..input.remaining()) { "Invalid Ghostty cell text" }
            val textBytes = ByteArray(textLength)
            input.get(textBytes)
                cachedCells[row * columns + column] = TerminalCell(
                text = textBytes.toString(Charsets.UTF_8),
                foreground = cellForeground,
                background = cellBackground,
                bold = flags and 1 != 0,
                italic = flags and 2 != 0,
                faint = flags and 4 != 0,
                underline = flags and 8 != 0,
                strikeThrough = flags and 16 != 0,
                invisible = flags and 32 != 0,
                selected = flags and 64 != 0,
                )
            }
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
            scrollTotal = scrollTotal,
            scrollOffset = scrollOffset,
            scrollVisible = scrollVisible,
            cursorBlinking = cursorFlags and 1 != 0,
            passwordInput = cursorFlags and 2 != 0,
            cursorWideTail = cursorFlags and 4 != 0,
            cursorAtPrompt = cursorFlags and 8 != 0,
            title = title,
            pwd = pwd,
            cells = cachedCells.toList(),
        )
    }

    private fun readString(input: ByteBuffer): String {
        return readBytes(input).toString(Charsets.UTF_8)
    }

    private fun readBytes(input: ByteBuffer): ByteArray {
        val length = input.int
        require(length in 0..input.remaining()) { "Invalid Ghostty bytes" }
        return ByteArray(length).also(input::get)
    }

    private external fun nativeCreate(columns: Int, rows: Int, foreground: Int, background: Int, cursor: Int): Long
    private external fun nativeWrite(handle: Long, data: ByteArray, offset: Int, length: Int)
    private external fun nativeResize(handle: Long, columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)
    private external fun nativeSnapshot(handle: Long): ByteArray
    private external fun nativeScroll(handle: Long, deltaRows: Int)
    private external fun nativeScrollToBottom(handle: Long)
    private external fun nativeEncodeKey(handle: Long, key: String, text: String, modifiers: Int, action: Int): ByteArray
    private external fun nativePasteIsSafe(text: String): Boolean
    private external fun nativeEncodePaste(handle: Long, text: String): ByteArray
    private external fun nativeIsMouseTracking(handle: Long): Boolean
    private external fun nativeEncodeMouse(
        handle: Long,
        action: Int,
        button: Int,
        x: Float,
        y: Float,
        modifiers: Int,
        width: Int,
        height: Int,
        cellWidth: Int,
        cellHeight: Int,
        anyPressed: Boolean,
    ): ByteArray
    private external fun nativeSelectWord(handle: Long, column: Int, row: Int): Boolean
    private external fun nativeExtendSelection(handle: Long, column: Int, row: Int): Boolean
    private external fun nativeSelectedText(handle: Long): String
    private external fun nativeClearSelection(handle: Long)
    private external fun nativeHyperlink(handle: Long, column: Int, row: Int): String
    private external fun nativeDrainEffects(handle: Long): ByteArray
    private external fun nativeEncodeState(handle: Long): ByteArray
    private external fun nativeRestore(data: ByteArray): Long
    private external fun nativeKittyFrame(handle: Long, knownGeneration: Long): ByteArray
    private external fun nativeDestroy(handle: Long)

    companion object {
        private const val SNAPSHOT_MAGIC = 0x47565431
        private const val DIRTY_FULL = 2
        const val KEY_ACTION_RELEASE = 0
        const val KEY_ACTION_PRESS = 1
        const val KEY_ACTION_REPEAT = 2
        const val MOUSE_ACTION_PRESS = 0
        const val MOUSE_ACTION_RELEASE = 1
        const val MOUSE_ACTION_MOTION = 2
        const val MOUSE_BUTTON_LEFT = 1
        const val MOUSE_BUTTON_WHEEL_UP = 4
        const val MOUSE_BUTTON_WHEEL_DOWN = 5

        init {
            System.loadLibrary("ghostty_android")
        }
    }
}

data class KittyFrame(
    val generation: Long,
    val images: Map<Int, KittyImage>,
    val placements: List<KittyPlacement>,
)

data class KittyImage(
    val id: Int,
    val generation: Long,
    val width: Int,
    val height: Int,
    val format: Int,
    val data: ByteArray,
)

data class KittyPlacement(
    val imageId: Int,
    val z: Int,
    val xOffset: Int,
    val yOffset: Int,
    val pixelWidth: Int,
    val pixelHeight: Int,
    val viewportColumn: Int,
    val viewportRow: Int,
    val sourceX: Int,
    val sourceY: Int,
    val sourceWidth: Int,
    val sourceHeight: Int,
)

data class TerminalEffects(
    val bells: Int,
    val progressState: Int,
    val progress: Int,
    val clipboard: String,
    val notificationTitle: String,
    val notificationBody: String,
    val unknownSequences: Int,
    val processingError: Boolean,
    val ptyWrite: ByteArray,
) {
    val isEmpty: Boolean get() = bells == 0 && progressState < 0 && clipboard.isEmpty() &&
        notificationTitle.isEmpty() && notificationBody.isEmpty() && unknownSequences == 0 &&
        !processingError && ptyWrite.isEmpty()
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
    val scrollTotal: Int,
    val scrollOffset: Int,
    val scrollVisible: Int,
    val cursorBlinking: Boolean,
    val passwordInput: Boolean,
    val cursorWideTail: Boolean,
    val cursorAtPrompt: Boolean,
    val title: String,
    val pwd: String,
    val cells: List<TerminalCell>,
) {
    val isAtBottom: Boolean get() = scrollOffset + scrollVisible >= scrollTotal
}

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
    val selected: Boolean,
) {
    companion object {
        fun empty(foreground: Int, background: Int) = TerminalCell(
            text = "",
            foreground = foreground,
            background = background,
            bold = false,
            italic = false,
            faint = false,
            underline = false,
            strikeThrough = false,
            invisible = false,
            selected = false,
        )
    }
}
