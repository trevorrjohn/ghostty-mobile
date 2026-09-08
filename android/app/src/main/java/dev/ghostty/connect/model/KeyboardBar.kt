package dev.ghostty.connect.model

enum class KeyboardModifier(val displayName: String) {
    CONTROL("Ctrl"),
    ALT("Alt"),
    SHIFT("Shift"),
    META("Meta"),
    FUNCTION("Fn"),
    SYMBOL("Sym"),
    CAPS_LOCK("Caps"),
    NUM_LOCK("Num"),
    SCROLL_LOCK("Scroll"),
}

enum class KeyboardBarItemType {
    MODIFIER,
    KEY,
    COMBINATION,
    LAST_USED_MODIFIER,
    LAST_USED_COMBINATION,
}

enum class HoldSwipeDirection { UP, RIGHT, DOWN, LEFT }

const val MAX_KEYBOARD_ACTION_STEPS = 8

data class KeyboardActionStep(
    val key: String,
    val modifiers: Set<KeyboardModifier> = emptySet(),
)

object HoldSwipeActions {
    const val SELECT_HERE = "quick-select-here"
    const val PASTE = "quick-paste"
    const val COPY_LATEST = "quick-copy-latest"
    const val SEARCH = "quick-search"
    const val NEXT_SESSION = "quick-next-session"
    const val CHOOSE_SESSION = "quick-choose-session"

    val builtIns = listOf(
        SELECT_HERE to "Select here",
        PASTE to "Paste",
        COPY_LATEST to "Copy latest",
        SEARCH to "Search",
        NEXT_SESSION to "Next session",
        CHOOSE_SESSION to "Choose session",
    )
}

data class KeyboardBarItem(
    val id: String,
    val label: String,
    val type: KeyboardBarItemType,
    val key: String? = null,
    val modifiers: Set<KeyboardModifier> = emptySet(),
    val titleContains: String? = null,
    val steps: List<KeyboardActionStep> = emptyList(),
)

fun KeyboardBarItem.actionSteps(additionalModifiers: Set<KeyboardModifier> = emptySet()): List<KeyboardActionStep> {
    val configured = steps.takeIf { it.isNotEmpty() }
        ?: key?.let { listOf(KeyboardActionStep(it, modifiers)) }.orEmpty()
    return configured.take(MAX_KEYBOARD_ACTION_STEPS).mapIndexed { index, step ->
        if (index == 0) step.copy(modifiers = step.modifiers + additionalModifiers) else step
    }
}

fun encodeKeyboardAction(
    item: KeyboardBarItem,
    additionalModifiers: Set<KeyboardModifier> = emptySet(),
    encode: (KeyboardActionStep) -> ByteArray,
): ByteArray = item.actionSteps(additionalModifiers).fold(ByteArray(0)) { bytes, step -> bytes + encode(step) }

fun parseKeyboardActionStep(value: String): KeyboardActionStep? {
    val parts = value.split('+').map(String::trim)
    if (parts.any(String::isEmpty)) return null
    val key = normalizedKeyboardActionKey(parts.last()) ?: return null
    val modifiers = parts.dropLast(1).map { name ->
        KeyboardModifier.entries.firstOrNull {
            it.name.equals(name, ignoreCase = true) || it.displayName.equals(name, ignoreCase = true) ||
                (it == KeyboardModifier.CONTROL && name.equals("Control", ignoreCase = true))
        } ?: return null
    }.toSet()
    return KeyboardActionStep(key, modifiers)
}

fun KeyboardActionStep.displayLabel(): String =
    (modifiers.joinToString("+") { it.displayName }.takeIf(String::isNotEmpty)?.plus("+") ?: "") + key

private fun normalizedKeyboardActionKey(value: String): String? {
    val key = value.trim()
    if (key.isEmpty() || key.any(Char::isISOControl) || key.toByteArray().size > 32) return null
    KeyboardBarCatalog.keys.firstOrNull { it.key.equals(key, ignoreCase = true) }?.key?.let { return it }
    return key.takeIf { it.codePointCount(0, it.length) == 1 }
}

fun KeyboardBarItem.isVisibleForTerminalTitle(title: String): Boolean =
    titleContains.isNullOrBlank() || title.contains(titleContains, ignoreCase = true)

