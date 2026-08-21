package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.SshIdentity
import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

class SshKeyStore(private val context: Context) {
    private val preferences = context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE)
    private val encryptedStore = EncryptedFileStore(context)

    fun identities(): List<SshIdentity> = synchronized(STORE_LOCK) {
        loadOrMigrateIdentities()
    }

    fun identity(id: String): SshIdentity? = synchronized(STORE_LOCK) {
        loadOrMigrateIdentities().firstOrNull { it.id == id }
    }

    fun import(name: String, privateKey: ByteArray): SshIdentity = synchronized(STORE_LOCK) {
        require(privateKey.size <= 1024 * 1024) { "Private key is too large" }
        val identities = loadOrMigrateIdentities()
        val details = inspectSshPrivateKey(privateKey)
        val requestedName = name.trim().ifBlank { details.suggestedName }.take(80)
        val identity = details.toIdentity(
            id = UUID.randomUUID().toString(),
            name = uniqueName(requestedName, identities.map(SshIdentity::name)),
        )
        encryptedStore.write(identityFileName(identity.id), privateKey)
        saveIdentities((identities + identity).sortedBy { it.name.lowercase() })
        identity
    }

    fun read(identityId: String): ByteArray = synchronized(STORE_LOCK) {
        require(loadOrMigrateIdentities().any { it.id == identityId }) { "SSH identity does not exist." }
        encryptedStore.read(identityFileName(canonicalIdentityId(identityId)))
    }

    fun requiresPassphrase(identityId: String): Boolean = synchronized(STORE_LOCK) {
        loadOrMigrateIdentities().firstOrNull { it.id == identityId }?.requiresPassphrase
            ?: error("SSH identity does not exist.")
    }

    fun inspect(privateKey: ByteArray): SshKeyDetails = synchronized(STORE_LOCK) {
        inspectSshPrivateKey(privateKey, loadOrMigrateIdentities().map(SshIdentity::name))
    }

    internal fun resolveLegacyName(name: String): SshIdentity? = synchronized(STORE_LOCK) {
        val identities = loadOrMigrateIdentities()
        identities.firstOrNull { it.name == name }?.let { return@synchronized it }
        val legacyFile = legacyIdentityFileName(name)
        if (!encryptedStore.exists(legacyFile)) return@synchronized null
        require(identities.none { it.name != name && legacyIdentityFileName(it.name) == legacyFile }) {
            "Legacy SSH identity names have an ambiguous key-file collision."
        }
        val privateKey = encryptedStore.read(legacyFile)
        val identity = inspectSshPrivateKey(privateKey).toIdentity(UUID.randomUUID().toString(), name)
        encryptedStore.write(identityFileName(identity.id), privateKey)
        saveIdentities((identities + identity).sortedBy { it.name.lowercase() })
        identity
    }

    private fun loadOrMigrateIdentities(): List<SshIdentity> {
        if (encryptedStore.exists(IDENTITY_INDEX_FILE)) {
            return decodeIdentities(encryptedStore.read(IDENTITY_INDEX_FILE))
        }
        val migrated = legacyNames().map { name ->
            val privateKey = encryptedStore.read(legacyIdentityFileName(name))
            val identity = inspectSshPrivateKey(privateKey).toIdentity(UUID.randomUUID().toString(), name)
            encryptedStore.write(identityFileName(identity.id), privateKey)
            identity
        }
        saveIdentities(migrated)
        return migrated
    }

    private fun legacyNames(): List<String> {
        val names = if (encryptedStore.exists(LEGACY_INDEX_FILE)) {
            val values = JSONArray(encryptedStore.read(LEGACY_INDEX_FILE).toString(Charsets.UTF_8))
            List(values.length(), values::getString)
        } else {
            preferences.getStringSet("names", emptySet()).orEmpty().toList()
        }
        require(names.size == names.distinct().size) { "Legacy SSH identity names are ambiguous." }
        require(names.map(::legacyIdentityFileName).distinct().size == names.size) {
            "Legacy SSH identity names have an ambiguous key-file collision."
        }
        return names.sorted()
    }

    private fun saveIdentities(identities: List<SshIdentity>) {
        val root = JSONObject().apply {
            put("version", IDENTITY_INDEX_VERSION)
            put("identities", JSONArray().apply {
                identities.forEach { identity ->
                    put(JSONObject().apply {
                        put("id", identity.id)
                        put("name", identity.name)
                        put("algorithm", identity.algorithm ?: JSONObject.NULL)
                        put("fingerprint", identity.fingerprint ?: JSONObject.NULL)
                        put("requiresPassphrase", identity.requiresPassphrase)
                        put("publicKey", identity.publicKey ?: JSONObject.NULL)
                    })
                }
            })
        }
        encryptedStore.write(IDENTITY_INDEX_FILE, root.toString().toByteArray())
    }

    private fun decodeIdentities(bytes: ByteArray): List<SshIdentity> {
        val root = JSONObject(bytes.toString(Charsets.UTF_8))
        require(root.getInt("version") == IDENTITY_INDEX_VERSION) { "Unsupported SSH identity data version." }
        val values = root.getJSONArray("identities")
        val identities = buildList {
            for (index in 0 until values.length()) {
                val value = values.getJSONObject(index)
                val identity = SshIdentity(
                    id = canonicalIdentityId(value.getString("id")),
                    name = value.getString("name").also { require(it.isNotBlank()) },
                    algorithm = value.optionalString("algorithm"),
                    fingerprint = value.optionalString("fingerprint"),
                    requiresPassphrase = value.getBoolean("requiresPassphrase"),
                    publicKey = value.optionalString("publicKey"),
                )
                require(encryptedStore.exists(identityFileName(identity.id))) { "SSH identity key data is missing." }
                add(identity)
            }
        }
        require(identities.map(SshIdentity::id).distinct().size == identities.size) {
            "SSH identity IDs are duplicated."
        }
        return identities.sortedBy { it.name.lowercase() }
    }

    private fun JSONObject.optionalString(name: String): String? =
        optString(name).takeIf { !isNull(name) && it.isNotBlank() }

    private fun canonicalIdentityId(id: String): String = UUID.fromString(id).toString().also {
        require(it == id) { "SSH identity ID is not canonical." }
    }

    private fun identityFileName(id: String) = "ssh-identity-${canonicalIdentityId(id)}.enc"

    companion object {
        private const val IDENTITY_INDEX_FILE = "ssh-identity-index.enc"
        private const val LEGACY_INDEX_FILE = "ssh-key-index.enc"
        private const val IDENTITY_INDEX_VERSION = 1
        private val STORE_LOCK = Any()
    }
}

