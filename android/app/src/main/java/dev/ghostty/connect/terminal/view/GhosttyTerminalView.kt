package dev.ghostty.connect.terminal.view

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
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
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.OverScroller
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.bridge.TerminalSnapshot
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.abs

class GhosttyTerminalView(
    context: Context,
    private val terminal: GhosttyTerminal,
) : View(context) {
    var onInput: (String) -> Unit = {}
    var onResize: (columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) -> Unit = { _, _, _, _ -> }
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
        snapshot = terminal.snapshot()
        invalidate()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
        resizeTerminal()
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
        drawCursor(canvas, visibleColumns, visibleRows)
        drawScrollPosition(canvas)
        resetPaint()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!isEnabled) return false
        scaleDetector.onTouchEvent(event)
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
                return true
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                scaleGesture = true
                dragging = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (scaleDetector.isInProgress || scaleGesture) return true
                velocityTracker?.addMovement(event)
                val distance = event.y - lastTouchY
                if (!dragging && abs(event.y - downY) > touchSlop) dragging = true
                if (dragging) scrollByPixels(distance)
                lastTouchY = event.y
                return true
            }
            MotionEvent.ACTION_UP -> {
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
                } else {
                    performClick()
                }
                endTouch()
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                endTouch()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun performClick(): Boolean {
        super.performClick()
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
                repeat(beforeLength.coerceAtLeast(1)) { sendInput("\u007f") }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_DOWN) flushComposition()
                return handleTerminalKey(event) || super.sendKeyEvent(event)
            }

            override fun performEditorAction(actionCode: Int): Boolean {
                flushComposition()
                sendInput("\r")
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

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = handleTerminalKey(event) || super.onKeyDown(keyCode, event)

    private fun handleTerminalKey(event: KeyEvent): Boolean {
        if (event.action != KeyEvent.ACTION_DOWN) return false
        val encoded = when (event.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> "\r"
            KeyEvent.KEYCODE_DEL -> "\u007f"
            KeyEvent.KEYCODE_FORWARD_DEL -> "\u001b[3~"
            KeyEvent.KEYCODE_TAB -> "\t"
            KeyEvent.KEYCODE_ESCAPE -> "\u001b"
            KeyEvent.KEYCODE_DPAD_UP -> "\u001b[A"
            KeyEvent.KEYCODE_DPAD_DOWN -> "\u001b[B"
            KeyEvent.KEYCODE_DPAD_RIGHT -> "\u001b[C"
            KeyEvent.KEYCODE_DPAD_LEFT -> "\u001b[D"
            KeyEvent.KEYCODE_MOVE_HOME -> "\u001b[H"
            KeyEvent.KEYCODE_MOVE_END -> "\u001b[F"
            else -> {
                if (event.isCtrlPressed && event.keyCode in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) {
                    ((event.keyCode - KeyEvent.KEYCODE_A) + 1).toChar().toString()
                } else {
                    event.unicodeChar.takeIf { it > 0 }?.let { String(Character.toChars(it)) }
                }
            }
        } ?: return false
        sendInput(encoded)
        return true
    }

    private fun sendInput(text: String) {
        if (!snapshot.isAtBottom) {
            terminal.scrollToBottom()
            refresh()
        }
        onInput(text)
    }

    private fun drawCursor(canvas: Canvas, visibleColumns: Int, visibleRows: Int) {
        if (snapshot.cursorStyle == 0 || snapshot.cursorX !in 0 until visibleColumns || snapshot.cursorY !in 0 until visibleRows) return
        val left = snapshot.cursorX * cellWidth
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
    }
}
