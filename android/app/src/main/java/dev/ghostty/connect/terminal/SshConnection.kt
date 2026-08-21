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
import net.schmizz.sshj.userauth.UserAuthException
import net.schmizz.sshj.userauth.method.AuthKeyboardInteractive
import net.schmizz.sshj.userauth.method.AuthMethod
import net.schmizz.sshj.userauth.method.AuthPassword
import net.schmizz.sshj.userauth.method.AuthPublickey
import net.schmizz.sshj.userauth.method.ChallengeResponseProvider
import net.schmizz.sshj.userauth.password.PasswordUtils
import net.schmizz.sshj.userauth.password.Resource
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.io.File
import java.security.PublicKey
import java.security.Security
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
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
        fun challenge(challenge: AuthenticationChallenge, answer: (CharArray?) -> Unit): () -> Unit
        fun connected()
        fun closed(closure: SshClosure)
    }

    private var client: SSHClient? = null
    private var session: Session? = null
    private var shell: Session.Shell? = null
    @Volatile private var stopping = false
    @Volatile private var columns = 80
    @Volatile private var rows = 24
    @Volatile private var pixelWidth = 0
    @Volatile private var pixelHeight = 0
    private val closureReported = AtomicBoolean(false)

    fun connect(host: Host, passwordOrPassphrase: CharArray) = thread(name = "ssh-${host.hostname}") {
        var temporaryKey: File? = null
        val challengeResponses = mutableListOf<CharArray>()
        var challengeProvider: InteractiveChallengeProvider? = null
        try {
            callbacks.status("Connecting…")
            installModernBouncyCastle()
            val ssh = SSHClient()
            client = ssh
            ssh.connectTimeout = CONNECT_TIMEOUT_MS
            ssh.addHostKeyVerifier(verifier(host))
            ssh.connect(host.hostname, host.port)
            ssh.connection.keepAlive.keepAliveInterval = 30
            callbacks.status("Authenticating…")
            if (host.authenticationType == AuthenticationType.SSH_KEY) {
                challengeProvider = InteractiveChallengeProvider(callbacks, challengeResponses, null)
                val keyboardInteractive = AuthKeyboardInteractive(challengeProvider)
                val identityId = requireNotNull(host.identityId) { "No SSH identity is selected for this host" }
                temporaryKey = File.createTempFile("identity-", ".key", context.cacheDir).apply {
                    writeBytes(keyStore.read(identityId))
                    setReadable(false, false)
                    setReadable(true, true)
                }
                val provider = ssh.loadKeys(temporaryKey.absolutePath, passwordOrPassphrase)
                ssh.auth(
                    host.username,
                    credentialThenChallenge(AuthPublickey(provider), keyboardInteractive, passwordOrPassphrase),
                )
            } else {
                challengeProvider = InteractiveChallengeProvider(
                    callbacks,
                    challengeResponses,
                    passwordOrPassphrase.copyOf(),
                )
                val keyboardInteractive = AuthKeyboardInteractive(challengeProvider)
                ssh.auth(
                    host.username,
                    credentialThenChallenge(
                        AuthPassword(PasswordUtils.createOneOff(passwordOrPassphrase)),
                        keyboardInteractive,
                        passwordOrPassphrase,
                    ),
                )
            }
            passwordOrPassphrase.fill('\u0000')
            challengeProvider?.clear()
            challengeResponses.forEach { it.fill('\u0000') }
            temporaryKey?.delete()
            val activeSession = ssh.startSession().also { session = it }
            setOptionalEnvironment(activeSession, "COLORTERM", "truecolor")
            setOptionalEnvironment(activeSession, "TERM_PROGRAM", "ghostty")
            setOptionalEnvironment(activeSession, "TERM_PROGRAM_VERSION", BuildConfig.VERSION_NAME)
            activeSession.allocatePTY("xterm-256color", columns, rows, pixelWidth, pixelHeight, emptyMap())
            val activeShell = activeSession.startShell().also { shell = it }
            callbacks.connected()
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
            if (!stopping) reportClosed(null)
        } catch (error: Exception) {
            if (!stopping) reportClosed(error)
        } finally {
            passwordOrPassphrase.fill('\u0000')
            challengeProvider?.clear()
            challengeResponses.forEach { it.fill('\u0000') }
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
            }.onFailure(::reportClosed)
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

    private class InteractiveChallengeProvider(
        private val callbacks: Callbacks,
        private val responses: MutableList<CharArray>,
        private var initialPassword: CharArray?,
    ) : ChallengeResponseProvider {
        private var title = ""
        private var instruction = ""

        override fun getSubmethods(): List<String> = emptyList()

        override fun init(resource: Resource<*>?, name: String?, instruction: String?) {
            title = name.orEmpty()
            this.instruction = instruction.orEmpty()
        }

        override fun getResponse(prompt: String, echo: Boolean): CharArray {
            if (!echo && prompt.contains("password", ignoreCase = true)) {
                initialPassword?.let { password ->
                    initialPassword = null
                    responses += password
                    return password
                }
            }
            val response = ChallengeResponseAwaiter()
            val cancel = callbacks.challenge(
                AuthenticationChallenge(title, instruction, prompt, echo),
                { submitted -> if (!response.answer(submitted)) submitted?.fill('\u0000') },
            )
            val value = response.await(CHALLENGE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            if (value == null) {
                cancel()
                throw UserAuthException("Keyboard-interactive authentication canceled or timed out")
            }
            responses += value
            return value
        }

        override fun shouldRetry(): Boolean = false

        fun clear() {
            initialPassword?.fill('\u0000')
            initialPassword = null
        }
    }

    private fun credentialThenChallenge(
        primary: AuthMethod,
        challenge: AuthMethod,
        credential: CharArray,
    ): Iterable<AuthMethod> = Iterable {
        object : Iterator<AuthMethod> {
            private var index = 0

            override fun hasNext(): Boolean = index < 2

            override fun next(): AuthMethod = when (index++) {
                0 -> primary
                1 -> challenge.also { credential.fill('\u0000') }
                else -> throw NoSuchElementException()
            }
        }
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

    private fun reportClosed(error: Throwable?) {
        if (!stopping && closureReported.compareAndSet(false, true)) {
            callbacks.closed(classifySshClosure(error))
        }
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
        private const val CONNECT_TIMEOUT_MS = 12_000
        private const val CHALLENGE_TIMEOUT_SECONDS = 120L
    }
}
