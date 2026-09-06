package dev.ghostty.connect.data

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class TerminalArchiveTest {
    @Test fun roundTripDoesNotExposePlaintext() {
        val plain = "private terminal output\n".toByteArray()
        val password = "correct horse battery staple".toCharArray()
        val archive = TerminalArchive.encrypt(plain, password)

        assertFalse(archive.toString(Charsets.ISO_8859_1).contains("private terminal output"))
        assertArrayEquals(plain, TerminalArchive.decrypt(archive, password))
    }

    @Test(expected = Exception::class)
    fun modifiedCiphertextIsRejected() {
        val archive = TerminalArchive.encrypt("output".toByteArray(), "long archive password".toCharArray())
        archive[archive.lastIndex] = (archive.last().toInt() xor 1).toByte()
        TerminalArchive.decrypt(archive, "long archive password".toCharArray())
    }

    @Test(expected = IllegalArgumentException::class)
    fun shortPassphraseIsRejected() {
        TerminalArchive.encrypt(byteArrayOf(), "short".toCharArray())
    }
}
