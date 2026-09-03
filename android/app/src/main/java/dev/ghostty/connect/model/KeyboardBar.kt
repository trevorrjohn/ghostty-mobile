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

data class KeyboardBarItem(
    val id: String,
    val label: String,
    val type: KeyboardBarItemType,
    val key: String? = null,
    val modifiers: Set<KeyboardModifier> = emptySet(),
)

data class KeyboardBarConfig(
    val enabled: Boolean = true,
    val items: List<KeyboardBarItem> = KeyboardBarCatalog.defaultItems,
    val combinations: List<KeyboardBarItem> = KeyboardBarCatalog.defaultCombinations,
    val volumeUpActionId: String = KeyboardBarCatalog.DEFAULT_VOLUME_UP_ACTION_ID,
    val volumeDownActionId: String = KeyboardBarCatalog.DEFAULT_VOLUME_DOWN_ACTION_ID,
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
