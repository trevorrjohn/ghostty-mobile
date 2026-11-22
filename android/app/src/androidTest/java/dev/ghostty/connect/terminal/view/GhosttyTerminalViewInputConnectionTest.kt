package dev.ghostty.connect.terminal.view

import android.content.Intent
import android.text.InputType
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.MainActivity
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GhosttyTerminalViewInputConnectionTest {
    @Test
    fun directTerminalInputAdvertisesNonLearningNonFullscreenTextEditor() = onMainThread {
        GhosttyTerminal().use { terminal ->
            val view = GhosttyTerminalView(context(), terminal)
            val editorInfo = EditorInfo()

            view.onCreateInputConnection(editorInfo)

            assertTrue(view.onCheckIsTextEditor())
            assertEquals(
                InputType.TYPE_CLASS_TEXT or
                    InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
                    InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS,
                editorInfo.inputType,
            )
            assertTrue(editorInfo.imeOptions and EditorInfo.IME_FLAG_NO_EXTRACT_UI != 0)
            assertTrue(editorInfo.imeOptions and EditorInfo.IME_FLAG_NO_FULLSCREEN != 0)
            assertTrue(editorInfo.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0)
        }
    }

    @Test
    fun inputConnectionSupportsNonZeroComposingRegionCommitCorrection() {
        val terminal = GhosttyTerminal()
        val input = mutableListOf<String>()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // The view drops input unless it is attached to a window.
        val activity = instrumentation.startActivitySync(
            Intent(instrumentation.targetContext, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as MainActivity
        try {
            onMainThread {
                val view = GhosttyTerminalView(activity, terminal)
                activity.addContentView(
                    view,
                    ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
                )
                view.onInput = input::add

                val connection = view.onCreateInputConnection(EditorInfo())
                assertTrue(connection.setComposingText("hello wrld", 1))
                assertTrue(connection.finishComposingText())
                assertTrue(connection.setComposingRegion(6, 10))
                assertTrue(connection.commitText("world", 1))
            }
            // The input buffer delivers text through a posted flush.
            instrumentation.waitForIdleSync()

            assertEquals(listOf("hello world"), input)
        } finally {
            activity.finish()
            terminal.close()
        }
    }

    /** Views create Handlers, so they need a Looper thread; rethrow failures so they report normally. */
    private fun onMainThread(block: () -> Unit) {
        var failure: Throwable? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try {
                block()
            } catch (error: Throwable) {
                failure = error
            }
        }
        failure?.let { throw it }
    }

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext
}
