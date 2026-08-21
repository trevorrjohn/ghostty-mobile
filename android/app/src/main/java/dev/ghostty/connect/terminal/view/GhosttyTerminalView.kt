package dev.ghostty.connect.terminal.view

import android.content.Context
import android.content.ClipData
import android.content.ClipboardManager
import android.annotation.TargetApi
import android.graphics.Canvas
import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.DashPathEffect
import android.graphics.Path
import android.graphics.Typeface
import android.graphics.RenderNode
import android.graphics.fonts.Font
import android.graphics.text.TextRunShaper
import android.os.Build
import android.text.InputType
import android.util.TypedValue
import android.view.KeyEvent
import android.view.InputDevice
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.os.SystemClock
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.OverScroller
import android.widget.TextView
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.bridge.KittyFrame
import dev.ghostty.connect.terminal.bridge.KittyImage
import dev.ghostty.connect.terminal.bridge.TerminalCell
import dev.ghostty.connect.terminal.bridge.TerminalSnapshot
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.abs

class GhosttyTerminalView(
    context: Context,
    private val terminal: GhosttyTerminal,
    initialTextSizeSp: Float = 15f,
) : View(context) {
    var onInput: (String) -> Unit = {}
    var acceptsInput = true
    var onSpecialKey: (String) -> Unit = {}
    var onKeyEvent: (KeyEvent) -> Boolean = { false }
    var isMouseTracking: () -> Boolean = { false }
    var onMouseEvent: (
        action: Int, button: Int, x: Float, y: Float,
        width: Int, height: Int, cellWidth: Int, cellHeight: Int, anyPressed: Boolean, metaState: Int,
    ) -> Unit = { _, _, _, _, _, _, _, _, _, _ -> }
    var onTerminalFocusChanged: (Boolean) -> Unit = {}
    var onSelectionStart: (column: Int, row: Int) -> Boolean = { _, _ -> false }
    var onSelectionUpdate: (start: Boolean, column: Int, row: Int) -> Unit = { _, _, _ -> }
    var onSelectionFinished: () -> Unit = {}
    var onMetadataChanged: (title: String, pwd: String, atPrompt: Boolean, passwordInput: Boolean) -> Unit =
        { _, _, _, _ -> }
    var onLinkTap: (column: Int, row: Int) -> Boolean = { _, _ -> false }
    var onResize: (columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) -> Unit = { _, _, _, _ -> }
    var onScrollPositionChanged: (isAtBottom: Boolean) -> Unit = {}
    var onTextSizeChanged: (Float) -> Unit = {}
    private var terminalTextSizeSp = initialTextSizeSp.coerceIn(MIN_TEXT_SIZE_SP, MAX_TEXT_SIZE_SP)
    private var terminalTextSize = sp(terminalTextSizeSp)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE
        textSize = terminalTextSize
        isSubpixelText = true
    }
    private val boldTypeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    private val regularTypeface = Typeface.MONOSPACE
    private var cellWidth = paint.measureText("M")
    private var cellHeight = paint.fontMetrics.run { descent - ascent + leading }
    private var baselineOffset = -paint.fontMetrics.ascent
    private var snapshot: TerminalSnapshot = terminal.snapshot()
    private var kittyFrame: KittyFrame = terminal.kittyFrame()
    private val kittyBitmaps = mutableMapOf<Int, Pair<Long, Bitmap>>()
    private data class CachedRow(
        val backgrounds: RenderNode,
        val foregrounds: RenderNode,
    )
    private val rowCaches = mutableListOf<CachedRow>()
    private val dirtyCachedRows = mutableSetOf<Int>()
    private var allCachedRowsDirty = true
    private val scroller = OverScroller(context)
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
    private val minimumFlingVelocity = ViewConfiguration.get(context).scaledMinimumFlingVelocity
    private val maximumFlingVelocity = ViewConfiguration.get(context).scaledMaximumFlingVelocity
    private var velocityTracker: VelocityTracker? = null
    private var lastTouchY = 0f
    private var downY = 0f
    private var scrollPixels = 0f
    private var dragging = false
    private var scaleGesture = false
    private var remoteMouseGesture = false
    private var remotePressSent = false
    private var remoteTwoFingerGesture = false
    private var remoteDownX = 0f
    private var remoteDownY = 0f
    private var remoteWheelPixels = 0f
    private var pointerMetaState = 0
    private var selectionActive = false
    private var selectionVisible = false
    private var selectionStartVisible = false
    private var selectionEndVisible = false
    private var selectionStartX = 0f
    private var selectionStartY = 0f
    private var selectionEndX = 0f
    private var selectionEndY = 0f
    private var selectionDragX = 0f
    private var selectionDragY = 0f
    private var draggedHandle = HANDLE_NONE
    private var selectionEdgeDirection = 0
    private val selectionAutoScroll = object : Runnable {
        override fun run() {
            if (!selectionActive || selectionEdgeDirection == 0) return
            terminal.scrollRows(selectionEdgeDirection)
            onSelectionUpdate(
                draggedHandle == HANDLE_START,
                cellColumn(selectionDragX),
                cellRow(selectionDragY),
            )
            refresh()
            postDelayed(this, SELECTION_SCROLL_INTERVAL_MS)
        }
    }
    private var pendingLongPress: Runnable? = null
    private var passwordInput = false
    private var accessibilityText: String? = null
    private var accessibilityUpdatePending = false
    private val accessibilityUpdate = Runnable {
        accessibilityUpdatePending = false
        if (!snapshot.passwordInput) sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
    }
    private var lastFlingY = 0
    private val liveButton = RectF()
    private val scaleDetector = ScaleGestureDetector(context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                scaleGesture = true
                dragging = false
                scroller.forceFinished(true)
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val newSize = (terminalTextSizeSp * detector.scaleFactor).coerceIn(MIN_TEXT_SIZE_SP, MAX_TEXT_SIZE_SP)
                if (abs(newSize - terminalTextSizeSp) < 0.05f) return true
                terminalTextSizeSp = newSize
                onTextSizeChanged(newSize)
                updateFontMetrics()
                resizeTerminal()
                return true
            }
        },
    )

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_YES
    }

    fun refresh() {
        val wasAtBottom = snapshot.isAtBottom
        val previousColumns = snapshot.columns
        val previousRows = snapshot.rows
        snapshot = terminal.snapshot()
        if (snapshot.isFullyDirty || snapshot.columns != previousColumns || snapshot.rows != previousRows) {
            invalidateRowCaches()
        } else {
            dirtyCachedRows.addAll(snapshot.dirtyRows.toList())
        }
        accessibilityText = null
        if (!accessibilityUpdatePending &&
            context.getSystemService(AccessibilityManager::class.java)?.isEnabled == true) {
            accessibilityUpdatePending = true
            postDelayed(accessibilityUpdate, ACCESSIBILITY_UPDATE_INTERVAL_MS)
        }
        kittyFrame = terminal.kittyFrame()
        updateSelectionHandles()
        updateKittyBitmaps()
        onMetadataChanged(snapshot.title, snapshot.pwd, snapshot.cursorAtPrompt, snapshot.passwordInput)
        if (snapshot.isAtBottom != wasAtBottom) onScrollPositionChanged(snapshot.isAtBottom)
        invalidate()
    }

    private fun updateSelectionHandles() {
        val endpoints = terminal.selectionEndpoints()
        selectionStartVisible = endpoints[0] >= 0
        selectionEndVisible = endpoints[2] >= 0
        selectionVisible = selectionStartVisible || selectionEndVisible
        if (selectionStartVisible) {
            selectionStartX = endpoints[0] * cellWidth
            selectionStartY = (endpoints[1] + 1) * cellHeight
        }
        if (selectionEndVisible) {
            selectionEndX = (endpoints[2] + 1) * cellWidth
            selectionEndY = (endpoints[3] + 1) * cellHeight
        }
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        resizeTerminal()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(selectionAutoScroll)
        removeCallbacks(accessibilityUpdate)
        accessibilityUpdatePending = false
        kittyBitmaps.values.forEach { it.second.recycle() }
        kittyBitmaps.clear()
        discardRowCaches()
        super.onDetachedFromWindow()
    }

    private fun resizeTerminal() {
        if (width <= 0 || height <= 0) return
        val columns = max(1, floor(width / cellWidth).toInt())
        val rows = max(1, floor(height / cellHeight).toInt())
        terminal.resize(columns, rows, cellWidth.toInt().coerceAtLeast(1), cellHeight.toInt().coerceAtLeast(1))
        onResize(columns, rows, width, height)
        refresh()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(snapshot.background)
        drawKitty(canvas) { it < KITTY_BELOW_BACKGROUND }
        val visibleColumns = minOf(snapshot.columns, floor(width / cellWidth).toInt())
        val visibleRows = minOf(snapshot.rows, floor(height / cellHeight).toInt())
        val cached = canvas.isHardwareAccelerated
        if (cached) drawCachedRows(canvas, visibleColumns, visibleRows, foreground = false)
        else for (row in 0 until visibleRows) drawRowBackgrounds(canvas, row, visibleColumns, row * cellHeight)
        drawKitty(canvas) { it in KITTY_BELOW_BACKGROUND until 0 }
        if (cached) drawCachedRows(canvas, visibleColumns, visibleRows, foreground = true)
        else for (row in 0 until visibleRows) drawRowForegrounds(canvas, row, visibleColumns, row * cellHeight, false)
        drawKitty(canvas) { it >= 0 }
        drawCursor(canvas, visibleColumns, visibleRows)
        drawScrollPosition(canvas)
        drawSelectionHandles(canvas)
        resetPaint()
    }

    private fun drawCachedRows(canvas: Canvas, columns: Int, rows: Int, foreground: Boolean) {
        ensureRowCaches(rows)
        for (row in 0 until rows) {
            val cache = rowCaches[row]
            val node = if (foreground) cache.foregrounds else cache.backgrounds
            if (allCachedRowsDirty || row in dirtyCachedRows || !node.hasDisplayList()) {
                recordRow(node, row, columns, foreground)
            }
            val save = canvas.save()
            canvas.translate(0f, row * cellHeight)
            canvas.drawRenderNode(node)
            canvas.restoreToCount(save)
        }
        if (foreground) {
            allCachedRowsDirty = false
            dirtyCachedRows.removeAll(0 until rows)
        }
    }

    private fun ensureRowCaches(rows: Int) {
        while (rowCaches.size < rows) {
            val row = rowCaches.size
            rowCaches += CachedRow(RenderNode("terminal-bg-$row"), RenderNode("terminal-fg-$row"))
        }
        while (rowCaches.size > rows) {
            rowCaches.removeAt(rowCaches.lastIndex).also {
                it.backgrounds.discardDisplayList()
                it.foregrounds.discardDisplayList()
            }
        }
    }

    private fun recordRow(node: RenderNode, row: Int, columns: Int, foreground: Boolean) {
        val rowWidth = kotlin.math.ceil(columns * cellWidth).toInt().coerceAtLeast(1)
        val rowHeight = kotlin.math.ceil(cellHeight).toInt().coerceAtLeast(1)
        node.setPosition(0, 0, rowWidth, rowHeight)
        val recording = node.beginRecording(rowWidth, rowHeight)
        try {
            if (foreground) drawRowForegrounds(recording, row, columns, 0f, Build.VERSION.SDK_INT >= 31)
            else drawRowBackgrounds(recording, row, columns, 0f)
        } finally {
            node.endRecording()
        }
    }

    private fun drawRowBackgrounds(canvas: Canvas, row: Int, columns: Int, top: Float) {
        for (column in 0 until columns) {
            val cell = snapshot.cells[row * snapshot.columns + column]
            val left = column * cellWidth
            if (cell.background != snapshot.background) {
                paint.color = cell.background
                paint.style = Paint.Style.FILL
                canvas.drawRect(left, top, left + cellWidth + 1f, top + cellHeight + 1f, paint)
            }
            if (cell.selected) {
                paint.color = 0xff315849.toInt()
                paint.style = Paint.Style.FILL
                canvas.drawRect(left, top, left + cellWidth + 1f, top + cellHeight + 1f, paint)
            }
        }
    }

    private fun drawRowForegrounds(canvas: Canvas, row: Int, columns: Int, top: Float, shaped: Boolean) {
        if (shaped && Build.VERSION.SDK_INT >= 31) drawShapedRow(canvas, row, columns, top)
        else drawCellRow(canvas, row, columns, top)
    }

    private fun drawCellRow(canvas: Canvas, row: Int, columns: Int, top: Float) {
        for (column in 0 until columns) {
            val cell = snapshot.cells[row * snapshot.columns + column]
            if (cell.invisible || cell.text.isEmpty()) continue
            val left = column * cellWidth
            configureTextPaint(cell)
            paint.isStrikeThruText = false
            canvas.drawText(cell.text, left, top + baselineOffset, paint)
            drawCellDecorations(canvas, cell, left, top)
        }
    }

    @TargetApi(31)
    private fun drawShapedRow(canvas: Canvas, row: Int, columns: Int, top: Float) {
        var column = 0
        while (column < columns) {
            val first = snapshot.cells[row * snapshot.columns + column]
            if (first.invisible || first.text.isEmpty()) {
                column++
                continue
            }
            val start = column
            val text = StringBuilder(first.text)
            column++
            while (column < columns) {
                val next = snapshot.cells[row * snapshot.columns + column]
                if (next.invisible || next.text.isEmpty() || !first.canShapeWith(next)) break
                text.append(next.text)
                column++
            }
            val left = start * cellWidth
            val right = column * cellWidth
            configureTextPaint(first)
            paint.isStrikeThruText = false
            val glyphs = TextRunShaper.shapeTextRun(
                text, 0, text.length, 0, text.length, left, top + baselineOffset, false, paint,
            )
            val save = canvas.save()
            canvas.clipRect(left, top, right, top + cellHeight)
            drawPositionedGlyphs(canvas, glyphs)
            canvas.restoreToCount(save)
            for (decorationColumn in start until column) {
                drawCellDecorations(
                    canvas,
                    snapshot.cells[row * snapshot.columns + decorationColumn],
                    decorationColumn * cellWidth,
                    top,
                )
            }
        }
    }

    @TargetApi(31)
    private fun drawPositionedGlyphs(canvas: Canvas, glyphs: android.graphics.text.PositionedGlyphs) {
        var start = 0
        while (start < glyphs.glyphCount()) {
            val font: Font = glyphs.getFont(start)
            var end = start + 1
            while (end < glyphs.glyphCount() && glyphs.getFont(end) == font) end++
            val count = end - start
            val ids = IntArray(count)
            val positions = FloatArray(count * 2)
            repeat(count) { index ->
                ids[index] = glyphs.getGlyphId(start + index)
                positions[index * 2] = glyphs.getGlyphX(start + index)
                positions[index * 2 + 1] = glyphs.getGlyphY(start + index)
            }
            canvas.drawGlyphs(ids, 0, positions, 0, count, font, paint)
            start = end
        }
    }

    private fun TerminalCell.canShapeWith(other: TerminalCell): Boolean =
        foreground == other.foreground && bold == other.bold && italic == other.italic && faint == other.faint &&
            strikeThrough == other.strikeThrough && overline == other.overline &&
            underlineStyle == other.underlineStyle && underlineColor == other.underlineColor

    private fun configureTextPaint(cell: TerminalCell) {
        paint.color = cell.foreground
        paint.alpha = if (cell.faint) 150 else 255
        paint.typeface = if (cell.bold) boldTypeface else regularTypeface
        paint.textSkewX = if (cell.italic) -0.2f else 0f
        paint.style = Paint.Style.FILL
        paint.isUnderlineText = false
    }

    private fun drawCellDecorations(canvas: Canvas, cell: TerminalCell, left: Float, top: Float) {
        drawUnderline(canvas, cell.underlineStyle, cell.underlineColor, left, top)
        paint.color = cell.foreground
        paint.alpha = if (cell.faint) 150 else 255
        paint.strokeWidth = resources.displayMetrics.density.coerceAtLeast(1f)
        if (cell.strikeThrough) {
            val y = top + baselineOffset - cellHeight * 0.3f
            canvas.drawLine(left, y, left + cellWidth, y, paint)
        }
        if (cell.overline) {
            canvas.drawLine(left, top + paint.strokeWidth, left + cellWidth, top + paint.strokeWidth, paint)
        }
    }

    private fun invalidateRowCaches() {
        allCachedRowsDirty = true
        dirtyCachedRows.clear()
        rowCaches.forEach {
            it.backgrounds.discardDisplayList()
            it.foregrounds.discardDisplayList()
        }
    }

    private fun discardRowCaches() {
        invalidateRowCaches()
        rowCaches.clear()
    }

    private fun drawUnderline(canvas: Canvas, style: Int, color: Int, left: Float, top: Float) {
        if (style == 0) return
        val y = top + baselineOffset + resources.displayMetrics.density
        paint.color = color
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = resources.displayMetrics.density.coerceAtLeast(1f)
        when (style) {
            2 -> {
                canvas.drawLine(left, y - paint.strokeWidth, left + cellWidth, y - paint.strokeWidth, paint)
                canvas.drawLine(left, y + paint.strokeWidth, left + cellWidth, y + paint.strokeWidth, paint)
            }
            3 -> {
                val path = Path().apply {
                    moveTo(left, y)
                    val quarter = cellWidth / 4f
                    cubicTo(left + quarter, y - paint.strokeWidth * 2, left + quarter, y + paint.strokeWidth * 2,
                        left + quarter * 2, y)
                    cubicTo(left + quarter * 3, y - paint.strokeWidth * 2, left + quarter * 3,
                        y + paint.strokeWidth * 2, left + cellWidth, y)
                }
                canvas.drawPath(path, paint)
            }
            4, 5 -> {
                paint.pathEffect = DashPathEffect(
                    if (style == 4) floatArrayOf(paint.strokeWidth, paint.strokeWidth * 2)
                    else floatArrayOf(paint.strokeWidth * 4, paint.strokeWidth * 2),
                    0f,
                )
                canvas.drawLine(left, y, left + cellWidth, y, paint)
                paint.pathEffect = null
            }
            else -> canvas.drawLine(left, y, left + cellWidth, y, paint)
        }
        paint.style = Paint.Style.FILL
    }

    private fun updateKittyBitmaps() {
        val activeIds = kittyFrame.images.keys
        kittyBitmaps.keys.filterNot(activeIds::contains).forEach { id -> kittyBitmaps.remove(id)?.second?.recycle() }
        kittyFrame.images.values.forEach { image ->
            if (kittyBitmaps[image.id]?.first == image.generation) return@forEach
            kittyBitmaps.remove(image.id)?.second?.recycle()
            kittyBitmaps[image.id] = image.generation to image.toBitmap()
        }
    }

    private fun KittyImage.toBitmap(): Bitmap {
        val pixels = IntArray(width * height)
        var offset = 0
        for (index in pixels.indices) {
            val red: Int
            val green: Int
            val blue: Int
            val alpha: Int
            when (format) {
                0 -> {
                    red = data[offset++].toInt() and 0xff
                    green = data[offset++].toInt() and 0xff
                    blue = data[offset++].toInt() and 0xff
                    alpha = 0xff
                }
                1 -> {
                    red = data[offset++].toInt() and 0xff
                    green = data[offset++].toInt() and 0xff
                    blue = data[offset++].toInt() and 0xff
                    alpha = data[offset++].toInt() and 0xff
                }
                3 -> {
                    red = data[offset++].toInt() and 0xff
                    green = red
                    blue = red
                    alpha = data[offset++].toInt() and 0xff
                }
                else -> {
                    red = data[offset++].toInt() and 0xff
                    green = red
                    blue = red
                    alpha = 0xff
                }
            }
            pixels[index] = alpha shl 24 or (red shl 16) or (green shl 8) or blue
        }
        return Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
    }

    private fun drawKitty(canvas: Canvas, matchesLayer: (Int) -> Boolean) {
        kittyFrame.placements.filter { matchesLayer(it.z) }.forEach { placement ->
            val bitmap = kittyBitmaps[placement.imageId]?.second ?: return@forEach
            val source = Rect(
                placement.sourceX,
                placement.sourceY,
                placement.sourceX + placement.sourceWidth,
                placement.sourceY + placement.sourceHeight,
            )
            val left = placement.viewportColumn * cellWidth + placement.xOffset
            val top = placement.viewportRow * cellHeight + placement.yOffset
            val destination = RectF(left, top, left + placement.pixelWidth, top + placement.pixelHeight)
            canvas.drawBitmap(bitmap, source, destination, paint)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        pointerMetaState = event.metaState
        if (!remoteMouseGesture && !remoteTwoFingerGesture) scaleDetector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                scroller.forceFinished(true)
                velocityTracker?.recycle()
                velocityTracker = VelocityTracker.obtain().also { it.addMovement(event) }
                downY = event.y
                lastTouchY = event.y
                dragging = false
                scaleGesture = false
                remoteMouseGesture = isMouseTracking()
                remotePressSent = false
                remoteTwoFingerGesture = false
                remoteDownX = event.x
                remoteDownY = event.y
                draggedHandle = selectionHandleAt(event.x, event.y)
                if (draggedHandle != HANDLE_NONE) {
                    selectionActive = true
                    selectionDragX = event.x
                    selectionDragY = event.y
                    cancelPendingLongPress()
                    return true
                }
                pendingLongPress = Runnable {
                    if (!dragging && !scaleGesture) {
                        remoteMouseGesture = false
                        selectionActive = onSelectionStart(cellColumn(remoteDownX), cellRow(remoteDownY))
                        if (selectionActive) {
                            selectionVisible = true
                            draggedHandle = HANDLE_END
                            selectionDragX = remoteDownX
                            selectionDragY = remoteDownY
                            refresh()
                        }
                    }
                }.also { postDelayed(it, ViewConfiguration.getLongPressTimeout().toLong()) }
                return true
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                cancelPendingLongPress()
                if (remoteMouseGesture) {
                    if (remotePressSent) sendRemoteMouse(MOUSE_RELEASE, MOUSE_LEFT, event.x, event.y, false)
                    remoteMouseGesture = false
                    remotePressSent = false
                    remoteTwoFingerGesture = true
                    lastTouchY = pointerAverageY(event)
                    remoteWheelPixels = 0f
                    return true
                }
                scaleGesture = true
                dragging = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (selectionActive) {
                    selectionDragX = event.x.coerceIn(0f, width.toFloat())
                    selectionDragY = event.y.coerceIn(0f, height.toFloat())
                    onSelectionUpdate(draggedHandle == HANDLE_START, cellColumn(event.x), cellRow(event.y))
                    updateSelectionAutoScroll(event.y)
                    refresh()
                    return true
                }
                if (abs(event.x - remoteDownX) > touchSlop || abs(event.y - remoteDownY) > touchSlop) cancelPendingLongPress()
                if (remoteTwoFingerGesture && event.pointerCount >= 2) {
                    val y = pointerAverageY(event)
                    remoteWheelPixels += y - lastTouchY
                    lastTouchY = y
                    val threshold = cellHeight.coerceAtLeast(1f)
                    while (abs(remoteWheelPixels) >= threshold) {
                        val button = if (remoteWheelPixels < 0) MOUSE_WHEEL_DOWN else MOUSE_WHEEL_UP
                        sendRemoteMouse(MOUSE_PRESS, button, event.x, y, false)
                        remoteWheelPixels += if (remoteWheelPixels < 0) threshold else -threshold
                    }
                    return true
                }
                if (remoteMouseGesture) {
                    if (!remotePressSent && (abs(event.x - remoteDownX) > touchSlop || abs(event.y - remoteDownY) > touchSlop)) {
                        sendRemoteMouse(MOUSE_PRESS, MOUSE_LEFT, remoteDownX, remoteDownY, true)
                        remotePressSent = true
                    }
                    if (remotePressSent) sendRemoteMouse(MOUSE_MOTION, MOUSE_LEFT, event.x, event.y, true)
                    return true
                }
                if (scaleDetector.isInProgress || scaleGesture) return true
                velocityTracker?.addMovement(event)
                val distance = event.y - lastTouchY
                if (!dragging && abs(event.y - downY) > touchSlop) dragging = true
                if (dragging) scrollByPixels(distance)
                lastTouchY = event.y
                return true
            }
            MotionEvent.ACTION_UP -> {
                cancelPendingLongPress()
                if (selectionActive) {
                    selectionActive = false
                    draggedHandle = HANDLE_NONE
                    updateSelectionAutoScroll(height / 2f)
                    startActionMode(selectionActions, ActionMode.TYPE_FLOATING)
                    refresh()
                    endTouch()
                    return true
                }
                if (remoteTwoFingerGesture) {
                    remoteTwoFingerGesture = false
                    endTouch()
                    return true
                }
                if (remoteMouseGesture) {
                    val tapped = !remotePressSent
                    if (tapped) sendRemoteMouse(MOUSE_PRESS, MOUSE_LEFT, event.x, event.y, true)
                    sendRemoteMouse(MOUSE_RELEASE, MOUSE_LEFT, event.x, event.y, false)
                    remoteMouseGesture = false
                    remotePressSent = false
                    if (tapped) performClick()
                    endTouch()
                    return true
                }
                velocityTracker?.addMovement(event)
                if (scaleGesture) {
                    // A pinch must not also focus the keyboard or start a fling.
                } else if (dragging) {
                    velocityTracker?.computeCurrentVelocity(1000, maximumFlingVelocity.toFloat())
                    val velocity = velocityTracker?.yVelocity?.toInt() ?: 0
                    if (abs(velocity) >= minimumFlingVelocity) {
                        lastFlingY = 0
                        scroller.fling(0, 0, 0, velocity, 0, 0, Int.MIN_VALUE, Int.MAX_VALUE)
                        postInvalidateOnAnimation()
                    }
                } else if (!snapshot.isAtBottom && liveButton.contains(event.x, event.y)) {
                    terminal.scrollToBottom()
                    refresh()
                } else if (onLinkTap(cellColumn(event.x), cellRow(event.y))) {
                    // The link handler owns this tap.
                } else {
                    performClick()
                }
                endTouch()
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                cancelPendingLongPress()
                if (remoteMouseGesture && remotePressSent) {
                    sendRemoteMouse(MOUSE_RELEASE, MOUSE_LEFT, event.x, event.y, false)
                }
                remoteMouseGesture = false
                remotePressSent = false
                remoteTwoFingerGesture = false
                selectionActive = false
                draggedHandle = HANDLE_NONE
                updateSelectionAutoScroll(height / 2f)
                endTouch()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (!isEnabled || !isMouseTracking() || event.source and InputDevice.SOURCE_CLASS_POINTER == 0) {
            return super.onGenericMotionEvent(event)
        }
        pointerMetaState = event.metaState
        when (event.actionMasked) {
            MotionEvent.ACTION_SCROLL -> {
                val vertical = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                if (vertical != 0f) {
                    sendRemoteMouse(
                        MOUSE_PRESS,
                        if (vertical > 0) MOUSE_WHEEL_UP else MOUSE_WHEEL_DOWN,
                        event.x,
                        event.y,
                        false,
                    )
                    return true
                }
            }
            MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.ACTION_BUTTON_RELEASE -> {
                val button = when (event.actionButton) {
                    MotionEvent.BUTTON_SECONDARY, MotionEvent.BUTTON_STYLUS_PRIMARY -> MOUSE_RIGHT
                    MotionEvent.BUTTON_TERTIARY, MotionEvent.BUTTON_STYLUS_SECONDARY -> MOUSE_MIDDLE
                    else -> MOUSE_LEFT
                }
                val pressed = event.actionMasked == MotionEvent.ACTION_BUTTON_PRESS
                sendRemoteMouse(if (pressed) MOUSE_PRESS else MOUSE_RELEASE, button, event.x, event.y, pressed)
                return true
            }
            MotionEvent.ACTION_HOVER_MOVE -> {
                val button = when {
                    event.buttonState and MotionEvent.BUTTON_SECONDARY != 0 -> MOUSE_RIGHT
                    event.buttonState and MotionEvent.BUTTON_TERTIARY != 0 -> MOUSE_MIDDLE
                    else -> MOUSE_LEFT
                }
                sendRemoteMouse(MOUSE_MOTION, button, event.x, event.y, event.buttonState != 0)
                return true
            }
        }
        return super.onGenericMotionEvent(event)
    }

    private val selectionActions = object : ActionMode.Callback {
        override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
            menu.add("Copy").setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            menu.add("Clear")
            return true
        }

        override fun onPrepareActionMode(mode: ActionMode, menu: Menu) = false

        override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
            when (item.title) {
                "Copy" -> onSelectionFinished()
                "Clear" -> Unit
                else -> return false
            }
            terminal.clearSelection()
            selectionVisible = false
            refresh()
            mode.finish()
            return true
        }

        override fun onDestroyActionMode(mode: ActionMode) = Unit
    }

    private fun updateSelectionAutoScroll(y: Float) {
        val direction = when {
            y < 0f -> -1
            y > height -> 1
            else -> 0
        }
        if (direction == selectionEdgeDirection) return
        removeCallbacks(selectionAutoScroll)
        selectionEdgeDirection = direction
        if (direction != 0) post(selectionAutoScroll)
    }

    private fun selectionHandleAt(x: Float, y: Float): Int {
        val radius = 28f * resources.displayMetrics.density
        val startDistance = if (selectionStartVisible) {
            Math.hypot((x - selectionStartX).toDouble(), (y - selectionStartY).toDouble())
        } else Double.MAX_VALUE
        val endDistance = if (selectionEndVisible) {
            Math.hypot((x - selectionEndX).toDouble(), (y - selectionEndY).toDouble())
        } else Double.MAX_VALUE
        return when {
            startDistance <= radius && startDistance <= endDistance -> HANDLE_START
            endDistance <= radius -> HANDLE_END
            else -> HANDLE_NONE
        }
    }

    private fun drawSelectionHandles(canvas: Canvas) {
        if (!selectionVisible) return
        paint.color = 0xff8be9b3.toInt()
        paint.style = Paint.Style.FILL
        val radius = 5f * resources.displayMetrics.density
        if (selectionStartVisible) canvas.drawCircle(selectionStartX, selectionStartY, radius, paint)
        if (selectionEndVisible) canvas.drawCircle(selectionEndX, selectionEndY, radius, paint)
    }

    private fun sendRemoteMouse(action: Int, button: Int, x: Float, y: Float, pressed: Boolean) {
        onMouseEvent(
            action, button, x, y, width, height,
            cellWidth.toInt().coerceAtLeast(1), cellHeight.toInt().coerceAtLeast(1), pressed,
            pointerMetaState,
        )
    }

    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        onTerminalFocusChanged(hasWindowFocus)
    }

    private fun pointerAverageY(event: MotionEvent): Float =
        (0 until event.pointerCount).sumOf { event.getY(it).toDouble() }.toFloat() / event.pointerCount

    private fun cellColumn(x: Float) = floor(x / cellWidth).toInt().coerceIn(0, snapshot.columns - 1)

    private fun cellRow(y: Float) = floor(y / cellHeight).toInt().coerceIn(0, snapshot.rows - 1)

    private fun cancelPendingLongPress() {
        pendingLongPress?.let(::removeCallbacks)
        pendingLongPress = null
    }

    override fun performClick(): Boolean {
        super.performClick()
        if (!acceptsInput) return true
        requestFocus()
        context.getSystemService(InputMethodManager::class.java)
            ?.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
        return true
    }

    override fun computeScroll() {
        if (!scroller.computeScrollOffset()) return
        val y = scroller.currY
        scrollByPixels((y - lastFlingY).toFloat())
        lastFlingY = y
        postInvalidateOnAnimation()
    }

    private fun scrollByPixels(delta: Float) {
        scrollPixels += delta
        val rows = (scrollPixels / cellHeight).toInt()
        if (rows == 0) return
        scrollPixels -= rows * cellHeight
        terminal.scrollRows(-rows)
        refresh()
    }

    private fun endTouch() {
        parent?.requestDisallowInterceptTouchEvent(false)
        velocityTracker?.recycle()
        velocityTracker = null
    }

    private fun updateFontMetrics() {
        terminalTextSize = sp(terminalTextSizeSp)
        paint.textSize = terminalTextSize
        paint.typeface = regularTypeface
        cellWidth = paint.measureText("M")
        cellHeight = paint.fontMetrics.run { descent - ascent + leading }
        baselineOffset = -paint.fontMetrics.ascent
        scrollPixels = 0f
        invalidateRowCaches()
    }

    private fun drawScrollPosition(canvas: Canvas) {
        if (snapshot.isAtBottom) {
            liveButton.setEmpty()
            return
        }
        val density = resources.displayMetrics.density
        val label = "↓ Live"
        paint.textSize = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP, 13f, resources.displayMetrics,
        )
        paint.typeface = boldTypeface
        val horizontalPadding = 12f * density
        val buttonHeight = 36f * density
        val buttonWidth = paint.measureText(label) + horizontalPadding * 2
        liveButton.set(width - buttonWidth - 12f * density, height - buttonHeight - 12f * density,
            width - 12f * density, height - 12f * density)
        paint.color = 0xee25302b.toInt()
        paint.style = Paint.Style.FILL
        canvas.drawRoundRect(liveButton, buttonHeight / 2, buttonHeight / 2, paint)
        paint.color = 0xff8be9b3.toInt()
        val textY = liveButton.centerY() - (paint.ascent() + paint.descent()) / 2
        canvas.drawText(label, liveButton.left + horizontalPadding, textY, paint)
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = TextView::class.java.name
        info.isFocusable = true
        info.contentDescription = null
        if (snapshot.passwordInput) {
            info.isPassword = true
            info.text = null
            info.contentDescription = "Terminal password input"
            return
        }
        val text = visibleAccessibilityText()
        info.text = text
        val canScrollBackward = snapshot.scrollOffset > 0
        val canScrollForward = !snapshot.isAtBottom
        info.isScrollable = canScrollBackward || canScrollForward
        if (canScrollBackward) info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD)
        if (canScrollForward) info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD)
        if (text.isNotBlank()) {
            info.addAction(AccessibilityNodeInfo.AccessibilityAction(
                AccessibilityNodeInfo.ACTION_COPY,
                "Copy visible terminal text",
            ))
        }
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(ACTION_PREVIOUS_PROMPT, "Previous prompt"))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(ACTION_NEXT_PROMPT, "Next prompt"))
        info.addAction(AccessibilityNodeInfo.AccessibilityAction(ACTION_COPY_OUTPUT, "Copy latest command output"))
    }

    override fun onInitializeAccessibilityEvent(event: AccessibilityEvent) {
        super.onInitializeAccessibilityEvent(event)
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
            event.contentChangeTypes = AccessibilityEvent.CONTENT_CHANGE_TYPE_TEXT
        }
    }

    override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean {
        if (snapshot.passwordInput) return super.performAccessibilityAction(action, arguments)
        val page = max(1, snapshot.scrollVisible - 1)
        when (action) {
            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD -> terminal.scrollRows(-page)
            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD -> terminal.scrollRows(page)
            AccessibilityNodeInfo.ACTION_COPY -> {
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(
                    ClipData.newPlainText("Visible terminal", visibleAccessibilityText()),
                )
                return true
            }
            ACTION_PREVIOUS_PROMPT -> {
                if (!terminal.jumpPrompt(-1)) return false
            }
            ACTION_NEXT_PROMPT -> {
                if (!terminal.jumpPrompt(1)) return false
            }
            ACTION_COPY_OUTPUT -> {
                if (!terminal.selectLatestOutput()) return false
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(
                    ClipData.newPlainText("Latest command output", terminal.selectedText()),
                )
            }
            else -> return super.performAccessibilityAction(action, arguments)
        }
        refresh()
        return true
    }

    private fun visibleAccessibilityText(): String {
        accessibilityText?.let { return it }
        return (0 until snapshot.rows).joinToString("\n") { row ->
            buildString {
                for (column in 0 until snapshot.columns) {
                    val cell = snapshot.cells[row * snapshot.columns + column]
                    append(if (cell.invisible || cell.text.isEmpty()) " " else cell.text)
                }
            }.trimEnd()
        }.trimEnd().let { text ->
            if (kittyFrame.placements.isEmpty()) text else "$text\n[Inline graphic]"
        }.also { accessibilityText = it }
    }

    fun setPasswordInput(enabled: Boolean) {
        if (passwordInput == enabled) return
        passwordInput = enabled
        context.getSystemService(InputMethodManager::class.java)?.restartInput(this)
    }

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = if (passwordInput) {
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
                InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        } else {
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_NORMAL or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
        }
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        return object : BaseInputConnection(this, false) {
            private var composingText = ""

            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                composingText = ""
                if (!text.isNullOrEmpty()) sendInput(text.toString())
                return true
            }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
                composingText = text?.toString().orEmpty()
                return true
            }

            override fun finishComposingText(): Boolean {
                flushComposition()
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (composingText.isNotEmpty()) {
                    composingText = composingText.dropLast(beforeLength.coerceAtLeast(1))
                    return true
                }
                repeat(beforeLength.coerceAtLeast(1)) { onSpecialKey("BACKSPACE") }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_DOWN) flushComposition()
                return onKeyEvent(event) || super.sendKeyEvent(event)
            }

            override fun performEditorAction(actionCode: Int): Boolean {
                flushComposition()
                onSpecialKey("ENTER")
                return true
            }

            private fun flushComposition() {
                if (composingText.isNotEmpty()) {
                    sendInput(composingText)
                    composingText = ""
                }
            }
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = onKeyEvent(event) || super.onKeyDown(keyCode, event)

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean = onKeyEvent(event) || super.onKeyUp(keyCode, event)

    private fun sendInput(text: String) {
        if (!snapshot.isAtBottom) {
            terminal.scrollToBottom()
            refresh()
        }
        onInput(text)
    }

    private fun drawCursor(canvas: Canvas, visibleColumns: Int, visibleRows: Int) {
        if (snapshot.cursorStyle == 0 || snapshot.cursorX !in 0 until visibleColumns || snapshot.cursorY !in 0 until visibleRows) return
        if (snapshot.cursorBlinking) {
            postInvalidateDelayed(CURSOR_BLINK_INTERVAL_MS)
            if ((SystemClock.uptimeMillis() / CURSOR_BLINK_INTERVAL_MS) % 2L != 0L) return
        }
        val cursorColumn = snapshot.cursorX - if (snapshot.cursorWideTail) 1 else 0
        val left = cursorColumn.coerceAtLeast(0) * cellWidth
        val top = snapshot.cursorY * cellHeight
        paint.color = snapshot.cursorColor
        paint.alpha = 220
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = resources.displayMetrics.density.coerceAtLeast(2f)
        when (snapshot.cursorStyle - 1) {
            0 -> canvas.drawLine(left, top, left, top + cellHeight, paint)
            2 -> canvas.drawLine(left, top + cellHeight - paint.strokeWidth, left + cellWidth, top + cellHeight - paint.strokeWidth, paint)
            else -> canvas.drawRect(left, top, left + cellWidth, top + cellHeight, paint)
        }
    }

    private fun resetPaint() {
        paint.alpha = 255
        paint.textSize = terminalTextSize
        paint.typeface = regularTypeface
        paint.textSkewX = 0f
        paint.style = Paint.Style.FILL
        paint.isUnderlineText = false
        paint.isStrikeThruText = false
        paint.pathEffect = null
    }

    private fun sp(value: Float): Float = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics,
    )

    companion object {
        private const val MIN_TEXT_SIZE_SP = 9f
        private const val MAX_TEXT_SIZE_SP = 30f
        private const val MOUSE_PRESS = 0
        private const val MOUSE_RELEASE = 1
        private const val MOUSE_MOTION = 2
        private const val MOUSE_LEFT = 1
        private const val MOUSE_MIDDLE = 2
        private const val MOUSE_RIGHT = 3
        private const val MOUSE_WHEEL_UP = 4
        private const val MOUSE_WHEEL_DOWN = 5
        private const val CURSOR_BLINK_INTERVAL_MS = 500L
        private const val SELECTION_SCROLL_INTERVAL_MS = 50L
        private const val ACCESSIBILITY_UPDATE_INTERVAL_MS = 150L
        private const val HANDLE_NONE = 0
        private const val HANDLE_START = 1
        private const val HANDLE_END = 2
        private const val ACTION_PREVIOUS_PROMPT = 0x01020001
        private const val ACTION_NEXT_PROMPT = 0x01020002
        private const val ACTION_COPY_OUTPUT = 0x01020003
        private const val KITTY_BELOW_BACKGROUND = Int.MIN_VALUE / 2
    }
}
