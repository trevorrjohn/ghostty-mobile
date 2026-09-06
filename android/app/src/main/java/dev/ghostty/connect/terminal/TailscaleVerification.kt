package dev.ghostty.connect.terminal

import java.net.URI

private const val MAX_TAILSCALE_BANNER_CHARS = 8192
private val HTTPS_URL = Regex("https://[^\\s<>\\\"]+", RegexOption.IGNORE_CASE)

internal fun boundedAuthenticationBanner(value: String): String = value.take(MAX_TAILSCALE_BANNER_CHARS)

internal fun tailscaleVerificationUrl(value: String): String? {
    val candidate = HTTPS_URL.find(boundedAuthenticationBanner(value))?.value
        ?.trimEnd('.', ',', ')', ']', '}') ?: return null
    val uri = runCatching { URI(candidate) }.getOrNull() ?: return null
    return candidate.takeIf {
        uri.scheme.equals("https", ignoreCase = true) && uri.userInfo == null &&
            uri.host.equals("login.tailscale.com", ignoreCase = true)
    }
}
