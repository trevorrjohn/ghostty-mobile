package dev.ghostty.connect.terminal

import dev.ghostty.connect.model.Host

data class SessionSummary(
    val sessionId: String,
    val hostId: String,
    val hostName: String,
    val destination: String,
    val status: String,
    val canRetry: Boolean = false,
)

internal fun sessionSummary(sessionId: String, host: Host, status: String, canRetry: Boolean = false) = SessionSummary(
    sessionId = sessionId,
    hostId = host.id,
    hostName = host.name,
    destination = host.destination,
    status = status,
    canRetry = canRetry,
)