data class KeyboardBarConfig(
    val enabled: Boolean = true,
    val items: List<KeyboardBarItem> = KeyboardBarCatalog.defaultItems,
    val combinations: List<KeyboardBarItem> = KeyboardBarCatalog.defaultCombinations,
    val volumeUpActionId: String = KeyboardBarCatalog.DEFAULT_VOLUME_UP_ACTION_ID,
    val volumeDownActionId: String = KeyboardBarCatalog.DEFAULT_VOLUME_DOWN_ACTION_ID,
    val holdSwipeEnabled: Boolean = true,
    val holdSwipeActions: Map<HoldSwipeDirection, String> = mapOf(
        HoldSwipeDirection.UP to HoldSwipeActions.COPY_LATEST,
        HoldSwipeDirection.RIGHT to HoldSwipeActions.PASTE,
        HoldSwipeDirection.DOWN to "key-escape",
        HoldSwipeDirection.LEFT to HoldSwipeActions.NEXT_SESSION,
    ),
)

object KeyboardBarCatalog {
    const val SYSTEM_VOLUME_ACTION_ID = "system-volume"
    const val DEFAULT_VOLUME_UP_ACTION_ID = "key-escape"
    const val DEFAULT_VOLUME_DOWN_ACTION_ID = "key-tab"

    val modifiers = KeyboardModifier.entries.map { modifier ->
        KeyboardBarItem(
            id = "modifier-${modifier.name.lowercase()}",
            label = modifier.displayName,
            type = KeyboardBarItemType.MODIFIER,
            modifiers = setOf(modifier),
        )
    }

    val keys = listOf(
        key("escape", "Esc", "ESCAPE"),
        key("tab", "Tab", "TAB"),
        key("enter", "Enter", "ENTER"),
        key("backspace", "Backspace", "BACKSPACE"),
        key("delete", "Delete", "DELETE"),
        key("insert", "Insert", "INSERT"),
        key("home", "Home", "HOME"),
        key("end", "End", "END"),
        key("page-up", "PgUp", "PAGE_UP"),
        key("page-down", "PgDn", "PAGE_DOWN"),
        key("arrow-up", "Up", "ARROW_UP"),
        key("arrow-down", "Down", "ARROW_DOWN"),
        key("arrow-left", "Left", "ARROW_LEFT"),
        key("arrow-right", "Right", "ARROW_RIGHT"),
    ) + (1..12).map { number -> key("f$number", "F$number", "F$number") }

    val lastUsedModifier = KeyboardBarItem(
        id = "last-used-modifier",
        label = "Last modifier",
        type = KeyboardBarItemType.LAST_USED_MODIFIER,
    )

    val lastUsedCombination = KeyboardBarItem(
        id = "last-used-combination",
        label = "Last combo",
        type = KeyboardBarItemType.LAST_USED_COMBINATION,
    )

    val controlB = KeyboardBarItem(
        id = "combination-control-b",
        label = "Ctrl+B",
        type = KeyboardBarItemType.COMBINATION,
        key = "b",
        modifiers = setOf(KeyboardModifier.CONTROL),
    )

    val defaultCombinations = listOf(controlB)

    val availableItems = modifiers + keys + lastUsedModifier + lastUsedCombination

    fun volumeAction(id: String): KeyboardBarItem? = keys.firstOrNull { it.id == id }

    fun normalizedVolumeActionId(id: String?, defaultId: String): String = when {
        id == SYSTEM_VOLUME_ACTION_ID -> SYSTEM_VOLUME_ACTION_ID
        keys.any { it.id == id } -> requireNotNull(id)
        else -> defaultId
    }

    val defaultItems = listOf(
        keys.first { it.key == "ESCAPE" },
        controlB,
        modifiers.first { it.modifiers.contains(KeyboardModifier.ALT) },
        keys.first { it.key == "TAB" },
        modifiers.first { it.modifiers.contains(KeyboardModifier.SHIFT) },
        keys.first { it.key == "ARROW_UP" },
        keys.first { it.key == "ARROW_DOWN" },
        keys.first { it.key == "ARROW_LEFT" },
        keys.first { it.key == "ARROW_RIGHT" },
        lastUsedModifier,
    )

    private fun key(id: String, label: String, key: String) = KeyboardBarItem(
        id = "key-$id",
        label = label,
        type = KeyboardBarItemType.KEY,
        key = key,
    )
}
