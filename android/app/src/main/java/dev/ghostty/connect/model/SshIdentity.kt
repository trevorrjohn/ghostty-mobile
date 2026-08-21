package dev.ghostty.connect.model

data class SshIdentity(
    val id: String,
    val name: String,
    val algorithm: String?,
    val fingerprint: String?,
    val requiresPassphrase: Boolean,
    val publicKey: String?,
)
