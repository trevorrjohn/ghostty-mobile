package dev.ghostty.connect.terminal

import dev.ghostty.connect.terminal.bridge.TerminalSnapshot

enum class ContextualSelectionKind {
    LINK,
    PATH,
    OUTPUT,
    WORD,
}

data class ContextualSelection(
    val kind: ContextualSelectionKind,
    val value: String = "",
)

data class TerminalTokenMatch(
    val kind: ContextualSelectionKind,
    val text: String,
    val startColumn: Int,
    val endColumn: Int,
)

object TerminalTokenMatcher {
    private const val MAX_TOKEN_BYTES = 1024
    private val leadingPunctuation = setOf('(', '[', '{', '<', '"', '\'')
    private val trailingPunctuation = setOf(')', ']', '}', '>', '"', '\'', ',', ';', '.', '!', '?')

    fun match(snapshot: TerminalSnapshot, column: Int, row: Int): TerminalTokenMatch? {
        if (row !in 0 until snapshot.rows || column !in 0 until snapshot.columns) return null
        val offset = row * snapshot.columns
        val cells = snapshot.cells.subList(offset, offset + snapshot.columns).map { cell ->
            cell.text.takeUnless { cell.invisible }.orEmpty()
        }
        return match(cells, column)
    }

    fun match(cells: List<String>, column: Int): TerminalTokenMatch? {
        if (column !in cells.indices || cells[column].isBlank()) return null
        var start = column
        var end = column
        while (start > 0 && !cells[start - 1].isBlank()) start--
        while (end + 1 < cells.size && !cells[end + 1].isBlank()) end++
        while (start <= end && cells[start].firstOrNull() in leadingPunctuation) start++
        while (end >= start && cells[end].lastOrNull() in trailingPunctuation) end--
        if (start > end || column !in start..end) return null

        val text = cells.subList(start, end + 1).joinToString("")
        if (text.isBlank() || text.toByteArray().size > MAX_TOKEN_BYTES) return null
        val kind = when {
            isWebLink(text) -> ContextualSelectionKind.LINK
            isPath(text) -> ContextualSelectionKind.PATH
            else -> return null
        }
        return TerminalTokenMatch(kind, text, start, end)
    }

    private fun isWebLink(text: String): Boolean =
        text.startsWith("http://", ignoreCase = true) || text.startsWith("https://", ignoreCase = true)

    private fun isPath(text: String): Boolean =
        !text.contains("://") && (
            text.startsWith("/") || text.startsWith("~/") || text.startsWith("./") ||
                text.startsWith("../") || text.contains('/')
            )
}
