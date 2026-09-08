package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.model.KeyboardBarCatalog
import dev.ghostty.connect.model.KeyboardBarConfig
import dev.ghostty.connect.model.KeyboardActionStep
import dev.ghostty.connect.model.KeyboardBarItem
import dev.ghostty.connect.model.KeyboardBarItemType
import dev.ghostty.connect.model.KeyboardModifier
import dev.ghostty.connect.model.actionSteps
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyboardBarStoreTest {
    private lateinit var context: Context
    private lateinit var encryptedStore: EncryptedFileStore

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        context.deleteFile(FILE_NAME)
        encryptedStore = EncryptedFileStore(context)
    }

    @After
    fun tearDown() {
        context.deleteFile(FILE_NAME)
    }

    @Test
    fun versionOneSettingsReceiveVolumeButtonDefaults() {
        encryptedStore.write(FILE_NAME, JSONObject().apply {
            put("version", 1)
            put("enabled", false)
            put("items", JSONArray())
            put("combinations", JSONArray())
        }.toString().toByteArray())

        val config = KeyboardBarStore(context).load()

        assertEquals(false, config.enabled)
        assertEquals(KeyboardBarCatalog.DEFAULT_VOLUME_UP_ACTION_ID, config.volumeUpActionId)
        assertEquals(KeyboardBarCatalog.DEFAULT_VOLUME_DOWN_ACTION_ID, config.volumeDownActionId)
    }

    @Test
    fun customVolumeActionsRoundTripAndUnknownIdsUseDefaults() {
        val store = KeyboardBarStore(context)
        store.save(KeyboardBarConfig(
            volumeUpActionId = KeyboardBarCatalog.SYSTEM_VOLUME_ACTION_ID,
            volumeDownActionId = "key-enter",
        ))

        assertEquals(KeyboardBarCatalog.SYSTEM_VOLUME_ACTION_ID, store.load().volumeUpActionId)
        assertEquals("key-enter", store.load().volumeDownActionId)

        val root = JSONObject(encryptedStore.read(FILE_NAME).toString(Charsets.UTF_8))
        root.put("volumeUpActionId", "removed-action")
        encryptedStore.write(FILE_NAME, root.toString().toByteArray())
        assertEquals(KeyboardBarCatalog.DEFAULT_VOLUME_UP_ACTION_ID, store.load().volumeUpActionId)
    }

    @Test
    fun multiStepCombinationRoundTrips() {
        val action = KeyboardBarItem(
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
        val store = KeyboardBarStore(context)

        store.save(KeyboardBarConfig(items = listOf(action), combinations = listOf(action)))

        assertEquals(action, store.load().items.single())
        assertEquals(action, store.load().combinations.single())
    }

    @Test
    fun versionThreeCombinationLoadsAsLegacySingleStep() {
        encryptedStore.write(FILE_NAME, JSONObject().apply {
            put("version", 3)
            put("items", JSONArray().put(JSONObject().apply {
                put("id", "legacy")
                put("label", "Ctrl+B")
                put("type", KeyboardBarItemType.COMBINATION.name)
                put("key", "b")
                put("modifiers", JSONArray().put(KeyboardModifier.CONTROL.name))
            }))
            put("combinations", JSONArray())
        }.toString().toByteArray())

        val action = KeyboardBarStore(context).load().items.single()

        assertEquals(emptyList<KeyboardActionStep>(), action.steps)
        assertEquals(listOf(KeyboardActionStep("b", setOf(KeyboardModifier.CONTROL))), action.actionSteps())
    }

    companion object {
        private const val FILE_NAME = "keyboard-bar.enc"
    }
}
