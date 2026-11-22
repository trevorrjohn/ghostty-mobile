package dev.ghostty.connect.terminal

import com.hierynomus.sshj.common.KeyDecryptionFailedException
import dev.ghostty.connect.model.DEFAULT_RETRY_ATTEMPTS
import dev.ghostty.connect.model.MAX_RETRY_ATTEMPTS
import dev.ghostty.connect.model.MIN_RETRY_ATTEMPTS
import dev.ghostty.connect.model.RetryBackoff
import dev.ghostty.connect.terminal.bridge.SeanceCore
import java.io.EOFException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import net.schmizz.sshj.common.DisconnectReason
import net.schmizz.sshj.common.SSHException
import net.schmizz.sshj.userauth.UserAuthException

enum class SshClosureKind {
    NORMAL,
    RETRYABLE,
    PERMANENT,
}

data class SshClosure(
    val kind: SshClosureKind,
    val message: String? = null,
)

internal fun classifySshClosure(error: Throwable?): SshClosure {
    if (error == null) return SshClosure(SshClosureKind.NORMAL)
    val causes = generateSequence(error) { it.cause }.toList()
    val message = error.message ?: error.javaClass.simpleName
    if (causes.any { it is UserAuthException || it is KeyDecryptionFailedException }) {
        return SshClosure(SshClosureKind.PERMANENT, message)
    }
    causes.filterIsInstance<SSHException>().firstOrNull()?.let { sshError ->
        when (sshError.disconnectReason) {
            DisconnectReason.CONNECTION_LOST -> return SshClosure(SshClosureKind.RETRYABLE, message)
            DisconnectReason.UNKNOWN -> if (
                causes.any { it is EOFException } ||
                sshError.message?.contains("encountered EOF", ignoreCase = true) == true
            ) return SshClosure(SshClosureKind.RETRYABLE, message)
            else -> return SshClosure(SshClosureKind.PERMANENT, message)
        }
    }
    return if (causes.any {
            it is SocketTimeoutException || it is ConnectException || it is NoRouteToHostException ||
                it is UnknownHostException || it is SocketException
        }) {
        SshClosure(SshClosureKind.RETRYABLE, message)
    } else {
        SshClosure(SshClosureKind.PERMANENT, message)
    }
}

internal enum class AutomaticReconnectAvailability {
    AVAILABLE,
    DISABLED,
    REAUTHENTICATION_REQUIRED,
}

internal fun automaticReconnectAvailability(
    enabled: Boolean,
    credentialReusable: Boolean,
): AutomaticReconnectAvailability = when {
    !enabled -> AutomaticReconnectAvailability.DISABLED
    !credentialReusable -> AutomaticReconnectAvailability.REAUTHENTICATION_REQUIRED
    else -> AutomaticReconnectAvailability.AVAILABLE
}

internal fun notificationReconnectAvailable(
    manualRetryAvailable: Boolean,
    credentialReusable: Boolean,
    connected: Boolean,
    attemptActive: Boolean,
    waitingToReconnect: Boolean,
    cleaningUp: Boolean,
): Boolean = manualRetryAvailable && credentialReusable && !connected && !attemptActive &&
    !waitingToReconnect && !cleaningUp

internal fun identityCredentialReusable(requiresPassphrase: Boolean, requiresBiometric: Boolean): Boolean =
    !requiresPassphrase && !requiresBiometric

/**
 * Reconnect policy backed by the shared core (`core/src/reconnect.zig`), so
 * backoff and the retry window are identical on iOS and Android.
 */
internal class ReconnectPolicy(
    enabled: Boolean = true,
    val maxAttempts: Int = DEFAULT_RETRY_ATTEMPTS,
    backoff: RetryBackoff = RetryBackoff.BALANCED,
) {
    private val handle: Long

    init {
        require(maxAttempts in MIN_RETRY_ATTEMPTS..MAX_RETRY_ATTEMPTS) {
            "Retry attempts must be between $MIN_RETRY_ATTEMPTS and $MAX_RETRY_ATTEMPTS."
        }
        handle = SeanceCore.nativeReconnectCreate(enabled, maxAttempts, backoff.ordinal)
        check(handle != 0L) { "Could not create a reconnect policy." }
    }

    internal val retryWindowMs: Long = SeanceCore.nativeReconnectWindowMs(handle)
    val attemptCount: Int get() = SeanceCore.nativeReconnectAttemptCount(handle)

    fun nextDelay(now: Long): Long? =
        SeanceCore.nativeReconnectNextDelay(handle, now).takeIf { it >= 0 }

    fun beginAttempt(now: Long): Boolean = SeanceCore.nativeReconnectBeginAttempt(handle, now)

    fun reset() = SeanceCore.nativeReconnectReset(handle)

    fun pause(now: Long) = SeanceCore.nativeReconnectPause(handle, now)

    fun resume(now: Long) = SeanceCore.nativeReconnectResume(handle, now)

    @Suppress("unused", "ProtectedInFinal")
    protected fun finalize() {
        SeanceCore.nativeReconnectFree(handle)
    }

    companion object {
        internal val BALANCED_DELAYS_MS = longArrayOf(
            0L, 2_000L, 5_000L, 10_000L, 20_000L, 30_000L, 30_000L, 30_000L, 30_000L, 30_000L,
        )
    }
}
