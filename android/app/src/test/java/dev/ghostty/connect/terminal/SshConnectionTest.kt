package dev.ghostty.connect.terminal

import dev.ghostty.connect.model.Host
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import net.schmizz.sshj.SSHClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SshConnectionTest {
    @Test
    fun disconnectInterruptsSetupAndFinishesCredentialCleanup() {
        val setupStarted = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val credential = "secret".toCharArray()
        val callbacks = RecordingCallbacks()
        val connection = SshConnection(callbacks, SshConnector { _, _, _ ->
            setupStarted.countDown()
            try {
                CountDownLatch(1).await()
            } catch (error: InterruptedException) {
                interrupted.countDown()
                throw error
            }
            error("unreachable")
        })
        connection.whenFinished(finished::countDown)

        connection.connect(testHost(), credential)
        assertTrue(setupStarted.await(1, TimeUnit.SECONDS))
        connection.disconnect()

        assertTrue(interrupted.await(1, TimeUnit.SECONDS))
        assertTrue(finished.await(1, TimeUnit.SECONDS))
        assertTrue(credential.all { it == '\u0000' })
        assertEquals(0, callbacks.closedCount.get())
        assertEquals(0, callbacks.connectedCount.get())
    }

    @Test
    fun cancellationSuppressesLateSetupFailureAndFinishesOnce() {
        val setupStarted = CountDownLatch(1)
        val releaseSetup = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val finishCount = AtomicInteger()
        val callbacks = RecordingCallbacks()
        val connection = SshConnection(callbacks, SshConnector { _, _, _ ->
            setupStarted.countDown()
            while (true) {
                try {
                    releaseSetup.await()
                    break
                } catch (_: InterruptedException) {
                    // Simulate a setup API that does not honor thread interruption.
                }
            }
            error("late failure")
        })
        connection.whenFinished {
            finishCount.incrementAndGet()
            finished.countDown()
        }

        connection.connect(testHost(), CharArray(0))
        assertTrue(setupStarted.await(1, TimeUnit.SECONDS))
        connection.disconnect()
        connection.disconnect()
        releaseSetup.countDown()

        assertTrue(finished.await(1, TimeUnit.SECONDS))
        connection.whenFinished { finishCount.incrementAndGet() }
        assertEquals(2, finishCount.get())
        assertEquals(0, callbacks.closedCount.get())
        assertEquals(0, callbacks.connectedCount.get())
    }

    @Test
    fun completionWaitsForOwnedClientToClose() {
        val setupStarted = CountDownLatch(1)
        val closeStarted = CountDownLatch(1)
        val allowClose = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val client = SSHClient()
        val connection = SshConnection(
            RecordingCallbacks(),
            SshConnector { _, _, ownClient ->
                ownClient(client)
                setupStarted.countDown()
                CountDownLatch(1).await()
                error("unreachable")
            },
            clientCloser = {
                closeStarted.countDown()
                allowClose.await()
            },
        )
        connection.whenFinished(finished::countDown)

        connection.connect(testHost(), CharArray(0))
        assertTrue(setupStarted.await(1, TimeUnit.SECONDS))
        connection.disconnect()

        assertTrue(closeStarted.await(1, TimeUnit.SECONDS))
        assertFalse(finished.await(100, TimeUnit.MILLISECONDS))
        allowClose.countDown()
        assertTrue(finished.await(1, TimeUnit.SECONDS))
    }

    private fun testHost() = Host(id = "host", hostname = "example.com", username = "user")

    private class RecordingCallbacks : SshConnection.Callbacks {
        val connectedCount = AtomicInteger()
        val closedCount = AtomicInteger()

        override fun status(message: String) = Unit
        override fun output(bytes: ByteArray) = Unit
        override fun connected() { connectedCount.incrementAndGet() }
        override fun closed(closure: SshClosure) { closedCount.incrementAndGet() }
        override fun verifyHostKey(request: HostKeyVerification, answer: (Boolean) -> Unit) = answer(false)
        override fun challenge(
            challenge: AuthenticationChallenge,
            answer: (CharArray?) -> Unit,
        ): () -> Unit = { answer(null) }
    }
}
