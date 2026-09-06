package dev.ghostty.connect.terminal

import dev.ghostty.connect.model.Host
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionSummaryTest {
    private val host = Host(id = "saved-host", hostname = "example.com", username = "ghost")

    @Test
    fun sessionIdentityIsIndependentFromHostIdentity() {
        val first = sessionSummary("session-1", host, 100L, "Connected")
        val second = sessionSummary("session-2", host, 200L, "Connected")

        assertNotEquals(first.sessionId, second.sessionId)
        assertEquals(first.hostId, second.hostId)
        assertEquals("ghost@example.com:22", first.destination)
        assertEquals(100L, first.startedAtElapsedRealtime)
        assertNotEquals(first.shortId, second.shortId)
    }

    @Test
    fun generatedSessionIdsAreUniqueAndNotHostIds() {
        val first = SshSessionService.newSessionId()
        val second = SshSessionService.newSessionId()

        assertNotEquals(host.id, first)
        assertNotEquals(first, second)
    }

    @Test
    fun summariesPreserveLinkedSessionOrder() {
        val sessions = linkedMapOf(
            "session-2" to sessionSummary("session-2", host, 100L, "Connecting…"),
            "session-1" to sessionSummary("session-1", host, 200L, "Connected"),
        )

        assertEquals(listOf("session-2", "session-1"), sessions.values.map(SessionSummary::sessionId))
    }

    @Test
    fun displayIdUsesStableSessionSuffix() {
        assertEquals("89abcdef", sessionDisplayId("12345678-1234-1234-1234-678989abcdef"))
    }

    @Test
    fun promptsArePresentedOnlyForTheSelectedRuntimeSession() {
        assertTrue(shouldPresentSessionPrompt("session-2", "session-2"))
        assertFalse(shouldPresentSessionPrompt("session-1", "session-2"))
        assertFalse(shouldPresentSessionPrompt(null, "session-2"))
    }

    @Test fun nextSessionUsesStartOrderAndWraps() {
        val sessions = listOf(
            sessionSummary("later", host, 200L, "Connected"),
            sessionSummary("earlier", host, 100L, "Connected"),
        )

        assertEquals("later", nextSessionId("earlier", sessions))
        assertEquals("earlier", nextSessionId("later", sessions))
        assertEquals(null, nextSessionId("missing", sessions))
        assertEquals(null, nextSessionId("earlier", sessions.take(1)))
    }
}
