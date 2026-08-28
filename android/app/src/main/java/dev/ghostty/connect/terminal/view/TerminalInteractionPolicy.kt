package dev.ghostty.connect.terminal.view

internal fun shouldRouteRemoteMouse(mouseTracking: Boolean, localSelectionMode: Boolean): Boolean =
    mouseTracking && !localSelectionMode

internal class RemoteButtonState {
    private val pressed = linkedSetOf<Int>()
    val anyPressed: Boolean get() = pressed.isNotEmpty()

    fun press(button: Int) {
        pressed += button
    }

    fun release(button: Int) {
        pressed -= button
    }

    fun drain(): List<Int> = pressed.toList().also { pressed.clear() }
}
