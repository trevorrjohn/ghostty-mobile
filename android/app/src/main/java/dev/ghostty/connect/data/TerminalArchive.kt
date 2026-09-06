package dev.ghostty.connect.data

import org.bouncycastle.crypto.generators.Argon2BytesGenerator
import org.bouncycastle.crypto.params.Argon2Parameters
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object TerminalArchive {
    private const val MAGIC = 0x47544131 // GTA1
    private const val VERSION = 1
    private const val MEMORY_KIB = 64 * 1024
    private const val ITERATIONS = 3
    private const val PARALLELISM = 1
    private const val MAX_PLAINTEXT_BYTES = 32 * 1024 * 1024
    private const val SALT_BYTES = 16
    private const val NONCE_BYTES = 12
    private const val KEY_BYTES = 32

    fun encrypt(plainText: ByteArray, passphrase: CharArray, random: SecureRandom = SecureRandom()): ByteArray {
        require(plainText.size <= MAX_PLAINTEXT_BYTES) { "Terminal archive is too large" }
        require(passphrase.size >= 10) { "Passphrase must be at least 10 characters" }
        val salt = ByteArray(SALT_BYTES).also(random::nextBytes)
        val nonce = ByteArray(NONCE_BYTES).also(random::nextBytes)
        val header = ByteArrayOutputStream().also { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(MAGIC)
                output.writeInt(VERSION)
                output.writeInt(MEMORY_KIB)
                output.writeInt(ITERATIONS)
                output.writeInt(PARALLELISM)
                output.writeInt(salt.size)
                output.write(salt)
                output.writeInt(nonce.size)
                output.write(nonce)
            }
        }.toByteArray()
        val key = ByteArray(KEY_BYTES)
        try {
            Argon2BytesGenerator().apply {
                init(Argon2Parameters.Builder(Argon2Parameters.ARGON2_id)
                    .withVersion(Argon2Parameters.ARGON2_VERSION_13)
                    .withMemoryAsKB(MEMORY_KIB)
                    .withIterations(ITERATIONS)
                    .withParallelism(PARALLELISM)
                    .withSalt(salt)
                    .build())
                generateBytes(passphrase, key)
            }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
            cipher.updateAAD(header)
            val encrypted = cipher.doFinal(plainText)
            return header + encrypted
        } finally {
            key.fill(0)
            salt.fill(0)
            nonce.fill(0)
        }
    }

    internal fun decrypt(archive: ByteArray, passphrase: CharArray): ByteArray {
        require(archive.size <= MAX_PLAINTEXT_BYTES + 128) { "Terminal archive is too large" }
        val input = DataInputStream(ByteArrayInputStream(archive))
        require(input.readInt() == MAGIC && input.readInt() == VERSION) { "Unsupported terminal archive" }
        require(input.readInt() == MEMORY_KIB && input.readInt() == ITERATIONS && input.readInt() == PARALLELISM) {
            "Unsupported terminal archive parameters"
        }
        val salt = ByteArray(input.readInt().also { require(it == SALT_BYTES) }).also(input::readFully)
        val nonce = ByteArray(input.readInt().also { require(it == NONCE_BYTES) }).also(input::readFully)
        val headerLength = archive.size - input.available()
        val encrypted = ByteArray(input.available()).also(input::readFully)
        require(encrypted.size >= 16) { "Invalid terminal archive" }
        val key = ByteArray(KEY_BYTES)
        try {
            Argon2BytesGenerator().apply {
                init(Argon2Parameters.Builder(Argon2Parameters.ARGON2_id)
                    .withVersion(Argon2Parameters.ARGON2_VERSION_13).withMemoryAsKB(MEMORY_KIB)
                    .withIterations(ITERATIONS).withParallelism(PARALLELISM).withSalt(salt).build())
                generateBytes(passphrase, key)
            }
            return Cipher.getInstance("AES/GCM/NoPadding").run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
                updateAAD(archive, 0, headerLength)
                doFinal(encrypted)
            }
        } finally {
            key.fill(0); salt.fill(0); nonce.fill(0); encrypted.fill(0)
        }
    }
}
