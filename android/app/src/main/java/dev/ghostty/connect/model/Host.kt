package dev.ghostty.connect.model

enum class AuthenticationType {
    PASSWORD,
    SSH_KEY,
    TAILSCALE_SSH,
}

enum class RetryBackoff {
    FAST,
    BALANCED,
    CONSERVATIVE,
}

data class Host(
    val id: String,
    val alias: String? = null,
    val hostname: String,
    val port: Int = 22,
    val username: String,
    val authenticationType: AuthenticationType = AuthenticationType.PASSWORD,
    val identityId: String? = null,
    val allowRemoteClipboard: Boolean? = null,
    val allowRemoteNotifications: Boolean? = null,
    val allowSftpDelete: Boolean = false,
    val retryEnabled: Boolean = true,
    val retryMaxAttempts: Int = DEFAULT_RETRY_ATTEMPTS,
    val retryBackoff: RetryBackoff = RetryBackoff.BALANCED,
    val startupCommand: String? = null,
) {
    init {
        require(retryMaxAttempts in MIN_RETRY_ATTEMPTS..MAX_RETRY_ATTEMPTS) {
            "Retry attempts must be between $MIN_RETRY_ATTEMPTS and $MAX_RETRY_ATTEMPTS."
        }
        require(authenticationType != AuthenticationType.TAILSCALE_SSH || port == 22) {
            "Tailscale SSH uses port 22."
        }
        require(startupCommand == normalizeStartupCommand(startupCommand)) {
            "Startup command must be normalized, single-line, and at most $MAX_STARTUP_COMMAND_BYTES UTF-8 bytes."
        }
    }

    val name: String get() = alias ?: hostname
    val destination: String get() = "$username@" + runCatching {
        SshDestination.create(hostname, port).display
    }.getOrDefault("$hostname:$port")
}

const val MIN_RETRY_ATTEMPTS = 1
const val MAX_RETRY_ATTEMPTS = 10
const val DEFAULT_RETRY_ATTEMPTS = 5
const val MAX_STARTUP_COMMAND_BYTES = 1_024

fun normalizeStartupCommand(value: String?): String? {
    if (value == null) return null
    require(value.none { it.code < 32 || it.code == 127 }) {
        "Startup command must be one line without control characters."
    }
    val normalized = value.trim()
    if (normalized.isEmpty()) return null
    require(normalized.toByteArray(Charsets.UTF_8).size <= MAX_STARTUP_COMMAND_BYTES) {
        "Startup command is limited to $MAX_STARTUP_COMMAND_BYTES UTF-8 bytes."
    }
    return normalized
}

fun Host.duplicate(newId: String, existingNames: Collection<String>): Host {
    val baseName = "$name copy"
    var duplicateName = baseName
    var suffix = 2
    while (duplicateName in existingNames) duplicateName = "$baseName ${suffix++}"
    return copy(id = newId, alias = duplicateName)
}
