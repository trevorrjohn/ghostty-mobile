package dev.ghostty.connect.model

data class TrustedHost(
    val storageId: String,
    val hostname: String?,
    val port: Int?,
    val fingerprint: String,
    val storageIds: Set<String> = setOf(storageId),
    val conflictingFingerprints: List<String> = emptyList(),
) {
    val isConflicted: Boolean get() = conflictingFingerprints.isNotEmpty()
    val fingerprints: List<String> get() = listOf(fingerprint) + conflictingFingerprints
    val destination: String
        get() = if (hostname == null || port == null) {
            storageId
        } else {
            SshDestination.create(hostname, port).display
        }
}

internal fun decodeTrustedHostId(id: String, fingerprint: String): TrustedHost {
    require(fingerprint.isNotBlank()) { "Trusted-host fingerprint is empty." }
    val destination = SshDestination.parseStorageId(id)
    return TrustedHost(id, destination.hostname, destination.port, fingerprint)
}

internal fun decodeStoredTrustedHost(id: String, fingerprint: String): TrustedHost =
    runCatching { decodeTrustedHostId(id, fingerprint) }
        .getOrElse { TrustedHost(id, null, null, fingerprint) }
