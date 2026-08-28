package dev.ghostty.connect.model

enum class AuthenticationType {
    PASSWORD,
    SSH_KEY,
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
) {
    init {
        require(retryMaxAttempts in MIN_RETRY_ATTEMPTS..MAX_RETRY_ATTEMPTS) {
            "Retry attempts must be between $MIN_RETRY_ATTEMPTS and $MAX_RETRY_ATTEMPTS."
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

fun Host.duplicate(newId: String, existingNames: Collection<String>): Host {
    val baseName = "$name copy"
    var duplicateName = baseName
    var suffix = 2
    while (duplicateName in existingNames) duplicateName = "$baseName ${suffix++}"
    return copy(id = newId, alias = duplicateName)
}
