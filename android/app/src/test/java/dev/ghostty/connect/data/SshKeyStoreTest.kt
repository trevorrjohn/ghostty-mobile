package dev.ghostty.connect.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.util.Base64

class SshKeyStoreTest {
    @Test
    fun `uses OpenSSH comment for unencrypted key`() {
        val details = inspectSshPrivateKey(openSshKey(cipher = "none", comment = "tj@workstation"))

        assertEquals("tj@workstation", details.suggestedName)
        assertFalse(details.requiresPassphrase)
    }

    @Test
    fun `detects encrypted OpenSSH key and fingerprints its public key`() {
        val details = inspectSshPrivateKey(openSshKey(cipher = "aes256-ctr", comment = null))

        assertTrue(details.suggestedName.startsWith("Ed25519 key "))
        assertTrue(details.requiresPassphrase)
        assertEquals("ssh-ed25519", details.algorithm)
        assertTrue(details.fingerprint?.startsWith("SHA256:") == true)
        assertTrue(details.publicKey?.startsWith("ssh-ed25519 ") == true)
        assertFalse(details.publicKey?.contains("PRIVATE KEY") == true)
    }

    @Test
    fun `detects encrypted PEM and avoids duplicate names`() {
        val key = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n"

        val details = inspectSshPrivateKey(key.toByteArray(), listOf("Encrypted key"))

        assertEquals("Encrypted key 2", details.suggestedName)
        assertTrue(details.requiresPassphrase)
    }

    @Test
    fun `suggested names avoid case insensitive duplicates`() {
        val details = inspectSshPrivateKey(
            openSshKey(cipher = "none", comment = "Work"),
            listOf("work", "Work 2"),
        )

        assertEquals("Work 3", details.suggestedName)
    }

    @Test
    fun `legacy hash collision remains detectable during migration`() {
        assertEquals("Aa".hashCode(), "BB".hashCode())
        assertEquals(legacyIdentityFileName("Aa"), legacyIdentityFileName("BB"))
    }

    private fun openSshKey(cipher: String, comment: String?): ByteArray {
        val algorithm = "ssh-ed25519".toByteArray()
        val publicKey = encoded {
            sshString(algorithm)
            sshString(ByteArray(32) { it.toByte() })
        }
        val privateBlock = encoded {
            writeInt(0x12345678)
            writeInt(0x12345678)
            sshString(algorithm)
            sshString(ByteArray(32))
            sshString(ByteArray(64))
            sshString(comment.orEmpty().toByteArray())
        }
        val payload = encoded {
            write("openssh-key-v1\u0000".toByteArray())
            sshString(cipher.toByteArray())
            sshString(if (cipher == "none") "none".toByteArray() else "bcrypt".toByteArray())
            sshString(byteArrayOf())
            writeInt(1)
            sshString(publicKey)
            sshString(privateBlock)
        }
        val encoded = Base64.getMimeEncoder(70, "\n".toByteArray()).encodeToString(payload)
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n$encoded\n-----END OPENSSH PRIVATE KEY-----\n".toByteArray()
    }

    private fun encoded(write: DataOutputStream.() -> Unit): ByteArray =
        ByteArrayOutputStream().also { output -> DataOutputStream(output).use(write) }.toByteArray()

    private fun DataOutputStream.sshString(value: ByteArray) {
        writeInt(value.size)
        write(value)
    }
}
