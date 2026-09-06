package dev.ghostty.connect

internal fun restoredSessionId(
    requestedSessionId: String?,
    savedSessionId: String?,
    savedTerminalVisible: Boolean,
    serviceActive: Boolean,
    freshLaunch: Boolean,
): String? = requestedSessionId?.takeIf { freshLaunch }
    ?: savedSessionId?.takeIf { !freshLaunch && savedTerminalVisible && serviceActive }

internal fun liveSessionToOpen(
    requestedSessionId: String?,
    liveSessionIds: List<String>,
    allowSingleSessionAutoOpen: Boolean,
): String? = requestedSessionId?.takeIf(liveSessionIds::contains)
    ?: liveSessionIds.singleOrNull()?.takeIf { requestedSessionId == null && allowSingleSessionAutoOpen }
