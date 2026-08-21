package dev.ghostty.connect.model

enum class AuthenticationType {
    PASSWORD,
    SSH_KEY,
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
) {
    val name: String get() = alias ?: hostname
    val destination: String get() = "$username@$hostname:$port"
}

fun Host.duplicate(newId: String, existingNames: Collection<String>): Host {
    val baseName = "$name copy"
    var duplicateName = baseName
    var suffix = 2
    while (duplicateName in existingNames) duplicateName = "$baseName ${suffix++}"
    return copy(id = newId, alias = duplicateName)
}
