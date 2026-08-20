package dev.ghostty.connect.terminal.view

import android.content.Context
import android.graphics.Canvas
import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.text.InputType
import android.util.TypedValue
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.VelocityTracker
import android.view.ViewConfiguration
import android.os.SystemClock
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.OverScroller
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.bridge.KittyFrame
import dev.ghostty.connect.terminal.bridge.KittyImage
import dev.ghostty.connect.terminal.bridge.TerminalSnapshot
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.abs

class GhosttyTerminalView(
    context: Context,
    private val terminal: GhosttyTerminal,
) : View(context) {
    var onInput: (String) -> Unit = {}
    var acceptsInput = true
    var onSpecialKey: (String) -> Unit = {}
    var onKeyEvent: (KeyEvent) -> Boolean = { false }
    var isMouseTracking: () -> Boolean = { false }
    var onMouseEvent: (
        action: Int, button: Int, x: Float, y: Float,
        width: Int, height: Int, cellWidth: Int, cellHeight: Int, anyPressed: Boolean,
    ) -> Unit = { _, _, _, _, _, _, _, _, _ -> }
    var onSelectionStart: (column: Int, row: Int) -> Boolean = { _, _ -> false }
    var onSelectionUpdate: (column: Int, row: Int) -> Unit = { _, _ -> }
    var onSelectionFinished: () -> Unit = {}
    var onMetadataChanged: (title: String, pwd: String, atPrompt: Boolean) -> Unit = { _, _, _ -> }
    var onLinkTap: (column: Int, row: Int) -> Boolean = { _, _ -> false }
    var onResize: (columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) -> Unit = { _, _, _, _ -> }
    var onScrollPositionChanged: (isAtBottom: Boolean) -> Unit = {}
    private var terminalTextSizeSp = 15f
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
    private var selectionActive = false
    private var pendingLongPress: Runnable? = null
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
                updateFontMetrics()
                resizeTerminal()
                return true
            }
        },
    )

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        contentDescription = "Ghostty terminal"
    }

    fun refresh() {
        val wasAtBottom = snapshot.isAtBottom
        snapshot = terminal.snapshot()
        kittyFrame = terminal.kittyFrame()
        updateKittyBitmaps()
        onMetadataChanged(snapshot.title, snapshot.pwd, snapshot.cursorAtPrompt)
        if (snapshot.isAtBottom != wasAtBottom) onScrollPositionChanged(snapshot.isAtBottom)
        invalidate()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        resizeTerminal()
    }

    override fun onDetachedFromWindow() {
        kittyBitmaps.values.forEach { it.second.recycle() }
        kittyBitmaps.clear()
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
        for (row in 0 until visibleRows) {
            val top = row * cellHeight
            for (column in 0 until visibleColumns) {
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
        drawKitty(canvas) { it in KITTY_BELOW_BACKGROUND until 0 }
        for (row in 0 until visibleRows) {
            val top = row * cellHeight
            for (column in 0 until visibleColumns) {
                val cell = snapshot.cells[row * snapshot.columns + column]
                val left = column * cellWidth
                if (!cell.invisible && cell.text.isNotEmpty()) {
                    paint.color = cell.foreground
                    paint.alpha = if (cell.faint) 150 else 255
                    paint.typeface = if (cell.bold) boldTypeface else regularTypeface
                    paint.textSkewX = if (cell.italic) -0.2f else 0f
                    paint.style = Paint.Style.FILL
                    paint.isUnderlineText = cell.underline
                    paint.isStrikeThruText = cell.strikeThrough
                    canvas.drawText(cell.text, left, top + baselineOffset, paint)
                }
            }
        }
        drawKitty(canvas) { it >= 0 }
        drawCursor(canvas, visibleColumns, visibleRows)
        drawScrollPosition(canvas)
        resetPaint()
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
                pendingLongPress = Runnable {
                    if (!dragging && !scaleGesture) {
                        remoteMouseGesture = false
                        selectionActive = onSelectionStart(cellColumn(remoteDownX), cellRow(remoteDownY))
                        if (selectionActive) refresh()
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
                    onSelectionUpdate(cellColumn(event.x), cellRow(event.y))
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
                    onSelectionFinished()
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
                    if (!remotePressSent) sendRemoteMouse(MOUSE_PRESS, MOUSE_LEFT, event.x, event.y, true)
                    sendRemoteMouse(MOUSE_RELEASE, MOUSE_LEFT, event.x, event.y, false)
                    remoteMouseGesture = false
                    remotePressSent = false
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
                endTouch()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun sendRemoteMouse(action: Int, button: Int, x: Float, y: Float, pressed: Boolean) {
        onMouseEvent(
            action, button, x, y, width, height,
            cellWidth.toInt().coerceAtLeast(1), cellHeight.toInt().coerceAtLeast(1), pressed,
        )
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

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_NORMAL or
            InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
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
        private const val MOUSE_WHEEL_UP = 4
        private const val MOUSE_WHEEL_DOWN = 5
        private const val CURSOR_BLINK_INTERVAL_MS = 500L
        private const val KITTY_BELOW_BACKGROUND = Int.MIN_VALUE / 2
    }
}
