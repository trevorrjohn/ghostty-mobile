package dev.ghostty.connect.sftp

import com.hierynomus.sshj.common.KeyDecryptionFailedException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.io.EOFException
import net.schmizz.sshj.common.SSHException
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPException
import net.schmizz.sshj.userauth.UserAuthException

internal fun sftpFailureMessage(error: Throwable): String {
    val causes = generateSequence(error) { it.cause }.toList()
    val status = causes.filterIsInstance<SFTPException>().firstOrNull()?.statusCode
    return when {
        causes.any { it is UserAuthException || it is KeyDecryptionFailedException } ->
            "Authentication was rejected, canceled, or timed out."
        status == Response.StatusCode.PERMISSION_DENIED -> "Permission was denied."
        status == Response.StatusCode.NO_SUCH_FILE || status == Response.StatusCode.NO_SUCH_PATH ->
            "The file or directory no longer exists."
        status == Response.StatusCode.FILE_ALREADY_EXISTS -> "A destination already exists."
        status == Response.StatusCode.DIR_NOT_EMPTY -> "The directory is not empty."
        status == Response.StatusCode.OP_UNSUPPORTED -> "The server does not support this SFTP operation."
        causes.any { cause ->
            cause.message?.contains("subsystem", ignoreCase = true) == true ||
                cause.message?.contains("sftp", ignoreCase = true) == true &&
                cause.message?.contains("request failed", ignoreCase = true) == true
        } -> "The server does not provide the SFTP subsystem."
        causes.any {
            it is SocketTimeoutException || it is ConnectException || it is NoRouteToHostException ||
                it is UnknownHostException || it is SocketException
        } -> "The network connection was interrupted."
        else -> "The operation failed for an unexpected reason."
    }
}

internal fun isSftpConnectionFailure(error: Throwable): Boolean {
    val causes = generateSequence(error) { it.cause }.toList()
    val status = causes.filterIsInstance<SFTPException>().firstOrNull()?.statusCode
    return status == Response.StatusCode.CONNECITON_LOST || status == Response.StatusCode.NO_CONNECTION ||
        causes.any {
            it is SocketTimeoutException || it is ConnectException || it is NoRouteToHostException ||
                it is UnknownHostException || it is SocketException || it is EOFException ||
                it is SSHException && it !is SFTPException
        }
}
