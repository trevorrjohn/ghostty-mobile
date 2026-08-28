package dev.ghostty.connect.terminal

import android.view.KeyEvent
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HardwareKeyActionTest {
    @Test
    fun mapsPressRepeatAndReleaseActions() {
        assertEquals(GhosttyTerminal.KEY_ACTION_PRESS, ghosttyKeyAction(KeyEvent.ACTION_DOWN, 0))
        assertEquals(GhosttyTerminal.KEY_ACTION_REPEAT, ghosttyKeyAction(KeyEvent.ACTION_DOWN, 1))
        assertEquals(GhosttyTerminal.KEY_ACTION_RELEASE, ghosttyKeyAction(KeyEvent.ACTION_UP, 0))
        assertNull(ghosttyKeyAction(99, 0))
    }

    @Test
    fun heldKeyKeepsInitialModifiersThroughRepeatAndRelease() {
        val state = HardwareKeyModifierState()

        assertEquals(7, state.modifiers(24, GhosttyTerminal.KEY_ACTION_PRESS, 7))
        assertEquals(7, state.modifiers(24, GhosttyTerminal.KEY_ACTION_REPEAT, 0))
        assertEquals(7, state.modifiers(24, GhosttyTerminal.KEY_ACTION_RELEASE, 0))
        assertNull(state.modifiers(24, GhosttyTerminal.KEY_ACTION_REPEAT, 0))
    }
}
