package dev.ghostty.connect.terminal.view

import android.view.MotionEvent
import org.junit.Assert.assertEquals
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
    fun stationaryHoldCanClaimRemoteMouseBeforePressIsSent() {
        assertTrue(canActivateHoldSwipe(false, false, false, false))
        assertFalse(canActivateHoldSwipe(true, false, false, false))
        assertFalse(canActivateHoldSwipe(false, true, false, false))
        assertFalse(canActivateHoldSwipe(false, false, true, false))
        assertFalse(canActivateHoldSwipe(false, false, false, true))
    }

    @Test
    fun enteringLocalSelectionDrainsEveryPressedRemoteButton() {
        val buttons = RemoteButtonState()
        buttons.press(1)
        buttons.press(2)

        val releases = buttons.drain()

        assertTrue(releases == listOf(RemoteButtonRelease(1, true), RemoteButtonRelease(2, false)))
        assertFalse(buttons.anyPressed)
    }

    @Test
    fun androidSecondaryAndTertiaryButtonsMatchGhosttyOrdering() {
        assertEquals(2, ghosttyMouseButton(MotionEvent.BUTTON_SECONDARY))
        assertEquals(3, ghosttyMouseButton(MotionEvent.BUTTON_TERTIARY))
        assertEquals(1, ghosttyMouseButton(MotionEvent.BUTTON_PRIMARY))
    }
}
