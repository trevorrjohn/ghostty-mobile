package dev.ghostty.connect.terminal

import com.hierynomus.sshj.common.KeyDecryptionFailedException
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
            DisconnectReason.UNKNOWN -> Unit
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

internal class ReconnectPolicy {
    private var startedAt = -1L
    private var attempts = 0

    fun nextDelay(now: Long): Long? {
        if (attempts >= DELAYS_MS.size) return null
        if (startedAt >= 0 && now - startedAt > WINDOW_MS) return null
        return DELAYS_MS[attempts]
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
    }

    companion object {
        internal val DELAYS_MS = longArrayOf(0L, 2_000L, 5_000L, 10_000L, 20_000L)
        internal const val WINDOW_MS = 120_000L
    }
}
