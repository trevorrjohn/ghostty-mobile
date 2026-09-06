package dev.ghostty.connect.terminal.view

import android.view.MotionEvent

internal fun shouldRouteRemoteMouse(mouseTracking: Boolean, localSelectionMode: Boolean): Boolean =
    mouseTracking && !localSelectionMode

internal fun canActivateHoldSwipe(
    remotePressSent: Boolean,
    localSelectionMode: Boolean,
    selectionVisible: Boolean,
    touchExplorationEnabled: Boolean,
): Boolean = !remotePressSent && !localSelectionMode && !selectionVisible && !touchExplorationEnabled

internal fun ghosttyMouseButton(actionButton: Int): Int = when (actionButton) {
    MotionEvent.BUTTON_SECONDARY, MotionEvent.BUTTON_STYLUS_PRIMARY -> 2
    MotionEvent.BUTTON_TERTIARY, MotionEvent.BUTTON_STYLUS_SECONDARY -> 3
    else -> 1
}

internal class RemoteButtonState {
    private val pressed = linkedSetOf<Int>()
    val anyPressed: Boolean get() = pressed.isNotEmpty()

    fun press(button: Int) {
        pressed += button
    }

    fun release(button: Int) {
        pressed -= button
    }

    fun drain(): List<RemoteButtonRelease> = buildList {
        while (pressed.isNotEmpty()) {
            val button = pressed.first()
            pressed.remove(button)
            add(RemoteButtonRelease(button, pressed.isNotEmpty()))
        }
    }
}

internal data class RemoteButtonRelease(val button: Int, val anyPressed: Boolean)
