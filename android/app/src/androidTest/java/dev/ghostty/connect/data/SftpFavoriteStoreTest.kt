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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

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

    @Test
    fun concurrentAddsAcrossInstancesPreserveEveryPath() {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val paths = List(30) { "/srv/project-$it" }
        try {
            val futures = paths.map { path ->
                executor.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    assertTrue(SftpFavoriteStore(context).add("host-a", path))
                }
            }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }

            assertEquals(paths.toSet(), SftpFavoriteStore(context).load("host-a").toSet())
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    companion object {
        private const val FILE_NAME = "sftp-favorites.enc"
    }
}
