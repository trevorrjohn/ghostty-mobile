package dev.ghostty.connect.terminal.view

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.text.InputType
import android.util.TypedValue
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import dev.ghostty.connect.terminal.bridge.TerminalSnapshot
import kotlin.math.floor
import kotlin.math.max

class GhosttyTerminalView(
    context: Context,
    private val terminal: GhosttyTerminal,
) : View(context) {
    var onInput: (String) -> Unit = {}
    var onResize: (columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) -> Unit = { _, _, _, _ -> }
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Typeface.MONOSPACE
        textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 15f, resources.displayMetrics)
        isSubpixelText = true
    }
    private val boldTypeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    private val regularTypeface = Typeface.MONOSPACE
    private val cellWidth = paint.measureText("M")
    private val cellHeight = paint.fontMetrics.run { descent - ascent + leading }
    private val baselineOffset = -paint.fontMetrics.ascent
    private var snapshot: TerminalSnapshot = terminal.snapshot()

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        contentDescription = "Ghostty terminal rendering preview"
        setOnClickListener {
            requestFocus()
            context.getSystemService(InputMethodManager::class.java)?.showSoftInput(this, InputMethodManager.SHOW_IMPLICIT)
        }
    }

    fun refresh() {
        snapshot = terminal.snapshot()
        invalidate()
    }

    override fun onSizeChanged(width: Int, height: Int, oldWidth: Int, oldHeight: Int) {
        super.onSizeChanged(width, height, oldWidth, oldHeight)
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
        resetPaint()
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS or
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                if (!text.isNullOrEmpty()) onInput(text.toString())
                return true
            }

            override fun setComposingText(text: CharSequence?, newCursorPosition: Int): Boolean {
                // Terminal input has no local editable buffer. Commit IME composition as input.
                if (!text.isNullOrEmpty()) onInput(text.toString())
                return true
            }

            override fun finishComposingText(): Boolean = true

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength.coerceAtLeast(1)) { onInput("\u007f") }
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean = handleTerminalKey(event) || super.sendKeyEvent(event)
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
        onInput(encoded)
        return true
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
        paint.typeface = regularTypeface
        paint.textSkewX = 0f
        paint.style = Paint.Style.FILL
        paint.isUnderlineText = false
        paint.isStrikeThruText = false
    }
}
