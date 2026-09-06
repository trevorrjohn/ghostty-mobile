package dev.ghostty.connect

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ActivitySessionRestoreTest {
    @Test
    fun activeServiceRestoresSelectedTerminalAmongMultipleSessions() {
        assertEquals("session-2", restoredSessionId(
            null, "session-2", savedTerminalVisible = true, serviceActive = true, freshLaunch = false,
        ))
    }

    @Test
    fun requestedSessionOverridesSavedSession() {
        assertEquals("notification-session", restoredSessionId(
            "notification-session",
            "saved-session",
            savedTerminalVisible = true,
            serviceActive = true,
            freshLaunch = true,
        ))
    }

    @Test
    fun processDeathDoesNotRestoreStaleSession() {
        assertNull(restoredSessionId(
            null, "stale-session", savedTerminalVisible = true, serviceActive = false, freshLaunch = false,
        ))
    }

    @Test
    fun hostScreenDoesNotRestoreSavedSession() {
        assertNull(restoredSessionId(
            null, "session-1", savedTerminalVisible = false, serviceActive = true, freshLaunch = false,
        ))
    }

    @Test
    fun recreationPrefersCurrentSavedSessionOverOriginalNotificationIntent() {
        assertEquals("session-b", restoredSessionId(
            "session-a", "session-b", savedTerminalVisible = true, serviceActive = true, freshLaunch = false,
        ))
    }

    @Test
    fun missingExplicitSessionDoesNotOpenAnotherSession() {
        assertNull(liveSessionToOpen("closed-session", listOf("other-session"), allowSingleSessionAutoOpen = true))
    }

    @Test
    fun initialLaunchMayOpenTheOnlyLiveSession() {
        assertEquals("session-1", liveSessionToOpen(null, listOf("session-1"), allowSingleSessionAutoOpen = true))
        assertNull(liveSessionToOpen(null, listOf("session-1", "session-2"), allowSingleSessionAutoOpen = true))
    }
}
