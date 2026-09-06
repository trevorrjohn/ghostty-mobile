package dev.ghostty.connect.terminal

import android.view.KeyEvent
import dev.ghostty.connect.terminal.bridge.GhosttyTerminal

internal fun ghosttyKeyAction(action: Int, repeatCount: Int): Int? = when {
    action == KeyEvent.ACTION_UP -> GhosttyTerminal.KEY_ACTION_RELEASE
    action == KeyEvent.ACTION_DOWN && repeatCount > 0 -> GhosttyTerminal.KEY_ACTION_REPEAT
    action == KeyEvent.ACTION_DOWN -> GhosttyTerminal.KEY_ACTION_PRESS
    else -> null
}

internal fun isModifierEligibleImeCommit(text: String): Boolean =
    text.codePointCount(0, text.length) == 1 && text.firstOrNull()?.code in 0x20..0x7e

internal enum class HardwareClipboardAction { COPY, PASTE }

internal fun hardwareClipboardAction(keyCode: Int): HardwareClipboardAction? = when (keyCode) {
    KeyEvent.KEYCODE_COPY -> HardwareClipboardAction.COPY
    KeyEvent.KEYCODE_PASTE -> HardwareClipboardAction.PASTE
    else -> null
}

internal fun androidKeyName(keyCode: Int): String? = when (keyCode) {
    in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z -> ('A'.code + keyCode - KeyEvent.KEYCODE_A).toChar().toString()
    in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> (keyCode - KeyEvent.KEYCODE_0).toString()
    in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9 -> "NUMPAD_${keyCode - KeyEvent.KEYCODE_NUMPAD_0}"
    KeyEvent.KEYCODE_ESCAPE -> "ESCAPE"
    KeyEvent.KEYCODE_TAB -> "TAB"
    KeyEvent.KEYCODE_ENTER -> "ENTER"
    KeyEvent.KEYCODE_NUMPAD_ENTER -> "NUMPAD_ENTER"
    KeyEvent.KEYCODE_DEL -> "BACKSPACE"
    KeyEvent.KEYCODE_FORWARD_DEL -> "DELETE"
    KeyEvent.KEYCODE_INSERT -> "INSERT"
    KeyEvent.KEYCODE_MOVE_HOME -> "HOME"
    KeyEvent.KEYCODE_MOVE_END -> "END"
    KeyEvent.KEYCODE_PAGE_UP -> "PAGE_UP"
    KeyEvent.KEYCODE_PAGE_DOWN -> "PAGE_DOWN"
    KeyEvent.KEYCODE_DPAD_UP -> "ARROW_UP"
    KeyEvent.KEYCODE_DPAD_DOWN -> "ARROW_DOWN"
    KeyEvent.KEYCODE_DPAD_LEFT -> "ARROW_LEFT"
    KeyEvent.KEYCODE_DPAD_RIGHT -> "ARROW_RIGHT"
    in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> "F${keyCode - KeyEvent.KEYCODE_F1 + 1}"
    KeyEvent.KEYCODE_SPACE -> "SPACE"
    KeyEvent.KEYCODE_GRAVE -> "BACKQUOTE"
    KeyEvent.KEYCODE_BACKSLASH -> "BACKSLASH"
    KeyEvent.KEYCODE_LEFT_BRACKET -> "BRACKET_LEFT"
    KeyEvent.KEYCODE_RIGHT_BRACKET -> "BRACKET_RIGHT"
    KeyEvent.KEYCODE_COMMA -> "COMMA"
    KeyEvent.KEYCODE_EQUALS -> "EQUAL"
    KeyEvent.KEYCODE_MINUS -> "MINUS"
    KeyEvent.KEYCODE_PERIOD -> "PERIOD"
    KeyEvent.KEYCODE_APOSTROPHE -> "QUOTE"
    KeyEvent.KEYCODE_SEMICOLON -> "SEMICOLON"
    KeyEvent.KEYCODE_SLASH -> "SLASH"
    KeyEvent.KEYCODE_SHIFT_LEFT -> "SHIFT_LEFT"
    KeyEvent.KEYCODE_SHIFT_RIGHT -> "SHIFT_RIGHT"
    KeyEvent.KEYCODE_CTRL_LEFT -> "CONTROL_LEFT"
    KeyEvent.KEYCODE_CTRL_RIGHT -> "CONTROL_RIGHT"
    KeyEvent.KEYCODE_ALT_LEFT -> "ALT_LEFT"
    KeyEvent.KEYCODE_ALT_RIGHT -> "ALT_RIGHT"
    KeyEvent.KEYCODE_META_LEFT -> "META_LEFT"
    KeyEvent.KEYCODE_META_RIGHT -> "META_RIGHT"
    KeyEvent.KEYCODE_CAPS_LOCK -> "CAPS_LOCK"
    KeyEvent.KEYCODE_NUM_LOCK -> "NUM_LOCK"
    KeyEvent.KEYCODE_SCROLL_LOCK -> "SCROLL_LOCK"
    KeyEvent.KEYCODE_NUMPAD_ADD -> "NUMPAD_ADD"
    KeyEvent.KEYCODE_NUMPAD_SUBTRACT -> "NUMPAD_SUBTRACT"
    KeyEvent.KEYCODE_NUMPAD_MULTIPLY -> "NUMPAD_MULTIPLY"
    KeyEvent.KEYCODE_NUMPAD_DIVIDE -> "NUMPAD_DIVIDE"
    KeyEvent.KEYCODE_NUMPAD_DOT -> "NUMPAD_DECIMAL"
    KeyEvent.KEYCODE_NUMPAD_COMMA -> "NUMPAD_COMMA"
    KeyEvent.KEYCODE_NUMPAD_EQUALS -> "NUMPAD_EQUAL"
    KeyEvent.KEYCODE_NUMPAD_LEFT_PAREN -> "NUMPAD_PAREN_LEFT"
    KeyEvent.KEYCODE_NUMPAD_RIGHT_PAREN -> "NUMPAD_PAREN_RIGHT"
    KeyEvent.KEYCODE_SYSRQ -> "PRINT_SCREEN"
    KeyEvent.KEYCODE_BREAK -> "PAUSE"
    KeyEvent.KEYCODE_MENU -> "CONTEXT_MENU"
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
