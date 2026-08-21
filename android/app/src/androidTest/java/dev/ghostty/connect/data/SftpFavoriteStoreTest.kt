package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SftpFavoriteStoreTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        context.deleteFile(FILE_NAME)
    }

    @After
    fun tearDown() {
        context.deleteFile(FILE_NAME)
    }

    @Test
    fun favoritesPersistAcrossStoreInstancesAndRemainHostScoped() {
        val first = SftpFavoriteStore(context)

        assertTrue(first.add("host-a", "/home/ghost/projects"))
        assertFalse(first.add("host-a", "/home/ghost/projects"))
        assertTrue(first.add("host-b", "/srv/releases"))

        val restored = SftpFavoriteStore(context)
        assertEquals(listOf("/home/ghost/projects"), restored.load("host-a"))
        assertEquals(listOf("/srv/releases"), restored.load("host-b"))
        assertTrue(restored.remove("host-a", "/home/ghost/projects"))
        assertEquals(emptyList<String>(), SftpFavoriteStore(context).load("host-a"))
    }

    companion object {
        private const val FILE_NAME = "sftp-favorites.enc"
    }
}
