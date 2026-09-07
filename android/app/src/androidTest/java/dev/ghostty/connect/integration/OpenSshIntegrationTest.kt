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
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
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
}