internal fun legacyIdentityFileName(name: String) = "ssh-key-${name.hashCode().toUInt().toString(16)}.enc"

internal fun inspectSshPrivateKey(privateKey: ByteArray, existingNames: Collection<String> = emptyList()): SshKeyDetails {
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
        ?: openSsh?.let { "${displayAlgorithm(it.algorithm)} ${it.fingerprint.removePrefix("SHA256:").take(12)}" }
        ?: when {
            text.contains("BEGIN RSA PRIVATE KEY") -> "RSA key"
            text.contains("BEGIN EC PRIVATE KEY") -> "ECDSA key"
            text.contains("BEGIN DSA PRIVATE KEY") -> "DSA key"
            text.contains("BEGIN ENCRYPTED PRIVATE KEY") -> "Encrypted key"
            text.contains("BEGIN PRIVATE KEY") -> "PKCS#8 key"
            else -> "SSH key"
        }
    val algorithm = openSsh?.algorithm ?: when {
        text.contains("BEGIN RSA PRIVATE KEY") -> "RSA"
        text.contains("BEGIN EC PRIVATE KEY") -> "ECDSA"
        text.contains("BEGIN DSA PRIVATE KEY") -> "DSA"
        text.contains("BEGIN ENCRYPTED PRIVATE KEY") || text.contains("BEGIN PRIVATE KEY") -> "PKCS#8"
        else -> null
    }
    return SshKeyDetails(
        suggestedName = uniqueName(baseName.take(80), existingNames),
        requiresPassphrase = encrypted,
        algorithm = algorithm,
        fingerprint = openSsh?.fingerprint,
        publicKey = openSsh?.publicKey,
    )
}

private fun uniqueName(base: String, names: Collection<String>): String {
    val existing = names.mapTo(mutableSetOf()) { it.lowercase() }
    if (base.lowercase() !in existing) return base
    var suffix = 2
    while ("$base $suffix".lowercase() in existing) suffix++
    return "$base $suffix"
}

private fun parseOpenSsh(text: String): OpenSshDetails? = runCatching {
    val encoded = text.substringAfter("-----BEGIN OPENSSH PRIVATE KEY-----", "")
        .substringBefore("-----END OPENSSH PRIVATE KEY-----", "")
        .filterNot(Char::isWhitespace)
    if (encoded.isEmpty()) return null
    val input = ByteBuffer.wrap(Base64.getDecoder().decode(encoded)).order(ByteOrder.BIG_ENDIAN)
    val magic = ByteArray(15).also(input::get).toString(Charsets.US_ASCII)
    require(magic == "openssh-key-v1\u0000")
    val cipher = input.readSshString().toString(Charsets.US_ASCII)
    input.readSshString()
    input.readSshString()
    val keyCount = input.int
    require(keyCount in 1..16)
    val publicKeys = List(keyCount) { input.readSshString() }
    val privateBlock = input.readSshString()
    val publicKey = publicKeys.first()
    val algorithm = ByteBuffer.wrap(publicKey).order(ByteOrder.BIG_ENDIAN)
        .readSshString().toString(Charsets.US_ASCII)
    val fingerprint = "SHA256:" + Base64.getEncoder().withoutPadding()
        .encodeToString(MessageDigest.getInstance("SHA-256").digest(publicKey))
    val publicKeyText = "$algorithm ${Base64.getEncoder().encodeToString(publicKey)}"
    val comment = if (cipher == "none") parseOpenSshComment(privateBlock, algorithm) else null
    OpenSshDetails(cipher, algorithm, fingerprint, publicKeyText, comment)
}.getOrNull()

private fun parseOpenSshComment(block: ByteArray, algorithm: String): String? = runCatching {
    val input = ByteBuffer.wrap(block).order(ByteOrder.BIG_ENDIAN)
    val check = input.int
    require(check == input.int)
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

data class SshKeyDetails(
    val suggestedName: String,
    val requiresPassphrase: Boolean,
    val algorithm: String?,
    val fingerprint: String?,
    val publicKey: String?,
)

private fun SshKeyDetails.toIdentity(id: String, name: String) = SshIdentity(
    id = id,
    name = name,
    algorithm = algorithm,
    fingerprint = fingerprint,
    requiresPassphrase = requiresPassphrase,
    publicKey = publicKey,
)

private data class OpenSshDetails(
    val cipher: String,
    val algorithm: String,
    val fingerprint: String,
    val publicKey: String,
    val comment: String?,
)
