package dev.ghostty.connect.sftp

enum class SftpEntryType {
    FILE,
    DIRECTORY,
    SYMLINK,
    UNSUPPORTED,
}

data class SftpEntry(
    val name: String,
    val type: SftpEntryType,
    val size: Long? = null,
    val modifiedAtSeconds: Long? = null,
    val permissions: String? = null,
    val supported: Boolean = true,
)

data class SftpBrowserState(
    val browserId: String,
    val hostName: String,
    val status: String,
    val path: String? = null,
    val entries: List<SftpEntry> = emptyList(),
    val canNavigateBack: Boolean = false,
    val connected: Boolean = false,
    val transfer: SftpTransferState? = null,
    val error: String? = null,
)

data class SftpTransferState(
    val direction: SftpTransferDirection,
    val displayName: String,
    val transferred: Long,
    val total: Long?,
    val status: SftpTransferStatus,
    val message: String? = null,
)

enum class SftpTransferDirection { UPLOAD, DOWNLOAD }
enum class SftpTransferStatus { RUNNING, COMPLETED, CANCELED, FAILED }

internal const val MAX_REMOTE_NAME_BYTES = 255

fun remoteChildNameError(name: String): String? = when {
    name.isBlank() -> "Enter a name."
    name == "." || name == ".." -> "That name is reserved."
    '/' in name || '\\' in name || '\u0000' in name -> "Names cannot contain separators or NUL characters."
    name.toByteArray(Charsets.UTF_8).size > MAX_REMOTE_NAME_BYTES -> "The UTF-8 name is too long."
    else -> null
}

internal fun safeRemoteChildName(name: String): Boolean = remoteChildNameError(name) == null

fun remoteFolderPath(parentPath: String, childName: String): String {
    remoteChildNameError(childName)?.let { error(it) }
    require(parentPath.startsWith('/')) { "The parent path must be absolute." }
    return if (parentPath == "/") "/$childName" else "${parentPath.trimEnd('/')}/$childName"
}

internal fun remoteAbsolutePathStack(targetPath: String): List<String> {
    require(targetPath.startsWith('/'))
    if (targetPath == "/") return listOf("/")
    val result = mutableListOf("/")
    targetPath.removePrefix("/").split('/').filter(String::isNotEmpty).forEach { child ->
        result += if (result.last() == "/") "/$child" else "${result.last()}/$child"
    }
    return result
}
