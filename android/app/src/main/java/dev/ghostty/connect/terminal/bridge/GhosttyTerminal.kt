package dev.ghostty.connect.terminal.bridge

import java.nio.ByteBuffer
import java.nio.ByteOrder

class GhosttyTerminal(
    columns: Int = 80,
    rows: Int = 24,
    foreground: Int = 0xfff1f3f8.toInt(),
    background: Int = 0xff0a0c10.toInt(),
    cursor: Int = 0xff8be9b3.toInt(),
    palette: IntArray = IntArray(0),
    restoredState: ByteArray? = null,
) : AutoCloseable {
    private val restored = restoredState?.let(::decodeSavedState)
    private var handle = restored?.nativeState?.let(::nativeRestore)
        ?: nativeCreate(columns, rows, foreground, background, cursor, palette)
    private var cachedColumns = 0
    private var cachedRows = 0
    private var cachedCells = mutableListOf<TerminalCell>()
    private var kittyGeneration = restored?.kittyFrame?.generation ?: 0L
    private var kittyImages = restored?.kittyFrame?.images ?: emptyMap()
    private var restoredPlacements = restored?.kittyFrame?.placements.orEmpty()

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

    fun encodeFocus(focused: Boolean): ByteArray = nativeEncodeFocus(handle, focused)

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

    fun selectRange(startColumn: Int, endColumn: Int, row: Int): Boolean =
        nativeSelectRange(handle, startColumn, endColumn, row)

    fun extendSelection(column: Int, row: Int): Boolean = nativeExtendSelection(handle, column, row)

    fun setSelectionEndpoint(start: Boolean, column: Int, row: Int): Boolean =
        nativeSetSelectionEndpoint(handle, start, column, row)

    fun selectionEndpoints(): IntArray = nativeSelectionEndpoints(handle)

    fun selectedText(): String = nativeSelectedText(handle)

    fun clearSelection() = nativeClearSelection(handle)

    fun selectLatestOutput(): Boolean = nativeSelectLatestOutput(handle)

    fun selectOutput(column: Int, row: Int): Boolean = nativeSelectOutput(handle, column, row)

    fun jumpPrompt(direction: Int): Boolean = nativeJumpPrompt(handle, direction)

    fun search(query: String, direction: Int): Boolean = nativeSearch(handle, query, direction)

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

    fun encodeState(): ByteArray {
        val native = nativeEncodeState(handle)
        val frame = kittyFrame()
        val revision = GHOSTTY_REVISION.toByteArray(Charsets.UTF_8)
        val size = 4 + 4 + 4 + revision.size + 4 + native.size + 8 + 4 +
            frame.images.values.sumOf { 4 + 8 + 4 * 4 + 4 + it.data.size } +
            4 + frame.placements.size * (12 * 4)
        require(size <= MAX_SAVED_STATE_SIZE) { "Terminal snapshot is too large" }
        return ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(SAVED_STATE_MAGIC)
            putInt(SAVED_STATE_VERSION)
            putInt(revision.size)
            put(revision)
            putInt(native.size)
            put(native)
            putLong(frame.generation)
            putInt(frame.images.size)
            frame.images.values.forEach { image ->
                putInt(image.id)
                putLong(image.generation)
                putInt(image.width)
                putInt(image.height)
                putInt(image.format)
                putInt(image.data.size)
                put(image.data)
            }
            putInt(frame.placements.size)
            frame.placements.forEach { placement ->
                putInt(placement.imageId)
                putInt(placement.z)
                putInt(placement.xOffset)
                putInt(placement.yOffset)
                putInt(placement.pixelWidth)
                putInt(placement.pixelHeight)
                putInt(placement.viewportColumn)
                putInt(placement.viewportRow)
                putInt(placement.sourceX)
                putInt(placement.sourceY)
                putInt(placement.sourceWidth)
                putInt(placement.sourceHeight)
            }
        }.array()
    }

    fun kittyFrame(): KittyFrame {
        val input = ByteBuffer.wrap(nativeKittyFrame(handle, kittyGeneration)).order(ByteOrder.LITTLE_ENDIAN)
        val generation = input.long
        val imageCount = input.int
        require(imageCount in 0..1024) { "Invalid Kitty image count" }
        val images = if (generation != kittyGeneration && restoredPlacements.isEmpty()) {
            mutableMapOf<Int, KittyImage>()
        } else {
            kittyImages.toMutableMap()
        }
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
        val effectivePlacements = if (placements.isEmpty() && restoredPlacements.isNotEmpty()) {
            restoredPlacements
        } else {
            restoredPlacements = emptyList()
            placements
        }
        return KittyFrame(generation, images, effectivePlacements)
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
        val dirtyRows = IntArray(updatedRows)
        repeat(updatedRows) { dirtyIndex ->
            val row = input.int
            dirtyRows[dirtyIndex] = row
            require(row in 0 until rows) { "Invalid Ghostty dirty row" }
            repeat(columns) { column ->
            val cellForeground = input.int
            val cellBackground = input.int
            val flags = input.int
            val underlineColor = input.int
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
                underlineStyle = flags shr 8 and 7,
                underlineColor = underlineColor,
                strikeThrough = flags and 16 != 0,
                invisible = flags and 32 != 0,
                selected = flags and 64 != 0,
                overline = flags and 128 != 0,
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
            dirty = dirty,
            dirtyRows = dirtyRows,
            cells = cachedCells.toList(),
        )
    }

    private fun decodeSavedState(bytes: ByteArray): SavedState {
        val input = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        if (bytes.size < 8 || input.int != SAVED_STATE_MAGIC) return SavedState(bytes, null)
        require(input.int == SAVED_STATE_VERSION) { "Unsupported saved terminal version" }
        val revisionLength = input.int
        require(revisionLength in 1..128 && revisionLength <= input.remaining()) { "Invalid Ghostty revision" }
        val revision = ByteArray(revisionLength).also(input::get).toString(Charsets.UTF_8)
        require(revision == GHOSTTY_REVISION) { "Saved session uses a different Ghostty revision" }
        val nativeLength = input.int
        require(nativeLength in 1..input.remaining()) { "Invalid native terminal snapshot" }
        val native = ByteArray(nativeLength).also(input::get)
        val generation = input.long
        val imageCount = input.int
        require(imageCount in 0..1024) { "Invalid saved Kitty image count" }
        val images = buildMap {
            repeat(imageCount) {
                val id = input.int
                val imageGeneration = input.long
                val width = input.int
                val height = input.int
                val format = input.int
                val length = input.int
                require(width in 1..4096 && height in 1..4096 && length in 0..input.remaining()) {
                    "Invalid saved Kitty image"
                }
                put(id, KittyImage(id, imageGeneration, width, height, format, ByteArray(length).also(input::get)))
            }
        }
        val placementCount = input.int
        require(placementCount in 0..4096 && input.remaining() == placementCount * 48) {
            "Invalid saved Kitty placements"
        }
        val placements = List(placementCount) {
            KittyPlacement(input.int, input.int, input.int, input.int, input.int, input.int,
                input.int, input.int, input.int, input.int, input.int, input.int)
        }
        return SavedState(native, KittyFrame(generation, images, placements))
    }

    private fun readString(input: ByteBuffer): String {
        return readBytes(input).toString(Charsets.UTF_8)
    }

    private fun readBytes(input: ByteBuffer): ByteArray {
        val length = input.int
        require(length in 0..input.remaining()) { "Invalid Ghostty bytes" }
        return ByteArray(length).also(input::get)
    }

    private external fun nativeCreate(
        columns: Int, rows: Int, foreground: Int, background: Int, cursor: Int, palette: IntArray,
    ): Long
    private external fun nativeWrite(handle: Long, data: ByteArray, offset: Int, length: Int)
    private external fun nativeResize(handle: Long, columns: Int, rows: Int, cellWidth: Int, cellHeight: Int)
    private external fun nativeSnapshot(handle: Long): ByteArray
    private external fun nativeScroll(handle: Long, deltaRows: Int)
    private external fun nativeScrollToBottom(handle: Long)
    private external fun nativeEncodeKey(handle: Long, key: String, text: String, modifiers: Int, action: Int): ByteArray
    private external fun nativePasteIsSafe(text: String): Boolean
    private external fun nativeEncodePaste(handle: Long, text: String): ByteArray
    private external fun nativeIsMouseTracking(handle: Long): Boolean
    private external fun nativeEncodeFocus(handle: Long, focused: Boolean): ByteArray
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
    private external fun nativeSelectRange(handle: Long, startColumn: Int, endColumn: Int, row: Int): Boolean
    private external fun nativeExtendSelection(handle: Long, column: Int, row: Int): Boolean
    private external fun nativeSetSelectionEndpoint(handle: Long, start: Boolean, column: Int, row: Int): Boolean
    private external fun nativeSelectionEndpoints(handle: Long): IntArray
    private external fun nativeSelectedText(handle: Long): String
    private external fun nativeClearSelection(handle: Long)
    private external fun nativeSelectLatestOutput(handle: Long): Boolean
    private external fun nativeSelectOutput(handle: Long, column: Int, row: Int): Boolean
    private external fun nativeJumpPrompt(handle: Long, direction: Int): Boolean
    private external fun nativeSearch(handle: Long, query: String, direction: Int): Boolean
    private external fun nativeHyperlink(handle: Long, column: Int, row: Int): String
    private external fun nativeDrainEffects(handle: Long): ByteArray
    private external fun nativeEncodeState(handle: Long): ByteArray
    private external fun nativeRestore(data: ByteArray): Long
    private external fun nativeKittyFrame(handle: Long, knownGeneration: Long): ByteArray
    private external fun nativeDestroy(handle: Long)

    companion object {
        private const val SNAPSHOT_MAGIC = 0x47565431
        private const val SAVED_STATE_MAGIC = 0x47544332
        private const val SAVED_STATE_VERSION = 1
        private const val GHOSTTY_REVISION = "9ae02a326f62bd88f7f5508cf1807c67e7775cb5"
        private const val MAX_SAVED_STATE_SIZE = 32 * 1024 * 1024
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

private data class SavedState(val nativeState: ByteArray, val kittyFrame: KittyFrame?)

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
    val dirty: Int,
    val dirtyRows: IntArray,
    val cells: List<TerminalCell>,
) {
    val isAtBottom: Boolean get() = scrollOffset + scrollVisible >= scrollTotal
    val isFullyDirty: Boolean get() = dirty == 2
}

data class TerminalCell(
    val text: String,
    val foreground: Int,
    val background: Int,
    val bold: Boolean,
    val italic: Boolean,
    val faint: Boolean,
    val underlineStyle: Int,
    val underlineColor: Int,
    val strikeThrough: Boolean,
    val invisible: Boolean,
    val selected: Boolean,
    val overline: Boolean,
) {
    companion object {
        fun empty(foreground: Int, background: Int) = TerminalCell(
            text = "",
            foreground = foreground,
            background = background,
            bold = false,
            italic = false,
            faint = false,
            underlineStyle = 0,
            underlineColor = foreground,
            strikeThrough = false,
            invisible = false,
            selected = false,
            overline = false,
        )
    }
}
