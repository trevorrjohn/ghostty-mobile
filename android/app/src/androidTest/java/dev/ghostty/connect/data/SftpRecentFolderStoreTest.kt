package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SftpRecentFolderStoreTest {
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
    fun recentsPersistInMruOrderAndRemainHostScoped() {
        val store = SftpRecentFolderStore(context)
        assertTrue(store.record("host-a", "/one"))
        assertTrue(store.record("host-a", "/two"))
        assertTrue(store.record("host-b", "/other"))
        assertTrue(store.record("host-a", "/one"))
        assertFalse(store.record("host-a", "/one"))

        assertEquals(listOf("/one", "/two"), SftpRecentFolderStore(context).load("host-a"))
        assertEquals(listOf("/other"), SftpRecentFolderStore(context).load("host-b"))
    }

    @Test
    fun evictsOldestFolderAtLimitAndClearsOnlyOneHost() {
        val store = SftpRecentFolderStore(context)
        val count = SftpRecentFolderStore.MAX_RECENT_FOLDERS_PER_HOST
        repeat(count + 2) { store.record("host-a", "/folder-$it") }
        store.record("host-b", "/keep")

        assertEquals((count + 1 downTo 2).map { "/folder-$it" }, store.load("host-a"))
        assertTrue(store.clear("host-a"))
        assertFalse(store.clear("host-a"))
        assertEquals(listOf("/keep"), store.load("host-b"))
    }

    @Test
    fun rejectsInvalidFolderKeysAndPaths() {
        val store = SftpRecentFolderStore(context)
        assertThrows(IllegalArgumentException::class.java) { store.record("", "/valid") }
        assertThrows(IllegalArgumentException::class.java) { store.record("host", "relative") }
        assertThrows(IllegalArgumentException::class.java) { store.record("host", "/bad\u0000path") }
        assertThrows(IllegalArgumentException::class.java) { store.record("host", "/" + "x".repeat(4097)) }
    }

    @Test
    fun concurrentRecordsAcrossInstancesPreserveBoundedUniquePaths() {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val count = SftpRecentFolderStore.MAX_RECENT_FOLDERS_PER_HOST
        val paths = List(count) { "/folder-$it" }
        try {
            val futures = paths.map { path ->
                executor.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    assertTrue(SftpRecentFolderStore(context).record("host-a", path))
                }
            }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }

            val stored = SftpRecentFolderStore(context).load("host-a")
            assertEquals(count, stored.size)
            assertEquals(paths.toSet(), stored.toSet())
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    companion object {
        private const val FILE_NAME = "sftp-recent-folders.enc"
    }
}
