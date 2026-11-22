package dev.ghostty.connect.terminal.view

import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.CheckBox
import dev.ghostty.connect.MainActivity
import android.content.Context
import android.os.SystemClock
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GhosttyTerminalViewScrollTest {
    @Test
    fun edgeSwipeUsesLiveDirectionAndSensitivitySettings() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as MainActivity
        instrumentation.runOnMainSync {
            val context = activity
            val preferences = context.getSharedPreferences("app_settings", Context.MODE_PRIVATE)
            val original = preferences.all
            try {
                MainActivity::class.java.getDeclaredMethod("showKeyboardSettings").apply {
                    isAccessible = true
                }.invoke(activity)
                fun findToggle(view: View): CheckBox? {
                    if (view is CheckBox && view.text.toString() == "Reverse scroll direction") return view
                    if (view is ViewGroup) for (index in 0 until view.childCount) {
                        findToggle(view.getChildAt(index))?.let { return it }
                    }
                    return null
                }
                val toggle = requireNotNull(findToggle(activity.window.decorView))
                GhosttyTerminal().use { terminal ->
                    terminal.write("\u001b[?1000h\u001b[?1006h")
                    val view = GhosttyTerminalView(context, terminal)
                    view.onResize = { columns, rows, width, height ->
                        terminal.resize(columns, rows, (width / columns).coerceAtLeast(1), (height / rows).coerceAtLeast(1))
                    }
                    view.layout(0, 0, 600, 1000)
                    view.isMouseTracking = terminal::isMouseTracking
                    val buttons = mutableListOf<Int>()
                    val encoded = mutableListOf<String>()
                    view.onMouseEvent = { action, button, x, y, width, height, cellWidth, cellHeight, pressed, mods ->
                        buttons.add(button)
                        encoded.add(String(terminal.encodeMouse(action, button, x, y, mods, width, height, cellWidth, cellHeight, pressed)))
                    }

                    fun swipe(reverse: Boolean, sensitivity: Float): List<Int> {
                        if (toggle.isChecked != reverse) toggle.performClick()
                        assertEquals(reverse, preferences.getBoolean("reverse_scroll_direction", false))
                        preferences.edit().putFloat("scroll_sensitivity", sensitivity).commit()
                        buttons.clear()
                        encoded.clear()
                        val time = SystemClock.uptimeMillis()
                        for ((action, y, offset) in listOf(
                            Triple(MotionEvent.ACTION_DOWN, 500f, 0L),
                            Triple(MotionEvent.ACTION_MOVE, 100f, 16L),
                            Triple(MotionEvent.ACTION_UP, 100f, 32L),
                        )) {
                            val event = MotionEvent.obtain(time, time + offset, action, 1f, y, 0)
                            try { view.onTouchEvent(event) } finally { event.recycle() }
                        }
                        assertTrue(encoded.isNotEmpty())
                        assertTrue(encoded.all { it.startsWith(if (reverse) "\u001b[<64;" else "\u001b[<65;") })
                        return buttons.toList()
                    }

                    val normal = swipe(false, 1f)
                    val reversed = swipe(true, 1f)
                    val fast = swipe(true, 4f)
                    assertTrue(normal.isNotEmpty())
                    assertTrue(normal.all { it == 5 })
                    assertTrue(reversed.isNotEmpty())
                    assertTrue(reversed.all { it == 4 })
                    assertTrue(fast.size > reversed.size * 3)
                    assertEquals(normal.size, reversed.size)
                    // IME dismissal grows the terminal; direction must survive both resize
                    // and a remote application's switch out of mouse tracking during redraw.
                    view.layout(0, 0, 600, 600)
                    assertTrue(swipe(true, 1f).all { it == 4 })
                    view.layout(0, 0, 600, 1000)
                    assertTrue(swipe(true, 1f).all { it == 4 })
                    terminal.write("\u001b[?1000l\u001b[?1006l")
                    terminal.write((1..300).joinToString("\r\n") { "Line $it" })
                    fun localSwipe(reverse: Boolean): Int {
                        if (toggle.isChecked != reverse) toggle.performClick()
                        preferences.edit().putFloat("scroll_sensitivity", 1f).commit()
                        terminal.scrollToBottom()
                        terminal.scrollRows(-100)
                        val before = terminal.snapshot().scrollOffset
                        val time = SystemClock.uptimeMillis()
                        for ((action, y, offset) in listOf(
                            Triple(MotionEvent.ACTION_DOWN, 500f, 0L),
                            Triple(MotionEvent.ACTION_MOVE, 100f, 16L),
                            Triple(MotionEvent.ACTION_CANCEL, 100f, 32L),
                        )) {
                            val event = MotionEvent.obtain(time, time + offset, action, 1f, y, 0)
                            try { view.onTouchEvent(event) } finally { event.recycle() }
                        }
                        return terminal.snapshot().scrollOffset - before
                    }
                    assertTrue("Normal swipe should move toward newer output", localSwipe(false) > 0)
                    assertTrue("Reversed swipe should move toward older output", localSwipe(true) < 0)
                }
            } finally {
                val editor = preferences.edit()
                for (key in listOf("reverse_scroll_direction", "scroll_sensitivity")) {
                    when (val value = original[key]) {
                        is Boolean -> editor.putBoolean(key, value)
                        is Float -> editor.putFloat(key, value)
                        else -> editor.remove(key)
                    }
                }
                editor.commit()
                activity.finish()
            }
        }
    }

    @Test
    fun dragSendsArrowsOnAlternateScreenAndScrollsLocallyOtherwise() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val preferences = context.getSharedPreferences("app_settings", Context.MODE_PRIVATE)
        val original = preferences.all
        instrumentation.runOnMainSync {
            try {
                preferences.edit()
                    .putBoolean("reverse_scroll_direction", false)
                    .putFloat("scroll_sensitivity", 1f)
                    .commit()
                GhosttyTerminal().use { terminal ->
                    val view = GhosttyTerminalView(context, terminal)
                    view.layout(0, 0, 600, 1000)
                    val sent = java.io.ByteArrayOutputStream()
                    view.onScrollInput = { sent.write(it) }

                    fun drag(fromY: Float, toY: Float) {
                        val time = SystemClock.uptimeMillis()
                        for ((action, y, offset) in listOf(
                            Triple(MotionEvent.ACTION_DOWN, fromY, 0L),
                            Triple(MotionEvent.ACTION_MOVE, toY, 16L),
                            Triple(MotionEvent.ACTION_CANCEL, toY, 32L),
                        )) {
                            val event = MotionEvent.obtain(time, time + offset, action, 300f, y, 0)
                            try { view.onTouchEvent(event) } finally { event.recycle() }
                        }
                    }

                    // A full-screen program that scrolls with arrows (alternate-scroll mode).
                    terminal.write("\u001b[?1049h")
                    drag(500f, 100f)
                    val down = String(sent.toByteArray())
                    assertTrue("Dragging up should send Down arrows", down.isNotEmpty() && down.split("\u001b[B").all { it.isEmpty() })
                    sent.reset()
                    drag(100f, 500f)
                    val up = String(sent.toByteArray())
                    assertTrue("Dragging down should send Up arrows", up.isNotEmpty() && up.split("\u001b[A").all { it.isEmpty() })

                    // The primary screen keeps scrolling its own scrollback.
                    terminal.write("\u001b[?1049l")
                    terminal.write((1..300).joinToString("\r\n") { "Line $it" })
                    terminal.scrollRows(-100)
                    val before = terminal.snapshot().scrollOffset
                    sent.reset()
                    drag(500f, 100f)
                    assertTrue(sent.size() == 0)
                    assertTrue(terminal.snapshot().scrollOffset > before)
                }
            } finally {
                val editor = preferences.edit()
                for (key in listOf("reverse_scroll_direction", "scroll_sensitivity")) {
                    when (val value = original[key]) {
                        is Boolean -> editor.putBoolean(key, value)
                        is Float -> editor.putFloat(key, value)
                        else -> editor.remove(key)
                    }
                }
                editor.commit()
            }
        }
    }
}
