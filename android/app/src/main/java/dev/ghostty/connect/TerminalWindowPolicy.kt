package dev.ghostty.connect

internal data class TerminalWindowInsets(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
)

internal fun usesTerminalImmersiveInsets(
    requested: Boolean,
    inMultiWindowMode: Boolean,
    captionBarVisible: Boolean,
): Boolean = requested && !inMultiWindowMode && !captionBarVisible

internal fun terminalContentInsets(
    immersive: Boolean,
    systemBars: TerminalWindowInsets,
    ime: TerminalWindowInsets,
    displayCutout: TerminalWindowInsets,
): TerminalWindowInsets {
    val base = if (immersive) {
        displayCutout
    } else {
        TerminalWindowInsets(
            left = maxOf(systemBars.left, displayCutout.left),
            top = maxOf(systemBars.top, displayCutout.top),
            right = maxOf(systemBars.right, displayCutout.right),
            bottom = maxOf(systemBars.bottom, displayCutout.bottom),
        )
    }
    return TerminalWindowInsets(
        left = maxOf(base.left, ime.left),
        top = maxOf(base.top, ime.top),
        right = maxOf(base.right, ime.right),
        bottom = maxOf(base.bottom, ime.bottom),
    )
}
