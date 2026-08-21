package dev.ghostty.connect.sftp

import java.net.SocketTimeoutException
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPException
import net.schmizz.sshj.userauth.UserAuthException
import org.junit.Assert.assertEquals
import org.junit.Test

class SftpFailureTest {
    @Test
    fun mapsProtocolFailuresToActionableLanguage() {
        assertEquals(
            "Permission was denied.",
            sftpFailureMessage(SFTPException(Response.StatusCode.PERMISSION_DENIED, "private server detail")),
        )
        assertEquals(
            "The directory is not empty.",
            sftpFailureMessage(SFTPException(Response.StatusCode.DIR_NOT_EMPTY, "private server detail")),
        )
    }

    @Test
    fun mapsAuthenticationAndNetworkWithoutRawDetails() {
        assertEquals(
            "Authentication was rejected, canceled, or timed out.",
            sftpFailureMessage(UserAuthException("secret server detail")),
        )
        assertEquals(
            "The network connection was interrupted.",
            sftpFailureMessage(SocketTimeoutException("private destination")),
        )
    }

    @Test
    fun mapsMissingSubsystem() {
        assertEquals(
            "The server does not provide the SFTP subsystem.",
            sftpFailureMessage(IllegalStateException("SFTP subsystem request failed")),
        )
    }
}
