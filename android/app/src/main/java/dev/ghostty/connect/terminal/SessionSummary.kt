package dev.ghostty.connect.terminal

import dev.ghostty.connect.model.Host

data class SessionSummary(
    val sessionId: String,
    val hostId: String,
    val hostName: String,
    val destination: String,
    val startedAtElapsedRealtime: Long,
    val status: String,
    val canRetry: Boolean = false,
) {
    val shortId: String get() = sessionDisplayId(sessionId)
}

internal fun sessionDisplayId(sessionId: String): String = sessionId.takeLast(8)

internal fun shouldPresentSessionPrompt(selectedSessionId: String?, promptSessionId: String): Boolean =
    selectedSessionId == promptSessionId

internal fun nextSessionId(currentSessionId: String, sessions: List<SessionSummary>): String? {
    val ordered = sessions.sortedBy(SessionSummary::startedAtElapsedRealtime)
    if (ordered.size < 2) return null
    val index = ordered.indexOfFirst { it.sessionId == currentSessionId }
    if (index < 0) return null
    return ordered[(index + 1) % ordered.size].sessionId
}

internal fun sessionSummary(
    sessionId: String,
    host: Host,
    startedAtElapsedRealtime: Long,
    status: String,
    canRetry: Boolean = false,
) = SessionSummary(
    sessionId = sessionId,
    hostId = host.id,
    hostName = host.name,
    destination = host.destination,
    startedAtElapsedRealtime = startedAtElapsedRealtime,
    status = status,
    canRetry = canRetry,
)
