package dev.ghostty.connect.data

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class BiometricIdentityStore(private val context: Context) {
    fun prepareEncryption(identityId: String) {
        val id = canonicalId(identityId)
        deleteKey(id)
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val builder = KeyGenParameterSpec.Builder(
            alias(id),
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(false)
        if (Build.VERSION.SDK_INT >= 30) {
            // Some newer KeyMint implementations reject operation-bound tokens. The app
            // still requires a fresh strong-biometric prompt before opening this window.
            builder.setUserAuthenticationParameters(
                AUTH_VALIDITY_SECONDS,
                KeyProperties.AUTH_BIOMETRIC_STRONG,
            )
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(AUTH_VALIDITY_SECONDS)
        }
        generator.init(builder.build())
        generator.generateKey()
    }

    fun encryptionCipher(identityId: String): Cipher {
        val id = canonicalId(identityId)
        return Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, key(id))
            updateAAD(aad(id, CURRENT_FORMAT_VERSION))
        }
    }

    fun decryptionCipher(identityId: String): Cipher {
        val id = canonicalId(identityId)
        val blob = readBlob(id)
        return try {
            Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, key(id), GCMParameterSpec(GCM_TAG_BITS, blob.iv))
                updateAAD(aad(id, blob.version))
            }
        } finally {
            blob.ciphertext.fill(0)
            blob.iv.fill(0)
        }
    }

    fun encrypt(identityId: String, cipher: Cipher, plaintext: ByteArray) {
        val id = canonicalId(identityId)
        val ciphertext = cipher.doFinal(plaintext)
        val file = AtomicFile(blobFile(id))
        val output = file.startWrite()
        try {
            val data = DataOutputStream(output)
            data.writeInt(CURRENT_FORMAT_VERSION)
            data.writeInt(cipher.iv.size)
            data.write(cipher.iv)
            data.writeInt(ciphertext.size)
            data.write(ciphertext)
            data.flush()
            file.finishWrite(output)
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        } finally {
            ciphertext.fill(0)
        }
    }

    fun decrypt(identityId: String, cipher: Cipher): ByteArray {
        val id = canonicalId(identityId)
        val blob = readBlob(id)
        return try {
            cipher.doFinal(blob.ciphertext)
        } finally {
            blob.ciphertext.fill(0)
            blob.iv.fill(0)
        }
    }

    fun delete(identityId: String) {
        val id = canonicalId(identityId)
        AtomicFile(blobFile(id)).delete()
        deleteKey(id)
    }

    fun exists(identityId: String): Boolean = AtomicFile(blobFile(canonicalId(identityId))).baseFile.exists()

    fun usesAuthenticationWindow(identityId: String): Boolean {
        val blob = readBlob(canonicalId(identityId))
        return try {
            blob.version >= AUTH_WINDOW_FORMAT_VERSION
        } finally {
            blob.ciphertext.fill(0)
            blob.iv.fill(0)
        }
    }

    fun deleteKey(identityId: String) {
        val id = canonicalId(identityId)
        keyStore().deleteEntry(alias(id))
    }

    private fun readBlob(identityId: String): BiometricBlob {
        val file = AtomicFile(blobFile(identityId))
        DataInputStream(file.openRead()).use { input ->
            val version = input.readInt()
            require(version in 1..CURRENT_FORMAT_VERSION) { "Unsupported biometric identity format." }
            val ivSize = input.readInt()
            require(ivSize in 12..32) { "Biometric identity data is invalid." }
            val iv = ByteArray(ivSize).also(input::readFully)
            val ciphertextSize = input.readInt()
            require(ciphertextSize in 16..MAX_PRIVATE_KEY_BYTES + 32) { "Biometric identity data is invalid." }
            val ciphertext = ByteArray(ciphertextSize).also(input::readFully)
            require(input.read() == -1) { "Biometric identity data is invalid." }
            return BiometricBlob(version, ciphertext, iv)
        }
    }

    private fun key(identityId: String): SecretKey =
        keyStore().getKey(alias(identityId), null) as? SecretKey
            ?: error("Biometric protection is unavailable. Reimport this identity.")

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun blobFile(identityId: String) = context.filesDir.resolve("ssh-identity-$identityId.biometric")
    private fun alias(identityId: String) = "ghostty-connect-biometric-identity-$identityId"
    private fun aad(identityId: String, version: Int) = "${context.packageName}:$version:$identityId".toByteArray()
    private fun canonicalId(identityId: String) = UUID.fromString(identityId).toString().also {
        require(it == identityId) { "Identity ID is invalid." }
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val CURRENT_FORMAT_VERSION = 2
        private const val AUTH_WINDOW_FORMAT_VERSION = 2
        private const val GCM_TAG_BITS = 128
        private const val AUTH_VALIDITY_SECONDS = 5
        private const val MAX_PRIVATE_KEY_BYTES = 1024 * 1024
    }
}

private data class BiometricBlob(val version: Int, val ciphertext: ByteArray, val iv: ByteArray)
