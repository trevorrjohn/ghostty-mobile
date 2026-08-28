package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class EncryptedFileStoreTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        clearStorage()
    }

    @After
    fun tearDown() = clearStorage()

    @Test
    fun fileLockIsSharedAcrossStoreInstances() {
        val executor = Executors.newFixedThreadPool(2)
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondReady = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        try {
            val first = executor.submit {
                EncryptedFileStore(context).withFileLock(FILE_NAME) {
                    firstEntered.countDown()
                    assertTrue(releaseFirst.await(5, TimeUnit.SECONDS))
                }
            }
            assertTrue(firstEntered.await(5, TimeUnit.SECONDS))
            val second = executor.submit {
                secondReady.countDown()
                EncryptedFileStore(context).withFileLock(FILE_NAME) { secondEntered.countDown() }
            }

            assertTrue(secondReady.await(5, TimeUnit.SECONDS))
            assertFalse(secondEntered.await(150, TimeUnit.MILLISECONDS))
            releaseFirst.countDown()
            first.get(5, TimeUnit.SECONDS)
            second.get(5, TimeUnit.SECONDS)
            assertTrue(secondEntered.await(5, TimeUnit.SECONDS))
        } finally {
            releaseFirst.countDown()
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    @Test
    fun concurrentAccessAlwaysLeavesACompleteEncryptedPayload() {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val payloads = List(32) { index -> "payload-$index-${"x".repeat(index * 17)}".toByteArray() }
        try {
            val futures = payloads.map { payload ->
                executor.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    val store = EncryptedFileStore(context)
                    store.write(FILE_NAME, payload)
                    assertTrue(store.read(FILE_NAME).contentEqualsAny(payloads))
                }
            }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }

            assertTrue(EncryptedFileStore(context).read(FILE_NAME).contentEqualsAny(payloads))
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    private fun ByteArray.contentEqualsAny(values: List<ByteArray>): Boolean = values.any(::contentEquals)

    private fun clearStorage() {
        context.fileList().filter { it.startsWith(FILE_NAME) }.forEach(context::deleteFile)
    }

    companion object {
        private const val FILE_NAME = "encrypted-store-concurrency-test.enc"
    }
}
