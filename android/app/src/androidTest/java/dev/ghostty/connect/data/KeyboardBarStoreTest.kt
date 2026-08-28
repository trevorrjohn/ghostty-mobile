package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.model.KeyboardBarCatalog
import dev.ghostty.connect.model.KeyboardBarConfig
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

    companion object {
        private const val FILE_NAME = "keyboard-bar.enc"
    }
}
