package dev.ghostty.connect.terminal

import android.view.KeyEvent
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal

internal fun ghosttyKeyAction(action: Int, repeatCount: Int): Int? = when {
    action == KeyEvent.ACTION_UP -> GhosttyTerminal.KEY_ACTION_RELEASE
    action == KeyEvent.ACTION_DOWN && repeatCount > 0 -> GhosttyTerminal.KEY_ACTION_REPEAT
    action == KeyEvent.ACTION_DOWN -> GhosttyTerminal.KEY_ACTION_PRESS
    else -> null
}

internal class HardwareKeyModifierState {
    private val heldModifiers = mutableMapOf<Int, Int>()

    fun modifiers(keyCode: Int, action: Int, currentModifiers: Int): Int? = when (action) {
        GhosttyTerminal.KEY_ACTION_PRESS -> currentModifiers.also { heldModifiers[keyCode] = it }
        GhosttyTerminal.KEY_ACTION_REPEAT -> heldModifiers[keyCode]
        GhosttyTerminal.KEY_ACTION_RELEASE -> heldModifiers.remove(keyCode)
        else -> null
    }

    fun clear() {
        heldModifiers.clear()
    }
}
