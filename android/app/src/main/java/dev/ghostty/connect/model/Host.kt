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
    val keyName: String? = null,
    val allowRemoteClipboard: Boolean? = null,
    val allowRemoteNotifications: Boolean? = null,
) {
    val name: String get() = alias ?: hostname
    val destination: String get() = "$username@$hostname:$port"
}
