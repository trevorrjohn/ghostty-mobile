package dev.ghostty.connect.terminal

import android.content.Context
import dev.ghostty.connect.data.KnownHostStore
import dev.ghostty.connect.data.SshKeyStore
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.model.SshDestination
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.SecurityUtils
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
import java.net.InetAddress
import java.security.PublicKey
import java.security.Security
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

interface SshAuthenticationCallbacks {
    fun status(message: String)
    fun verifyHostKey(request: HostKeyVerification, answer: (Boolean) -> Unit)
    fun challenge(challenge: AuthenticationChallenge, answer: (CharArray?) -> Unit): () -> Unit
}

data class HostKeyVerification(
    val destination: String,
    val algorithm: String,
    val fingerprint: String,
    val previousFingerprints: List<String>,
) {
    val changed: Boolean get() = previousFingerprints.isNotEmpty()
}

internal class AuthenticatedSshClient(
    private val context: Context,
    private val keyStore: SshKeyStore,
    private val callbacks: SshAuthenticationCallbacks,
) {
    fun connect(
        host: Host,
        credential: CharArray,
        resolvedAddress: InetAddress? = null,
        disconnectOnFailure: Boolean = true,
        clientReady: (SSHClient) -> Unit = {},
    ): SSHClient {
        var temporaryKey: File? = null
        var privateKeyBytes: ByteArray? = null
        val challengeResponses = mutableListOf<CharArray>()
        var challengeProvider: InteractiveChallengeProvider? = null
        val ssh = SSHClient()
        try {
            clientReady(ssh)
            callbacks.status("Connecting…")
            installModernBouncyCastle()
            val destination = SshDestination.create(host.hostname, host.port)
            ssh.connectTimeout = CONNECT_TIMEOUT_MS
            ssh.addHostKeyVerifier(verifier(destination))
            if (resolvedAddress == null) {
                ssh.connect(destination.hostname, destination.port)
            } else {
                ssh.connect(resolvedAddress, destination.port)
            }
            ssh.connection.keepAlive.keepAliveInterval = 30
            callbacks.status("Authenticating…")
            if (host.authenticationType == AuthenticationType.SSH_KEY) {
                challengeProvider = InteractiveChallengeProvider(callbacks, challengeResponses, null)
                val keyboardInteractive = AuthKeyboardInteractive(challengeProvider)
                val identityId = requireNotNull(host.identityId) { "No SSH identity is selected for this host" }
                privateKeyBytes = keyStore.read(identityId)
                temporaryKey = File.createTempFile("identity-", ".key", context.cacheDir).apply {
                    writeBytes(privateKeyBytes)
                    setReadable(false, false)
                    setReadable(true, true)
                }
                val provider = ssh.loadKeys(temporaryKey.absolutePath, credential)
                ssh.auth(host.username, credentialThenChallenge(AuthPublickey(provider), keyboardInteractive, credential))
            } else {
                challengeProvider = InteractiveChallengeProvider(callbacks, challengeResponses, credential.copyOf())
                val keyboardInteractive = AuthKeyboardInteractive(challengeProvider)
                ssh.auth(
                    host.username,
                    credentialThenChallenge(
                        AuthPassword(PasswordUtils.createOneOff(credential)),
                        keyboardInteractive,
                        credential,
                    ),
                )
            }
            return ssh
        } catch (error: Exception) {
            if (disconnectOnFailure) runCatching { ssh.disconnect() }
            throw error
        } finally {
            credential.fill('\u0000')
            privateKeyBytes?.fill(0)
            challengeProvider?.clear()
            challengeResponses.forEach { it.fill('\u0000') }
            temporaryKey?.delete()
        }
    }

    private fun verifier(destination: SshDestination) = object : HostKeyVerifier {
        override fun verify(hostname: String, port: Int, key: PublicKey): Boolean {
            val fingerprint = SecurityUtils.getFingerprint(key)
            val store = KnownHostStore(context)
            val lookup = store.lookup(destination.hostname, destination.port)
            if (lookup.fingerprint == fingerprint) return true
            val latch = CountDownLatch(1)
            var approved = false
            callbacks.verifyHostKey(HostKeyVerification(
                destination = destination.display,
                algorithm = key.algorithm,
                fingerprint = fingerprint,
                previousFingerprints = lookup.fingerprints.sorted(),
            )) { accepted ->
                approved = accepted
                latch.countDown()
            }
            if (!latch.await(PROMPT_TIMEOUT_SECONDS, TimeUnit.SECONDS) || !approved) return false
            return store.trust(lookup, fingerprint)
        }

        override fun findExistingAlgorithms(hostname: String, port: Int): MutableList<String> = mutableListOf()
    }

    private class InteractiveChallengeProvider(
        private val callbacks: SshAuthenticationCallbacks,
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
            val value = response.await(PROMPT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
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

    companion object {
        private val PROVIDER_LOCK = Any()
        private const val CONNECT_TIMEOUT_MS = 12_000
        private const val PROMPT_TIMEOUT_SECONDS = 120L

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
    }
}
