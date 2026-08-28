package dev.ghostty.connect.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardBarTest {
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
}
