package dev.ghostty.connect.terminal

import android.graphics.Bitmap
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.text.TextRunShaper
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream

@RunWith(AndroidJUnit4::class)
class GhosttyTerminalIntegrationTest {
    @Test
    fun focusReportsOnlyWhenApplicationEnablesMode() {
        GhosttyTerminal().use { terminal ->
            assertTrue(terminal.encodeFocus(true).isEmpty())
            terminal.write("\u001b[?1004h")

            assertArrayEquals("\u001b[I".toByteArray(), terminal.encodeFocus(true))
            assertArrayEquals("\u001b[O".toByteArray(), terminal.encodeFocus(false))
        }
    }

    @Test
    fun searchSelectsAcrossSoftWrap() {
        GhosttyTerminal(columns = 5, rows = 3).use { terminal ->
            terminal.resize(5, 3, 10, 20)
            terminal.write("abcdefgh")

            assertTrue(terminal.search("def", 1))
            assertEquals("def", terminal.selectedText())
        }
    }

    @Test
    fun savedStateRestoresTerminalText() {
        val state = GhosttyTerminal(columns = 10, rows = 3).use { terminal ->
            terminal.write("persisted")
            terminal.encodeState()
        }

        GhosttyTerminal(restoredState = state).use { restored ->
            val text = restored.snapshot().cells.joinToString("") { it.text }
            assertTrue(text.contains("persisted"))
        }
    }

    @Test
    fun translatedItermImageCreatesKittyPlacement() {
        val jpeg = ByteArrayOutputStream().use { output ->
            Bitmap.createBitmap(2, 2, Bitmap.Config.ARGB_8888).let { bitmap ->
                try {
                    assertTrue(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, output))
                    output.toByteArray()
                } finally {
                    bitmap.recycle()
                }
            }
        }
        val commands = ItermImageTranslator.translate(
            ItermInlineImage(mapOf("inline" to "1", "width" to "2"), jpeg),
            TerminalPixelMetrics(80, 24, 800, 480),
        )

        GhosttyTerminal().use { terminal ->
            commands.forEach(terminal::write)
            val frame = terminal.kittyFrame()
            assertTrue(frame.images.isNotEmpty())
            assertTrue(frame.placements.isNotEmpty())
        }
    }

    @Test
    fun snapshotPreservesDirtyRowsForRenderCaching() {
        GhosttyTerminal(columns = 10, rows = 3).use { terminal ->
            terminal.snapshot()
            terminal.write("dirty")

            val snapshot = terminal.snapshot()
            assertTrue(snapshot.dirtyRows.isNotEmpty())
            assertTrue(snapshot.dirtyRows.all { it in 0 until snapshot.rows })
        }
    }

    @Test
    fun androidShaperProducesFallbackGlyphRuns() {
        val text = "fi e\u0301 \ud83d\ude80"
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.MONOSPACE
            textSize = 32f
        }

        val glyphs = TextRunShaper.shapeTextRun(text, 0, text.length, 0, text.length, 0f, 32f, false, paint)

        assertTrue(glyphs.glyphCount() > 0)
        assertTrue(glyphs.advance > 0f)
        assertTrue((0 until glyphs.glyphCount()).map(glyphs::getFont).distinct().isNotEmpty())
    }
}
