package dev.ghostty.connect.sftp

import java.net.URI

/** OSC 7 metadata supplies only a path; the saved host still owns the SSH destination. */
internal fun terminalDirectoryPath(value: String): String? {
    val path = if (value.startsWith('/')) value else {
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (uri.scheme != "file" || uri.query != null || uri.fragment != null || uri.userInfo != null) return null
        uri.path ?: return null
    }
    return path.takeIf { it.startsWith('/') && '\u0000' !in it && it.toByteArray(Charsets.UTF_8).size <= 4096 }
}
