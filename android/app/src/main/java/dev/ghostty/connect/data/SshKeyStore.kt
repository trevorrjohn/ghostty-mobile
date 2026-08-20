package dev.ghostty.connect.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.nio.ByteBuffer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SshKeyStore(private val context: Context) {
    private val preferences = context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE)
    private val alias = "ghostty-connect-key-encryption"

    fun names(): List<String> = preferences.getStringSet("names", emptySet()).orEmpty().sorted()

    fun import(name: String, privateKey: ByteArray) {
        require(privateKey.size <= 1024 * 1024) { "Private key is too large" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val encrypted = cipher.doFinal(privateKey)
        val payload = ByteBuffer.allocate(4 + cipher.iv.size + encrypted.size)
            .putInt(cipher.iv.size).put(cipher.iv).put(encrypted).array()
        val safeName = name.trim().ifBlank { "SSH key" }
        context.openFileOutput(fileName(safeName), Context.MODE_PRIVATE).use { it.write(payload) }
        preferences.edit().putStringSet("names", names().toSet() + safeName).apply()
    }

    fun read(name: String): ByteArray {
        val payload = context.openFileInput(fileName(name)).use { it.readBytes() }
        val buffer = ByteBuffer.wrap(payload)
        val iv = ByteArray(buffer.int).also(buffer::get)
        val encrypted = ByteArray(buffer.remaining()).also(buffer::get)
        return Cipher.getInstance("AES/GCM/NoPadding").run {
            init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
            doFinal(encrypted)
        }
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
            generateKey()
        }
    }

    private fun fileName(name: String) = "ssh-key-${name.hashCode().toUInt().toString(16)}.enc"
}

