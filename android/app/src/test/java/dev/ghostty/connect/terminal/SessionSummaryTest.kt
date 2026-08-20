package dev.ghostty.connect.terminal

import dev.ghostty.connect.model.Host
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class SessionSummaryTest {
    private val host = Host(id = "saved-host", hostname = "example.com", username = "ghost")

    @Test
    fun sessionIdentityIsIndependentFromHostIdentity() {
        val first = sessionSummary("session-1", host, "Connected")
        val second = sessionSummary("session-2", host, "Connected")

        assertNotEquals(first.sessionId, second.sessionId)
        assertEquals(first.hostId, second.hostId)
        assertEquals("ghost@example.com:22", first.destination)
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
            "session-2" to sessionSummary("session-2", host, "Connecting…"),
            "session-1" to sessionSummary("session-1", host, "Connected"),
        )

        assertEquals(listOf("session-2", "session-1"), sessions.values.map(SessionSummary::sessionId))
    }
}
