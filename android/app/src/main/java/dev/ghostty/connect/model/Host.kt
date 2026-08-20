package dev.ghostty.connect.model

data class Host(
    val name: String,
    val hostname: String,
    val port: Int = 22,
    val username: String,
    val keyName: String? = null,
) {
    val destination: String get() = "$username@$hostname:$port"
}
