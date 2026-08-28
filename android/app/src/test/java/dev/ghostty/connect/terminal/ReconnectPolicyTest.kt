package dev.ghostty.connect.terminal

import com.hierynomus.sshj.common.KeyDecryptionFailedException
import dev.ghostty.connect.model.RetryBackoff
import java.io.EOFException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import net.schmizz.sshj.common.DisconnectReason
import net.schmizz.sshj.transport.TransportException
import net.schmizz.sshj.userauth.UserAuthException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReconnectPolicyTest {
    @Test
    fun retriesUseBoundedDeterministicBackoff() {
        val policy = ReconnectPolicy()
        var now = 1_000L

        ReconnectPolicy.BALANCED_DELAYS_MS.take(5).forEach { delay ->
            assertEquals(delay, policy.nextDelay(now))
            now += delay
            assertTrue(policy.beginAttempt(now))
        }
        assertNull(policy.nextDelay(now))
        assertFalse(policy.beginAttempt(now))
    }

    @Test
    fun retryWindowDoesNotResetWithoutSuccessfulConnection() {
        val policy = ReconnectPolicy()
        assertTrue(policy.beginAttempt(1_000L))
        assertNull(policy.nextDelay(1_000L + policy.retryWindowMs + 1))
    }

    @Test
    fun offlineTimeDoesNotConsumeRetryWindow() {
        val policy = ReconnectPolicy()
        val startedAt = 1_000L
        assertTrue(policy.beginAttempt(startedAt))
        policy.pause(startedAt + 10_000L)
        val restoredAt = startedAt + policy.retryWindowMs + 60_000L

        assertEquals(2_000L, policy.nextDelay(restoredAt))
        policy.resume(restoredAt)
        assertEquals(2_000L, policy.nextDelay(restoredAt))
        assertNull(policy.nextDelay(restoredAt + policy.retryWindowMs))
    }

    @Test
    fun customAttemptLimitAndBackoffAreApplied() {
        val policy = ReconnectPolicy(maxAttempts = 3, backoff = RetryBackoff.FAST)

        assertEquals(0L, policy.nextDelay(1_000L))
        assertTrue(policy.beginAttempt(1_000L))
        assertEquals(1_000L, policy.nextDelay(1_000L))
        assertTrue(policy.beginAttempt(2_000L))
        assertEquals(2_000L, policy.nextDelay(2_000L))
        assertTrue(policy.beginAttempt(4_000L))
        assertNull(policy.nextDelay(4_000L))
        assertEquals(3, policy.attemptCount)
    }

    @Test
    fun everyBackoffCanReachMaximumConfiguredAttempts() {
        RetryBackoff.entries.forEach { backoff ->
            val policy = ReconnectPolicy(maxAttempts = 10, backoff = backoff)
            var now = 1_000L
            repeat(10) {
                val delay = requireNotNull(policy.nextDelay(now))
                now += delay + 30_000L
                assertTrue(policy.beginAttempt(now))
            }
            assertNull(policy.nextDelay(now))
            assertEquals(10, policy.attemptCount)
        }
    }

    @Test
    fun disabledPolicyNeverRetries() {
        val policy = ReconnectPolicy(enabled = false)

        assertNull(policy.nextDelay(1_000L))
        assertFalse(policy.beginAttempt(1_000L))
    }

    @Test(expected = IllegalArgumentException::class)
    fun attemptLimitIsValidatedAtPolicyBoundary() {
        ReconnectPolicy(maxAttempts = 11)
    }

    @Test
    fun reconnectAvailabilityKeepsConfigurationAndCredentialPolicyDistinct() {
        assertEquals(
            AutomaticReconnectAvailability.DISABLED,
            automaticReconnectAvailability(enabled = false, credentialReusable = true),
        )
        assertEquals(
            AutomaticReconnectAvailability.REAUTHENTICATION_REQUIRED,
            automaticReconnectAvailability(enabled = true, credentialReusable = false),
        )
        assertEquals(
            AutomaticReconnectAvailability.AVAILABLE,
            automaticReconnectAvailability(enabled = true, credentialReusable = true),
        )
    }

    @Test
    fun classifiesOnlyTypedTransientFailuresForRetry() {
        listOf(
            SocketTimeoutException(),
            ConnectException(),
            UnknownHostException(),
            TransportException(DisconnectReason.CONNECTION_LOST),
            TransportException(SocketTimeoutException()),
        ).forEach { error ->
            assertEquals(SshClosureKind.RETRYABLE, classifySshClosure(error).kind)
        }
    }

    @Test
    fun unexpectedTransportEofIsRetryable() {
        listOf(
            TransportException(EOFException()),
            TransportException("Broken transport; encountered EOF"),
        ).forEach { error ->
            assertEquals(SshClosureKind.RETRYABLE, classifySshClosure(error).kind)
        }
    }

    @Test
    fun authenticationKeysProtocolAndEofArePermanent() {
        listOf(
            UserAuthException("denied"),
            KeyDecryptionFailedException("bad key"),
            TransportException(DisconnectReason.PROTOCOL_ERROR),
            TransportException(DisconnectReason.UNKNOWN),
            EOFException(),
        ).forEach { error ->
            assertEquals(SshClosureKind.PERMANENT, classifySshClosure(error).kind)
        }
        assertEquals(SshClosureKind.NORMAL, classifySshClosure(null).kind)
    }
}
