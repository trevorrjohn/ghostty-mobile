package dev.ghostty.connect

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalWindowPolicyTest {
    @Test
    fun `immersive mode requires a full window without a caption bar`() {
        assertTrue(usesTerminalImmersiveInsets(requested = true, inMultiWindowMode = false, captionBarVisible = false))
        assertFalse(usesTerminalImmersiveInsets(requested = false, inMultiWindowMode = false, captionBarVisible = false))
        assertFalse(usesTerminalImmersiveInsets(requested = true, inMultiWindowMode = true, captionBarVisible = false))
        assertFalse(usesTerminalImmersiveInsets(requested = true, inMultiWindowMode = false, captionBarVisible = true))
    }

    @Test
    fun `immersive content retains cutout and ime safety`() {
        assertEquals(
            TerminalWindowInsets(left = 5, top = 18, right = 7, bottom = 220),
            terminalContentInsets(
                immersive = true,
                systemBars = TerminalWindowInsets(10, 40, 12, 30),
                ime = TerminalWindowInsets(0, 0, 0, 220),
                displayCutout = TerminalWindowInsets(5, 18, 7, 0),
            ),
        )
    }

    @Test
    fun `landscape immersive content keeps side cutouts when keyboard closes`() {
        assertEquals(
            TerminalWindowInsets(left = 80, top = 0, right = 24, bottom = 0),
            terminalContentInsets(
                immersive = true,
                systemBars = TerminalWindowInsets(0, 40, 48, 30),
                ime = TerminalWindowInsets(0, 0, 0, 0),
                displayCutout = TerminalWindowInsets(80, 0, 24, 0),
            ),
        )
    }

    @Test
    fun `caption bar remains above terminal content in a window`() {
        assertEquals(
            TerminalWindowInsets(left = 0, top = 64, right = 0, bottom = 30),
            terminalContentInsets(
                immersive = usesTerminalImmersiveInsets(true, false, true),
                systemBars = TerminalWindowInsets(0, 64, 0, 30),
                ime = TerminalWindowInsets(0, 0, 0, 0),
                displayCutout = TerminalWindowInsets(0, 40, 0, 0),
            ),
        )
    }

    @Test
    fun `windowed content retains system bars and ime`() {
        assertEquals(
            TerminalWindowInsets(left = 24, top = 40, right = 28, bottom = 220),
            terminalContentInsets(
                immersive = false,
                systemBars = TerminalWindowInsets(10, 40, 12, 30),
                ime = TerminalWindowInsets(0, 0, 0, 220),
                displayCutout = TerminalWindowInsets(24, 18, 28, 0),
            ),
        )
    }
}
