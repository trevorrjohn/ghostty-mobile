package dev.ghostty.connect.terminal

import com.hierynomus.sshj.common.KeyDecryptionFailedException
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

        ReconnectPolicy.DELAYS_MS.forEach { delay ->
            assertEquals(delay, policy.nextDelay(now))
            assertTrue(policy.beginAttempt(now))
            now += delay
        }
        assertNull(policy.nextDelay(now))
        assertFalse(policy.beginAttempt(now))
    }

    @Test
    fun retryWindowDoesNotResetWithoutSuccessfulConnection() {
        val policy = ReconnectPolicy()
        assertTrue(policy.beginAttempt(1_000L))
        assertNull(policy.nextDelay(1_000L + ReconnectPolicy.WINDOW_MS + 1))
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
    fun authenticationKeysProtocolAndEofArePermanent() {
        listOf(
            UserAuthException("denied"),
            KeyDecryptionFailedException("bad key"),
            TransportException(DisconnectReason.PROTOCOL_ERROR),
            EOFException(),
        ).forEach { error ->
            assertEquals(SshClosureKind.PERMANENT, classifySshClosure(error).kind)
        }
        assertEquals(SshClosureKind.NORMAL, classifySshClosure(null).kind)
    }
}
