package dev.ghostty.connect.terminal

import dev.ghostty.connect.model.RetryBackoff
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Exercises the shared Zig core through the JNI entry points linked into the app. */
class SeanceCoreReconnectTest {
    @Test
    fun policyRunsFromTheLinkedCore() {
        val policy = ReconnectPolicy(true, 3, RetryBackoff.BALANCED)
        assertEquals(0L, policy.nextDelay(0))
        assertTrue(policy.beginAttempt(0))
        assertEquals(2_000L, policy.nextDelay(0))
        assertTrue(policy.beginAttempt(2_000))
        assertTrue(policy.beginAttempt(7_000))
        assertNull(policy.nextDelay(7_000))
        assertFalse(policy.beginAttempt(7_000))
        assertEquals(3, policy.attemptCount)
    }

    @Test
    fun pausedTimeDoesNotCountAgainstTheWindow() {
        val policy = ReconnectPolicy()
        assertTrue(policy.beginAttempt(0))
        policy.pause(1_000)
        val late = 1_000 + policy.retryWindowMs * 3
        assertTrue(policy.nextDelay(late) != null)
        policy.resume(late)
        assertNull(policy.nextDelay(late + policy.retryWindowMs + 1))
    }
}
