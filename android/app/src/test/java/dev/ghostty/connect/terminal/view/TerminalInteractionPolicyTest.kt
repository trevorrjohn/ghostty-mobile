package dev.ghostty.connect.terminal.view

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalInteractionPolicyTest {
    @Test
    fun localSelectionSuppressesRemoteMouseTracking() {
        assertFalse(shouldRouteRemoteMouse(mouseTracking = true, localSelectionMode = true))
    }

    @Test
    fun remoteMouseResumesAfterLocalSelection() {
        assertTrue(shouldRouteRemoteMouse(mouseTracking = true, localSelectionMode = false))
        assertFalse(shouldRouteRemoteMouse(mouseTracking = false, localSelectionMode = false))
    }

    @Test
    fun enteringLocalSelectionDrainsEveryPressedRemoteButton() {
        val buttons = RemoteButtonState()
        buttons.press(1)
        buttons.press(2)

        val releases = buttons.drain()

        assertTrue(releases == listOf(1, 2))
        assertFalse(buttons.anyPressed)
    }
}
