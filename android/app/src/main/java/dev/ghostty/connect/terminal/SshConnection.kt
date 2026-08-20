package dev.ghostty.connect.terminal

import android.content.Context
import dev.ghostty.connect.BuildConfig
import dev.ghostty.connect.data.KnownHostStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.SecurityUtils
import net.schmizz.sshj.connection.ConnectionException
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.connection.channel.direct.Signal
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.io.File
import java.security.PublicKey
import java.security.Security
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class SshConnection(
    private val context: Context,
    private val keyStore: SshKeyStore,
    private val callbacks: Callbacks,
) {
    private val knownHostStore = KnownHostStore(context)
    private val channelExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "ssh-channel")
    }

    interface Callbacks {
        fun status(message: String)
        fun output(bytes: ByteArray)
        fun verifyHostKey(fingerprint: String, changed: Boolean, answer: (Boolean) -> Unit)
        fun closed(error: String?)
    }

    private var client: SSHClient? = null
    private var session: Session? = null
    private var shell: Session.Shell? = null
    @Volatile private var stopping = false
    @Volatile private var columns = 80
    @Volatile private var rows = 24
    @Volatile private var pixelWidth = 0
    @Volatile private var pixelHeight = 0

    fun connect(host: Host, passwordOrPassphrase: String) = thread(name = "ssh-${host.hostname}") {
        var temporaryKey: File? = null
        try {
            callbacks.status("Connecting…")
            installModernBouncyCastle()
            val ssh = SSHClient()
            client = ssh
            ssh.addHostKeyVerifier(verifier(host))
            ssh.connect(host.hostname, host.port)
            ssh.connection.keepAlive.keepAliveInterval = 30
            callbacks.status("Authenticating…")
            if (host.authenticationType == AuthenticationType.SSH_KEY) {
                val keyName = requireNotNull(host.keyName) { "No SSH key is selected for this host" }
                temporaryKey = File.createTempFile("identity-", ".key", context.cacheDir).apply {
                    writeBytes(keyStore.read(keyName))
                    setReadable(false, false)
                    setReadable(true, true)
                }
                val provider = ssh.loadKeys(temporaryKey.absolutePath, passwordOrPassphrase)
                ssh.authPublickey(host.username, provider)
            } else {
                ssh.authPassword(host.username, passwordOrPassphrase)
            }
            temporaryKey?.delete()
            callbacks.status("Connected")
            val activeSession = ssh.startSession().also { session = it }
            setOptionalEnvironment(activeSession, "COLORTERM", "truecolor")
            setOptionalEnvironment(activeSession, "TERM_PROGRAM", "ghostty")
            setOptionalEnvironment(activeSession, "TERM_PROGRAM_VERSION", BuildConfig.VERSION_NAME)
            activeSession.allocatePTY("xterm-256color", columns, rows, pixelWidth, pixelHeight, emptyMap())
            val activeShell = activeSession.startShell().also { shell = it }
            thread(name = "ssh-stderr", isDaemon = true) {
                val errorBuffer = ByteArray(4096)
                runCatching {
                    while (!stopping) {
                        val count = activeShell.errorStream.read(errorBuffer)
                        if (count < 0) break
                        if (count > 0) callbacks.output(errorBuffer.copyOf(count))
                    }
                }
            }
            val buffer = ByteArray(8192)
            while (!stopping) {
                val count = activeShell.inputStream.read(buffer)
                if (count < 0) break
                callbacks.output(buffer.copyOf(count))
            }
            if (!stopping) callbacks.closed(null)
        } catch (error: Exception) {
            if (!stopping) callbacks.closed(error.message ?: error.javaClass.simpleName)
        } finally {
            temporaryKey?.delete()
            closeResources()
        }
    }

    fun send(text: String) {
        send(text.toByteArray())
    }

    fun send(bytes: ByteArray) {
        if (stopping) return
        runCatching { channelExecutor.execute {
            runCatching {
                shell?.outputStream?.apply {
                    write(bytes)
                    flush()
                }
            }.onFailure { callbacks.closed(it.message) }
        } }
    }

    fun resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        this.columns = columns
        this.rows = rows
        this.pixelWidth = pixelWidth
        this.pixelHeight = pixelHeight
        if (stopping) return
        runCatching { channelExecutor.execute {
            runCatching { shell?.changeWindowDimensions(columns, rows, pixelWidth, pixelHeight) }
        } }
    }

    fun signal(signal: Signal) {
        if (stopping) return
        runCatching { channelExecutor.execute { runCatching { shell?.signal(signal) } } }
    }

    fun disconnect() {
        stopping = true
        closeResources()
    }

    private fun verifier(host: Host) = object : HostKeyVerifier {
        override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
            val fingerprint = SecurityUtils.getFingerprint(key)
            val known = knownHostStore.fingerprint(host.hostname, host.port)
            if (known == fingerprint) return true
            val latch = CountDownLatch(1)
            var accepted = false
            callbacks.verifyHostKey(fingerprint, known != null) {
                accepted = it
                latch.countDown()
            }
            if (!latch.await(2, TimeUnit.MINUTES) || !accepted) return false
            knownHostStore.trust(host.hostname, host.port, fingerprint)
            return true
        }

        override fun findExistingAlgorithms(hostname: String, port: Int): MutableList<String> = mutableListOf()
    }

    private fun setOptionalEnvironment(session: Session, name: String, value: String) {
        try {
            session.setEnvVar(name, value)
        } catch (error: ConnectionException) {
            if (error.message != "Request failed") throw error
        }
    }

    private fun closeResources() {
        channelExecutor.shutdownNow()
        runCatching { shell?.close() }
        runCatching { session?.close() }
        runCatching { client?.disconnect() }
    }

    private fun installModernBouncyCastle() {
        synchronized(PROVIDER_LOCK) {
            val current = Security.getProvider(BouncyCastleProvider.PROVIDER_NAME)
            if (current?.getService("KeyAgreement", "X25519") == null) {
                Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
                Security.insertProviderAt(BouncyCastleProvider(), 1)
            }
            check(Security.getProvider(BouncyCastleProvider.PROVIDER_NAME)?.getService("KeyAgreement", "X25519") != null) {
                "This device could not initialize X25519 support"
            }
            SecurityUtils.setRegisterBouncyCastle(false)
            SecurityUtils.setSecurityProvider(BouncyCastleProvider.PROVIDER_NAME)
        }
    }

    companion object {
        private val PROVIDER_LOCK = Any()
    }
}
