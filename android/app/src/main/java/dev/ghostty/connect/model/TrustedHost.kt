package dev.ghostty.connect.model

data class TrustedHost(
    val storageId: String,
    val hostname: String?,
    val port: Int?,
    val fingerprint: String,
) {
    val destination: String
        get() = if (hostname == null || port == null) {
            storageId
        } else if (':' in hostname && !(hostname.startsWith('[') && hostname.endsWith(']'))) {
            "[$hostname]:$port"
        } else {
            "$hostname:$port"
        }
}

internal fun decodeTrustedHostId(id: String, fingerprint: String): TrustedHost {
    val separator = id.lastIndexOf(':')
    require(separator > 0 && separator < id.lastIndex) { "Invalid trusted-host destination." }
    val hostname = id.substring(0, separator)
    val port = id.substring(separator + 1).toInt()
    require(hostname.isNotBlank()) { "Trusted-host name is empty." }
    require(port in 1..65535) { "Trusted-host port is invalid." }
    require(fingerprint.isNotBlank()) { "Trusted-host fingerprint is empty." }
    return TrustedHost(id, hostname, port, fingerprint)
}

internal fun decodeStoredTrustedHost(id: String, fingerprint: String): TrustedHost =
    runCatching { decodeTrustedHostId(id, fingerprint) }
        .getOrElse { TrustedHost(id, null, null, fingerprint) }
