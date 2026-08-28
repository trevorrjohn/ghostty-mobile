package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.model.RetryBackoff
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
class HostStoreConcurrencyTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        clearStorage()
    }

    @After
    fun tearDown() = clearStorage()

    @Test
    fun concurrentSavesAcrossInstancesPreserveEveryHost() {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val hosts = List(20) { index ->
            Host(
                id = "host-$index",
                alias = "Host $index",
                hostname = "server-$index.example.com",
                username = "user",
                authenticationType = AuthenticationType.PASSWORD,
            )
        }
        try {
            val futures = hosts.map { host ->
                executor.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    HostStore(context, SshKeyStore(context)).save(host)
                }
            }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }

            assertEquals(hosts.mapTo(mutableSetOf(), Host::id),
                HostStore(context, SshKeyStore(context)).loadAll().mapTo(mutableSetOf(), Host::id))
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    @Test
    fun retryPolicyRoundTripsThroughEncryptedHostStore() {
        val host = Host(
            id = "host",
            hostname = "server.example.com",
            username = "user",
            retryEnabled = false,
            retryMaxAttempts = 8,
            retryBackoff = RetryBackoff.CONSERVATIVE,
        )

        HostStore(context, SshKeyStore(context)).save(host)

        assertEquals(host, HostStore(context, SshKeyStore(context)).loadAll().single())
    }

    private fun clearStorage() {
        context.fileList().filter { it == "hosts.enc" || it.startsWith("ssh-identity-") }
            .forEach(context::deleteFile)
        context.getSharedPreferences("hosts", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE).edit().clear().commit()
    }
}
