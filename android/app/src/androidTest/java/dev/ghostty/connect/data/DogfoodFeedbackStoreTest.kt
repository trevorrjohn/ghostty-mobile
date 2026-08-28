package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.model.DogfoodFeedbackEntry
import dev.ghostty.connect.model.FeedbackKind
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class DogfoodFeedbackStoreTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        clearStorage()
    }

    @After
    fun tearDown() = clearStorage()

    @Test
    fun concurrentAppendsAcrossInstancesPreserveEveryEntry() {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val entries = List(40, ::entry)
        try {
            val futures = entries.map { entry ->
                executor.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    DogfoodFeedbackStore(context).append(entry)
                }
            }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }

            assertEquals(entries.mapTo(mutableSetOf(), DogfoodFeedbackEntry::id),
                DogfoodFeedbackStore(context).loadAll().mapTo(mutableSetOf(), DogfoodFeedbackEntry::id))
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    private fun entry(index: Int) = DogfoodFeedbackEntry(
        id = "entry-$index",
        createdAtEpochMillis = index.toLong(),
        kind = FeedbackKind.BUG,
        area = "Terminal",
        note = "Concurrent note $index",
        appVersion = "test",
        versionCode = 1,
        androidApi = 36,
        deviceModel = "test",
    )

    private fun clearStorage() {
        context.fileList().filter { it.startsWith("dogfood-feedback") }.forEach(context::deleteFile)
    }
}
