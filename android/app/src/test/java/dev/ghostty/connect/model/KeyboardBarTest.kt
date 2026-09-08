package dev.ghostty.connect.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardBarTest {
    @Test
    fun defaultsIncludeControlBCombination() {
        val config = KeyboardBarConfig()
        val controlB = config.items.single { it.id == "combination-control-b" }

        assertEquals(KeyboardBarItemType.COMBINATION, controlB.type)
        assertEquals("b", controlB.key)
        assertEquals(setOf(KeyboardModifier.CONTROL), controlB.modifiers)
        assertNull(controlB.titleContains)
        assertTrue(controlB.isVisibleForTerminalTitle("work — tmux"))
        assertTrue(controlB.isVisibleForTerminalTitle("work — shell"))
        assertEquals(listOf(controlB), config.combinations)
    }

    @Test
    fun volumeButtonsDefaultToEscapeAndTab() {
        val config = KeyboardBarConfig()

        assertEquals("ESCAPE", KeyboardBarCatalog.volumeAction(config.volumeUpActionId)?.key)
        assertEquals("TAB", KeyboardBarCatalog.volumeAction(config.volumeDownActionId)?.key)
    }

    @Test
    fun volumeActionsAllowSystemBehaviorAndRejectUnknownIds() {
        assertNull(KeyboardBarCatalog.volumeAction(KeyboardBarCatalog.SYSTEM_VOLUME_ACTION_ID))
        assertEquals(
            KeyboardBarCatalog.DEFAULT_VOLUME_UP_ACTION_ID,
            KeyboardBarCatalog.normalizedVolumeActionId("unknown", KeyboardBarCatalog.DEFAULT_VOLUME_UP_ACTION_ID),
        )
        assertEquals(
            KeyboardBarCatalog.SYSTEM_VOLUME_ACTION_ID,
            KeyboardBarCatalog.normalizedVolumeActionId(
                KeyboardBarCatalog.SYSTEM_VOLUME_ACTION_ID,
                KeyboardBarCatalog.DEFAULT_VOLUME_UP_ACTION_ID,
            ),
        )
        assertTrue(KeyboardBarCatalog.keys.map(KeyboardBarItem::id).toSet().size == KeyboardBarCatalog.keys.size)
    }

    @Test
    fun multiStepActionEncodesPrefixAndCommandIndependently() {
        val item = KeyboardBarItem(
            id = "tmux-next",
            label = "Tmux next",
            type = KeyboardBarItemType.COMBINATION,
            key = "b",
            modifiers = setOf(KeyboardModifier.CONTROL),
            steps = listOf(
                KeyboardActionStep("b", setOf(KeyboardModifier.CONTROL)),
                KeyboardActionStep("n"),
            ),
        )
        val encodedSteps = mutableListOf<KeyboardActionStep>()

        val bytes = encodeKeyboardAction(item) { step ->
            encodedSteps += step
            when (step) {
                KeyboardActionStep("b", setOf(KeyboardModifier.CONTROL)) -> byteArrayOf(0x02)
                KeyboardActionStep("n") -> byteArrayOf(0x6e)
                else -> byteArrayOf()
            }
        }

        assertEquals(listOf(0x02.toByte(), 0x6e.toByte()), bytes.toList())
        assertEquals(item.steps, encodedSteps)
    }

    @Test
    fun legacyCombinationBecomesOneStepAndActiveModifierOnlyAppliesToPrefix() {
        val legacy = KeyboardBarCatalog.controlB
        assertEquals(
            listOf(KeyboardActionStep("b", setOf(KeyboardModifier.CONTROL, KeyboardModifier.ALT))),
            legacy.actionSteps(setOf(KeyboardModifier.ALT)),
        )

        val sequence = legacy.copy(steps = listOf(
            KeyboardActionStep("b", setOf(KeyboardModifier.CONTROL)),
            KeyboardActionStep("n"),
        ))
        assertEquals(
            listOf(
                KeyboardActionStep("b", setOf(KeyboardModifier.CONTROL, KeyboardModifier.SHIFT)),
                KeyboardActionStep("n"),
            ),
            sequence.actionSteps(setOf(KeyboardModifier.SHIFT)),
        )
    }

    @Test
    fun parsesBoundedSequenceStepSyntax() {
        assertEquals(KeyboardActionStep("n"), parseKeyboardActionStep("n"))
        assertEquals(
            KeyboardActionStep("c", setOf(KeyboardModifier.CONTROL)),
            parseKeyboardActionStep("Ctrl+c"),
        )
        assertEquals(KeyboardActionStep("ARROW_LEFT"), parseKeyboardActionStep("arrow_left"))
        assertNull(parseKeyboardActionStep("two"))
        assertNull(parseKeyboardActionStep("Ctrl+"))
    }

    @Test fun holdSwipeDefaultsFavorSafeFrequentActions() {
        val config = KeyboardBarConfig()

        assertTrue(config.holdSwipeEnabled)
        assertEquals(HoldSwipeActions.COPY_LATEST, config.holdSwipeActions[HoldSwipeDirection.UP])
        assertEquals(HoldSwipeActions.PASTE, config.holdSwipeActions[HoldSwipeDirection.RIGHT])
        assertEquals("key-escape", config.holdSwipeActions[HoldSwipeDirection.DOWN])
        assertEquals(HoldSwipeActions.NEXT_SESSION, config.holdSwipeActions[HoldSwipeDirection.LEFT])
    }
}
