package dev.ghostty.connect.data

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream

class PrivateKeyImportTest {
    @Test
    fun `preserves pasted key text`() {
        val text = "-----BEGIN OPENSSH PRIVATE KEY-----\nvalue\n-----END OPENSSH PRIVATE KEY-----"
        assertArrayEquals(text.toByteArray(), privateKeyImportBytes(text))
    }

    @Test
    fun `rejects text without a private key marker`() {
        assertThrows(IllegalArgumentException::class.java) { privateKeyImportBytes("ssh-ed25519 public-key") }
    }

    @Test
    fun `rejects oversized pasted keys`() {
        val text = "-----BEGIN PRIVATE KEY-----" + "a".repeat(MAX_PRIVATE_KEY_BYTES)
        assertThrows(IllegalArgumentException::class.java) { privateKeyImportBytes(text) }
    }

    @Test
    fun `reads a bounded private key file`() {
        val bytes = "-----BEGIN PRIVATE KEY-----\nvalue".toByteArray()
        assertArrayEquals(bytes, readPrivateKeyBytes(ByteArrayInputStream(bytes)))
    }

    @Test
    fun `rejects oversized private key files`() {
        val bytes = ByteArray(MAX_PRIVATE_KEY_BYTES + 1)
        assertThrows(IllegalArgumentException::class.java) {
            readPrivateKeyBytes(ByteArrayInputStream(bytes))
        }
    }

    @Test
    fun `rejects malformed UTF-8 key files`() {
        assertThrows(IllegalArgumentException::class.java) { decodePrivateKeyText(byteArrayOf(0xc3.toByte())) }
    }
}
