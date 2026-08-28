package dev.ghostty.connect.terminal

import com.hierynomus.sshj.common.KeyDecryptionFailedException
import dev.ghostty.connect.model.DEFAULT_RETRY_ATTEMPTS
import dev.ghostty.connect.model.MAX_RETRY_ATTEMPTS
import dev.ghostty.connect.model.MIN_RETRY_ATTEMPTS
import dev.ghostty.connect.model.RetryBackoff
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

internal class ReconnectPolicy(
    private val enabled: Boolean = true,
    val maxAttempts: Int = DEFAULT_RETRY_ATTEMPTS,
    private val backoff: RetryBackoff = RetryBackoff.BALANCED,
) {
    init {
        require(maxAttempts in MIN_RETRY_ATTEMPTS..MAX_RETRY_ATTEMPTS) {
            "Retry attempts must be between $MIN_RETRY_ATTEMPTS and $MAX_RETRY_ATTEMPTS."
        }
    }

    private var startedAt = -1L
    private var attempts = 0
    private var pausedAt = -1L
    private var pausedDuration = 0L
    internal val retryWindowMs = maxOf(
        MINIMUM_WINDOW_MS,
        delays(backoff).take(maxAttempts).sum() + ATTEMPT_ALLOWANCE_MS * maxAttempts,
    )
    val attemptCount: Int get() = attempts

    fun nextDelay(now: Long): Long? {
        if (!enabled || attempts >= maxAttempts) return null
        val currentPause = if (pausedAt >= 0) now - pausedAt else 0L
        if (startedAt >= 0 && now - startedAt - pausedDuration - currentPause > retryWindowMs) return null
        return delays(backoff)[attempts]
    }

    fun beginAttempt(now: Long): Boolean {
        if (nextDelay(now) == null) return false
        if (startedAt < 0) startedAt = now
        attempts++
        return true
    }

    fun reset() {
        startedAt = -1L
        attempts = 0
        pausedAt = -1L
        pausedDuration = 0L
    }

    fun pause(now: Long) {
        if (startedAt >= 0 && pausedAt < 0) pausedAt = now
    }

    fun resume(now: Long) {
        if (pausedAt < 0) return
        pausedDuration += now - pausedAt
        pausedAt = -1L
    }

    companion object {
        internal val BALANCED_DELAYS_MS = longArrayOf(
            0L, 2_000L, 5_000L, 10_000L, 20_000L, 30_000L, 30_000L, 30_000L, 30_000L, 30_000L,
        )
        private const val MINIMUM_WINDOW_MS = 120_000L
        private const val ATTEMPT_ALLOWANCE_MS = 30_000L

        private val FAST_DELAYS_MS = longArrayOf(
            0L, 1_000L, 2_000L, 3_000L, 5_000L, 8_000L, 13_000L, 20_000L, 30_000L, 30_000L,
        )
        private val CONSERVATIVE_DELAYS_MS = longArrayOf(
            0L, 5_000L, 15_000L, 30_000L, 60_000L, 60_000L, 60_000L, 60_000L, 60_000L, 60_000L,
        )

        private fun delays(backoff: RetryBackoff): LongArray = when (backoff) {
            RetryBackoff.FAST -> FAST_DELAYS_MS
            RetryBackoff.BALANCED -> BALANCED_DELAYS_MS
            RetryBackoff.CONSERVATIVE -> CONSERVATIVE_DELAYS_MS
        }
    }
}
