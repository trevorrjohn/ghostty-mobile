package dev.ghostty.connect.integration

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.data.KnownHostStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.sftp.SftpConnection
import dev.ghostty.connect.terminal.AuthenticatedSshClient
import dev.ghostty.connect.terminal.AuthenticationChallenge
import dev.ghostty.connect.terminal.HostKeyVerification
import dev.ghostty.connect.terminal.SshAuthenticationCallbacks
import dev.ghostty.connect.terminal.SshClosure
import dev.ghostty.connect.terminal.SshClosureKind
import dev.ghostty.connect.terminal.SshConnection
import dev.ghostty.connect.terminal.SshConnector
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OpenSshIntegrationTest {
    private lateinit var context: Context
    private lateinit var fixture: Fixture

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        fixture = Fixture.fromInstrumentationArguments()
        assumeTrue("Run android/scripts/run-live-ssh-tests to provide OpenSSH", fixture.port > 0)
        clearKnownHosts()
    }

    @After
    fun tearDown() = clearKnownHosts()

    @Test
    fun passwordAuthenticationRequiresApprovalThenReusesTrust() {
        val firstCallbacks = RecordingAuthenticationCallbacks(approveHostKey = true)
        val firstCredential = fixture.password.toCharArray()
        val first = authenticatedClient(firstCallbacks).connect(fixture.host(), firstCredential)
        first.disconnect()

        assertTrue(firstCredential.all { it == '\u0000' })
        assertEquals(1, firstCallbacks.hostKeys.size)
        assertFalse(firstCallbacks.hostKeys.single().changed)
        assertTrue(firstCallbacks.hostKeys.single().previousFingerprints.isEmpty())

        val secondCallbacks = RecordingAuthenticationCallbacks(approveHostKey = false)
        val second = authenticatedClient(secondCallbacks).connect(fixture.host(), fixture.password.toCharArray())
        second.disconnect()

        assertTrue(secondCallbacks.hostKeys.isEmpty())
        assertEquals(
            firstCallbacks.hostKeys.single().fingerprint,
            KnownHostStore(context).lookup(fixture.host, fixture.port).fingerprint,
        )
    }

    @Test
    fun rejectedHostAndIncorrectPasswordCannotAuthenticate() {
        val rejectedCredential = fixture.password.toCharArray()
        assertThrows(Exception::class.java) {
            authenticatedClient(RecordingAuthenticationCallbacks(approveHostKey = false))
                .connect(fixture.host(), rejectedCredential)
        }
        assertTrue(rejectedCredential.all { it == '\u0000' })
        assertFalse(KnownHostStore(context).lookup(fixture.host, fixture.port).hasExistingTrust)

        val wrongCredential = "not-the-password".toCharArray()
        assertThrows(Exception::class.java) {
            authenticatedClient(RecordingAuthenticationCallbacks(approveHostKey = true))
                .connect(fixture.host(), wrongCredential)
        }
        assertTrue(wrongCredential.all { it == '\u0000' })
    }

    @Test
    fun ptyEchoesOutputAndAbruptServerLossIsRetryable() {
        val callbacks = RecordingConnectionCallbacks()
        val connection = SshConnection(
            callbacks = callbacks,
            connector = SshConnector { host, credential, unlockedPrivateKey, ownClient ->
                authenticatedClient(callbacks).connect(
                    host = host,
                    credential = credential,
                    resolvedAddress = InetAddress.getLoopbackAddress(),
                    disconnectOnFailure = false,
                    clientReady = ownClient,
                    unlockedPrivateKey = unlockedPrivateKey,
                )
            },
        )
        callbacks.attach(connection)
        try {
            connection.connect(fixture.host(), fixture.password.toCharArray())
            assertTrue("SSH shell did not connect", callbacks.connected.await(15, TimeUnit.SECONDS))

            connection.send("printf '__ghostty_live__\\n'\n")
            assertTrue("SSH shell output did not arrive", callbacks.outputArrived.await(10, TimeUnit.SECONDS))
            assertTrue(callbacks.outputText().contains("__ghostty_live__"))

            // Killing the per-connection sshd process simulates transport loss, not a clean shell exit.
            connection.send("kill -9 \$PPID\n")
            assertTrue("Abrupt SSH closure was not reported", callbacks.closed.await(15, TimeUnit.SECONDS))
            assertEquals(SshClosureKind.RETRYABLE, callbacks.closure?.kind)
            assertTrue("SSH worker did not finish", callbacks.finished.await(10, TimeUnit.SECONDS))
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun sftpStreamsUploadsDownloadsAndCleansCanceledUpload() {
        val callbacks = RecordingAuthenticationCallbacks(approveHostKey = true)
        val connection = SftpConnection(context, callbacks)
        try {
            val home = connection.connect(fixture.host(), fixture.password.toCharArray())
            assertTrue(home.endsWith("/ghostty"))

            val payload = ByteArray(256 * 1024) { index -> (index % 251).toByte() }
            val uploadProgress = mutableListOf<Long>()
            connection.upload(
                currentPath = home,
                finalName = "round-trip.bin",
                input = ByteArrayInputStream(payload),
                total = payload.size.toLong(),
                replace = false,
                canceled = AtomicBoolean(false),
            ) { transferred, _ -> uploadProgress += transferred }
            assertTrue(uploadProgress.zipWithNext().all { (before, after) -> after > before })

            val downloaded = ByteArrayOutputStream()
            val downloadProgress = mutableListOf<Long>()
            connection.download(home, "round-trip.bin", downloaded, AtomicBoolean(false)) { transferred, _ ->
                downloadProgress += transferred
            }
            assertArrayEquals(payload, downloaded.toByteArray())
            assertTrue(downloadProgress.zipWithNext().all { (before, after) -> after > before })

            val canceled = AtomicBoolean(false)
            assertThrows(IllegalStateException::class.java) {
                connection.upload(
                    currentPath = home,
                    finalName = "canceled.bin",
                    input = ByteArrayInputStream(payload),
                    total = payload.size.toLong(),
                    replace = false,
                    canceled = canceled,
                ) { _, _ -> canceled.set(true) }
            }
            assertFalse(connection.exists(home, "canceled.bin"))
            assertFalse(connection.list(home).any { it.name.startsWith(".seance-shell-upload-") })
            assertTrue(connection.exists(home, "round-trip.bin"))
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun sftpLiveDirectoryOperationsRoundTrip() {
        val connection = SftpConnection(context, RecordingAuthenticationCallbacks(approveHostKey = true))
        try {
            val home = connection.connect(fixture.host(), fixture.password.toCharArray())
            val directory = "ops-${UUID.randomUUID()}"
            val renamed = "$directory-renamed"

            connection.createDirectory(home, directory)
            assertTrue(connection.list(home).any { it.name == directory && it.type == dev.ghostty.connect.sftp.SftpEntryType.DIRECTORY })

            val entered = connection.enterDirectory(home, directory)
            assertEquals(entered, connection.openDirectoryPath(home, directory))

            connection.rename(home, directory, renamed)
            assertFalse(connection.exists(home, directory))
            assertTrue(connection.exists(home, renamed))
            assertEquals(connection.enterDirectory(home, renamed), connection.openDirectoryPath(home, renamed))

            val entry = connection.list(home).single { it.name == renamed }
            connection.delete(home, entry)
            assertFalse(connection.exists(home, renamed))
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun sftpLiveRejectsConflictsAndUnsafePaths() {
        val connection = SftpConnection(context, RecordingAuthenticationCallbacks(approveHostKey = true))
        try {
            val home = connection.connect(fixture.host(), fixture.password.toCharArray())
            val directory = "conflict-${UUID.randomUUID()}"
            val other = "$directory-other"
            val payload = byteArrayOf(1, 2, 3, 4)

            connection.createDirectory(home, directory)
            connection.createDirectory(home, other)

            assertThrows(IllegalArgumentException::class.java) { connection.createDirectory(home, directory) }
            assertThrows(IllegalArgumentException::class.java) { connection.rename(home, directory, other) }
            assertThrows(IllegalStateException::class.java) { connection.createDirectory(home, "../escape") }
            assertThrows(IllegalArgumentException::class.java) { connection.openDirectoryPath(home, "bad\u0000path") }

            connection.upload(home, "existing.bin", ByteArrayInputStream(payload), payload.size.toLong(), false, AtomicBoolean(false)) { _, _ -> }
            assertThrows(IllegalStateException::class.java) {
                connection.upload(home, "existing.bin", ByteArrayInputStream(payload), payload.size.toLong(), false, AtomicBoolean(false)) { _, _ -> }
            }

            connection.delete(home, connection.list(home).single { it.name == "existing.bin" })
            connection.delete(home, connection.list(home).single { it.name == directory })
            connection.delete(home, connection.list(home).single { it.name == other })
        } finally {
            connection.disconnect()
        }
    }

    @Test
    fun sftpLiveDownloadFailsSafelyWhenConnectionIsInterrupted() {
        val connection = SftpConnection(context, RecordingAuthenticationCallbacks(approveHostKey = true))
        try {
            val home = connection.connect(fixture.host(), fixture.password.toCharArray())
            val name = "interrupted-${UUID.randomUUID()}.bin"
            val payload = ByteArray(4 * 1024 * 1024) { index -> (index % 239).toByte() }
            connection.upload(home, name, ByteArrayInputStream(payload), payload.size.toLong(), false, AtomicBoolean(false)) { _, _ -> }

            val firstWrite = CountDownLatch(1)
            val releaseWrite = CountDownLatch(1)
            val finished = CountDownLatch(1)
            val failure = AtomicReference<Throwable?>()
            val output = BlockingOutputStream(firstWrite, releaseWrite)
            Thread({
                try {
                    connection.download(home, name, output, AtomicBoolean(false)) { _, _ -> }
                } catch (error: Throwable) {
                    failure.set(error)
                } finally {
                    finished.countDown()
                }
            }, "sftp-interrupted-download").start()

            assertTrue("Download did not start", firstWrite.await(10, TimeUnit.SECONDS))
            connection.disconnect()
            releaseWrite.countDown()

            assertTrue("Interrupted download did not finish", finished.await(15, TimeUnit.SECONDS))
            assertTrue("Download unexpectedly completed after disconnect", failure.get() != null)
            assertTrue("Interrupted output should be partial", output.bytesWritten < payload.size)
        } finally {
            connection.disconnect()
        }
    }

    private fun authenticatedClient(callbacks: SshAuthenticationCallbacks) =
        AuthenticatedSshClient(context, SshKeyStore(context), callbacks)

    private fun clearKnownHosts() {
        context.fileList().filter { it.startsWith("known-hosts.enc") }.forEach(context::deleteFile)
        context.getSharedPreferences("known_hosts", Context.MODE_PRIVATE).edit().clear().commit()
    }

    private data class Fixture(
        val host: String,
        val port: Int,
        val username: String,
        val password: String,
    ) {
        fun host() = Host(
            id = UUID.randomUUID().toString(),
            alias = "Disposable OpenSSH",
            hostname = host,
            port = port,
            username = username,
            retryEnabled = false,
        )

        companion object {
            fun fromInstrumentationArguments(): Fixture {
                val arguments = InstrumentationRegistry.getArguments()
                return Fixture(
                    host = arguments.getString("sshHost").orEmpty(),
                    port = arguments.getString("sshPort")?.toIntOrNull() ?: 0,
                    username = arguments.getString("sshUsername").orEmpty(),
                    password = arguments.getString("sshPassword").orEmpty(),
                )
            }
        }
    }

    private open class RecordingAuthenticationCallbacks(
        private val approveHostKey: Boolean,
    ) : SshAuthenticationCallbacks {
        val hostKeys = mutableListOf<HostKeyVerification>()

        override fun status(message: String) = Unit

        override fun verifyHostKey(request: HostKeyVerification, answer: (Boolean) -> Unit) {
            synchronized(hostKeys) { hostKeys += request }
            answer(approveHostKey)
        }

        override fun challenge(challenge: AuthenticationChallenge, answer: (CharArray?) -> Unit): () -> Unit {
            answer(null)
            return {}
        }
    }

    private class RecordingConnectionCallbacks : RecordingAuthenticationCallbacks(true), SshConnection.Callbacks {
        val connected = CountDownLatch(1)
        val outputArrived = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val finished = CountDownLatch(1)
        private val output = ByteArrayOutputStream()
        @Volatile var closure: SshClosure? = null

        override fun connected() = connected.countDown()

        override fun output(bytes: ByteArray) {
            synchronized(output) { output.write(bytes) }
            if (outputText().contains("__ghostty_live__")) outputArrived.countDown()
        }

        override fun closed(closure: SshClosure) {
            this.closure = closure
            closed.countDown()
        }

        fun outputText(): String = synchronized(output) { output.toString(Charsets.UTF_8.name()) }

        fun attach(connection: SshConnection) = connection.whenFinished(finished::countDown)
    }

    private class BlockingOutputStream(
        private val firstWrite: CountDownLatch,
        private val releaseWrite: CountDownLatch,
    ) : OutputStream() {
        @Volatile var bytesWritten = 0L

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            bytesWritten += length.toLong()
            firstWrite.countDown()
            assertTrue("Timed out waiting to release blocked write", releaseWrite.await(10, TimeUnit.SECONDS))
        }

        override fun write(value: Int) {
            bytesWritten++
            firstWrite.countDown()
            assertTrue("Timed out waiting to release blocked write", releaseWrite.await(10, TimeUnit.SECONDS))
        }
    }
}
