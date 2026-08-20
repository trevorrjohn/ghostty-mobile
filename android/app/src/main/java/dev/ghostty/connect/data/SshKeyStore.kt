package dev.ghostty.connect.data

import android.content.Context
import android.util.Base64
import org.json.JSONArray
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

class SshKeyStore(private val context: Context) {
    private val preferences = context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE)
    private val encryptedStore = EncryptedFileStore(context)

    fun names(): List<String> {
        if (encryptedStore.exists(INDEX_FILE)) {
            val array = JSONArray(encryptedStore.read(INDEX_FILE).toString(Charsets.UTF_8))
            return List(array.length(), array::getString).sorted()
        }
        val migrated = preferences.getStringSet("names", emptySet()).orEmpty().sorted()
        if (migrated.isNotEmpty()) {
            saveNames(migrated)
            preferences.edit().clear().apply()
        }
        return migrated
    }

    fun import(name: String, privateKey: ByteArray) {
        require(privateKey.size <= 1024 * 1024) { "Private key is too large" }
        val safeName = name.trim().ifBlank { "SSH key" }
        encryptedStore.write(fileName(safeName), privateKey)
        saveNames((names() + safeName).distinct())
    }

    fun read(name: String): ByteArray = encryptedStore.read(fileName(name))

    fun requiresPassphrase(name: String): Boolean = inspect(read(name)).requiresPassphrase

    fun inspect(privateKey: ByteArray): SshKeyDetails {
        val text = privateKey.toString(Charsets.UTF_8)
        val openSsh = parseOpenSsh(text)
        val encrypted = when {
            openSsh != null -> openSsh.cipher != "none"
            text.contains("BEGIN ENCRYPTED PRIVATE KEY") -> true
            text.contains("BEGIN SSH2 ENCRYPTED PRIVATE KEY") -> true
            text.contains("Proc-Type: 4,ENCRYPTED", ignoreCase = true) -> true
            text.contains("DEK-Info:", ignoreCase = true) -> true
            else -> false
        }
        val baseName = openSsh?.comment?.takeIf { it.isUsefulKeyComment() }
            ?: openSsh?.let { "${displayAlgorithm(it.algorithm)} ${it.fingerprint}" }
            ?: when {
                text.contains("BEGIN RSA PRIVATE KEY") -> "RSA key"
                text.contains("BEGIN EC PRIVATE KEY") -> "ECDSA key"
                text.contains("BEGIN DSA PRIVATE KEY") -> "DSA key"
                text.contains("BEGIN ENCRYPTED PRIVATE KEY") -> "Encrypted key"
                text.contains("BEGIN PRIVATE KEY") -> "PKCS#8 key"
                else -> "SSH key"
            }
        return SshKeyDetails(uniqueName(baseName.take(80)), encrypted)
    }

    private fun saveNames(names: List<String>) {
        encryptedStore.write(INDEX_FILE, JSONArray(names).toString().toByteArray())
    }

    private fun fileName(name: String) = "ssh-key-${name.hashCode().toUInt().toString(16)}.enc"

    private fun uniqueName(base: String): String {
        val existing = names().toSet()
        if (base !in existing) return base
        var suffix = 2
        while ("$base $suffix" in existing) suffix++
        return "$base $suffix"
    }

    private fun parseOpenSsh(text: String): OpenSshDetails? = runCatching {
        val encoded = text.substringAfter("-----BEGIN OPENSSH PRIVATE KEY-----", "")
            .substringBefore("-----END OPENSSH PRIVATE KEY-----", "")
            .filterNot(Char::isWhitespace)
        if (encoded.isEmpty()) return null
        val input = ByteBuffer.wrap(Base64.decode(encoded, Base64.DEFAULT)).order(ByteOrder.BIG_ENDIAN)
        val magic = ByteArray(15).also(input::get).toString(Charsets.US_ASCII)
        require(magic == "openssh-key-v1\u0000")
        val cipher = input.readSshString().toString(Charsets.US_ASCII)
        input.readSshString() // KDF name
        input.readSshString() // KDF options
        val keyCount = input.int
        require(keyCount in 1..16)
        val publicKeys = List(keyCount) { input.readSshString() }
        val privateBlock = input.readSshString()
        val publicKey = publicKeys.first()
        val algorithm = ByteBuffer.wrap(publicKey).order(ByteOrder.BIG_ENDIAN)
            .readSshString().toString(Charsets.US_ASCII)
        val fingerprint = Base64.encodeToString(
            MessageDigest.getInstance("SHA-256").digest(publicKey),
            Base64.NO_WRAP or Base64.NO_PADDING,
        ).take(12)
        val comment = if (cipher == "none") parseOpenSshComment(privateBlock, algorithm) else null
        OpenSshDetails(cipher, algorithm, fingerprint, comment)
    }.getOrNull()

    private fun parseOpenSshComment(block: ByteArray, algorithm: String): String? = runCatching {
        val input = ByteBuffer.wrap(block).order(ByteOrder.BIG_ENDIAN)
        require(input.int == input.int)
        require(input.readSshString().toString(Charsets.US_ASCII) == algorithm)
        val fieldCount = when {
            algorithm == "ssh-ed25519" -> 2
            algorithm == "ssh-rsa" -> 6
            algorithm == "ssh-dss" -> 5
            algorithm.startsWith("ecdsa-sha2-") -> 3
            else -> return null
        }
        repeat(fieldCount) { input.readSshString() }
        input.readSshString().toString(Charsets.UTF_8).trim().takeIf(String::isNotEmpty)
    }.getOrNull()

    private fun ByteBuffer.readSshString(): ByteArray {
        val length = int
        require(length in 0..remaining())
        return ByteArray(length).also(::get)
    }

    private fun String.isUsefulKeyComment(): Boolean = isNotBlank() && length <= 80 &&
        none { it.isISOControl() } && this != "no comment"

    private fun displayAlgorithm(value: String): String = when {
        value == "ssh-ed25519" -> "Ed25519 key"
        value == "ssh-rsa" -> "RSA key"
        value == "ssh-dss" -> "DSA key"
        value.startsWith("ecdsa-") -> "ECDSA key"
        else -> "SSH key"
    }

    companion object {
        private const val INDEX_FILE = "ssh-key-index.enc"
    }
}

data class SshKeyDetails(
    val suggestedName: String,
    val requiresPassphrase: Boolean,
)

private data class OpenSshDetails(
    val cipher: String,
    val algorithm: String,
    val fingerprint: String,
    val comment: String?,
)
