package dev.ghostty.connect.terminal

import android.view.KeyEvent
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    @Test
    fun mapsExtendedAndNumpadKeysWithoutCollapsingTheirIdentity() {
        assertEquals("NUMPAD_0", androidKeyName(KeyEvent.KEYCODE_NUMPAD_0))
        assertEquals("NUMPAD_ENTER", androidKeyName(KeyEvent.KEYCODE_NUMPAD_ENTER))
        assertEquals("NUMPAD_ADD", androidKeyName(KeyEvent.KEYCODE_NUMPAD_ADD))
        assertEquals("CAPS_LOCK", androidKeyName(KeyEvent.KEYCODE_CAPS_LOCK))
        assertEquals("PRINT_SCREEN", androidKeyName(KeyEvent.KEYCODE_SYSRQ))
        assertEquals("CONTEXT_MENU", androidKeyName(KeyEvent.KEYCODE_MENU))
    }

    @Test
    fun onlySingleAsciiImeCommitsConsumeOneShotModifiers() {
        assertTrue(isModifierEligibleImeCommit("a"))
        assertTrue(isModifierEligibleImeCommit("["))
        assertFalse(isModifierEligibleImeCommit("hello"))
        assertFalse(isModifierEligibleImeCommit("😀"))
        assertFalse(isModifierEligibleImeCommit("é"))
    }

    @Test
    fun dedicatedClipboardKeysAreHandledLocally() {
        assertEquals(HardwareClipboardAction.COPY, hardwareClipboardAction(KeyEvent.KEYCODE_COPY))
        assertEquals(HardwareClipboardAction.PASTE, hardwareClipboardAction(KeyEvent.KEYCODE_PASTE))
        assertNull(hardwareClipboardAction(KeyEvent.KEYCODE_C))
    }
}
