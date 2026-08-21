package dev.ghostty.connect.sftp

enum class SftpEntryType {
    FILE,
    DIRECTORY,
    SYMLINK,
    UNSUPPORTED,
}

enum class SftpSortMode { NAME, UPDATED, ACCESSED, SIZE }

data class SftpEntry(
    val name: String,
    val type: SftpEntryType,
    val size: Long? = null,
    val modifiedAtSeconds: Long? = null,
    val accessedAtSeconds: Long? = null,
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
    val openUri: String? = null,
    val openWhenComplete: Boolean = false,
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

fun filterAndSortSftpEntries(
    entries: List<SftpEntry>,
    query: String,
    sortMode: SftpSortMode,
    descending: Boolean,
): List<SftpEntry> {
    val scores = entries.mapNotNull { entry -> fuzzyScore(entry.name, query)?.let { entry to it } }.toMap()
    return scores.keys.sortedWith { left, right ->
        val directoryOrder = compareValues(left.type != SftpEntryType.DIRECTORY, right.type != SftpEntryType.DIRECTORY)
        if (directoryOrder != 0) return@sortedWith directoryOrder
        if (query.isNotBlank()) {
            val relevance = compareValues(scores.getValue(left), scores.getValue(right))
            if (relevance != 0) return@sortedWith relevance
        }
        val selected = when (sortMode) {
            SftpSortMode.NAME -> left.name.compareTo(right.name, ignoreCase = true)
            SftpSortMode.UPDATED -> compareNullableLong(left.modifiedAtSeconds, right.modifiedAtSeconds, descending)
            SftpSortMode.ACCESSED -> compareNullableLong(left.accessedAtSeconds, right.accessedAtSeconds, descending)
            SftpSortMode.SIZE -> compareNullableLong(left.size, right.size, descending)
        }
        if (selected != 0) {
            if (sortMode == SftpSortMode.NAME && descending) -selected else selected
        } else {
            left.name.compareTo(right.name, ignoreCase = true)
        }
    }
}

internal fun fuzzyScore(candidate: String, query: String): Int? {
    val needle = query.trim().lowercase()
    if (needle.isEmpty()) return 0
    val value = candidate.lowercase()
    if (value == needle) return 0
    if (value.startsWith(needle)) return 10 + value.length - needle.length
    val substring = value.indexOf(needle)
    if (substring >= 0) return 100 + substring * 10 + value.length - needle.length
    var queryIndex = 0
    var first = -1
    var previous = -1
    var gaps = 0
    value.forEachIndexed { index, character ->
        if (queryIndex < needle.length && character == needle[queryIndex]) {
            if (first < 0) first = index
            if (previous >= 0) gaps += index - previous - 1
            previous = index
            queryIndex++
        }
    }
    return if (queryIndex == needle.length) 1_000 + first * 10 + gaps * 5 + value.length else null
}

private fun compareNullableLong(left: Long?, right: Long?, descending: Boolean): Int = when {
    left == null && right == null -> 0
    left == null -> 1
    right == null -> -1
    descending -> right.compareTo(left)
    else -> left.compareTo(right)
}

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
