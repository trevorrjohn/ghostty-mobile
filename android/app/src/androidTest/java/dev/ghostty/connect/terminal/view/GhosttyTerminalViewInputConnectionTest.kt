package dev.ghostty.connect.terminal.view

import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GhosttyTerminalViewInputConnectionTest {
    @Test
    fun directTerminalInputAdvertisesNonLearningNonFullscreenTextEditor() {
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
        GhosttyTerminal().use { terminal ->
            val view = GhosttyTerminalView(context(), terminal)
            val input = mutableListOf<String>()
            view.onInput = input::add

            val connection = view.onCreateInputConnection(EditorInfo())
            assertTrue(connection.setComposingText("hello wrld", 1))
            assertTrue(connection.finishComposingText())
            assertTrue(connection.setComposingRegion(6, 10))
            assertTrue(connection.commitText("world", 1))

            assertEquals(listOf("hello world"), input)
        }
    }

    private fun context() = InstrumentationRegistry.getInstrumentation().targetContext
}
