package dev.ghostty.connect.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.nio.ByteBuffer
import java.security.KeyStore
import java.io.File
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class EncryptedFileStore(
    private val context: Context,
    private val keyAlias: String = "ghostty-connect-key-encryption",
) {
    fun write(fileName: String, value: ByteArray) = withFileLock(fileName) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(value)
        val payload = ByteBuffer.allocate(4 + cipher.iv.size + encrypted.size)
            .putInt(cipher.iv.size)
            .put(cipher.iv)
            .put(encrypted)
            .array()
        val file = atomicFile(fileName)
        val output = file.startWrite()
        try {
            output.write(payload)
            file.finishWrite(output)
        } catch (error: Throwable) {
            file.failWrite(output)
            throw error
        }
    }

    fun read(fileName: String): ByteArray = withFileLock(fileName) {
        val payload = atomicFile(fileName).openRead().use { it.readBytes() }
        require(payload.size >= 4 + MIN_IV_BYTES + GCM_TAG_BYTES) { "Encrypted file is truncated." }
        val buffer = ByteBuffer.wrap(payload)
        val ivSize = buffer.int
        require(ivSize in MIN_IV_BYTES..MAX_IV_BYTES && ivSize <= buffer.remaining() - GCM_TAG_BYTES) {
            "Encrypted file has invalid framing."
        }
        val iv = ByteArray(ivSize).also(buffer::get)
        val encrypted = ByteArray(buffer.remaining()).also(buffer::get)
        Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            doFinal(encrypted)
        }
    }

    fun exists(fileName: String): Boolean = withFileLock(fileName) {
        atomicFile(fileName).baseFile.let { base ->
            base.exists() || File("${base.path}.bak").exists()
        }
    }

    fun delete(fileName: String) = withFileLock(fileName) { atomicFile(fileName).delete() }

    internal fun <T> withFileLock(fileName: String, action: () -> T): T =
        synchronized(fileLocks[fileLockIndex(fileName)], action)

    private fun atomicFile(fileName: String) = AtomicFile(context.getFileStreamPath(fileName))

    private fun secretKey(): SecretKey = synchronized(keyLocks[keyLockIndex(keyAlias)]) {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return@synchronized it }
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    keyAlias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
            generateKey()
        }
    }

    private fun fileLockIndex(fileName: String): Int =
        (context.getFileStreamPath(fileName).canonicalPath.hashCode() and Int.MAX_VALUE) % fileLocks.size

    private fun keyLockIndex(alias: String): Int = (alias.hashCode() and Int.MAX_VALUE) % keyLocks.size

    companion object {
        private const val MIN_IV_BYTES = 12
        private const val MAX_IV_BYTES = 16
        private const val GCM_TAG_BYTES = 16
        private val fileLocks = Array(64) { Any() }
        private val keyLocks = Array(16) { Any() }
    }
}
