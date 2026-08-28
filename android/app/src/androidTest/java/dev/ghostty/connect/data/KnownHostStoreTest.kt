package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class KnownHostStoreTest {
    private lateinit var context: Context
    private lateinit var encryptedStore: EncryptedFileStore

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().context
        encryptedStore = EncryptedFileStore(context)
        clearStorage()
    }

    @After
    fun tearDown() = clearStorage()

    @Test
    fun migratesAliasesAndGroupsEquivalentDestinations() {
        encryptedStore.write("known-hosts.enc", JSONObject().apply {
            put("EXAMPLE.com.:22", "SHA256:abc")
            put("example.com:022", "SHA256:abc")
        }.toString().toByteArray())

        val trustedHost = KnownHostStore(context).loadAll().single()
        val migrated = JSONObject(encryptedStore.read("known-hosts.enc").toString(Charsets.UTF_8))

        assertEquals("example.com:22", trustedHost.destination)
        assertEquals(setOf("EXAMPLE.com.:22", "example.com:022"), trustedHost.storageIds)
        assertFalse(trustedHost.isConflicted)
        assertEquals(2, migrated.getInt("version"))
    }

    @Test
    fun conflictingAliasesFailClosedUntilExplicitReplacement() {
        encryptedStore.write("known-hosts.enc", JSONObject().apply {
            put("EXAMPLE.com:22", "SHA256:first")
            put("example.com.:22", "SHA256:second")
        }.toString().toByteArray())
        val store = KnownHostStore(context)

        val conflict = store.loadAll().single()
        val lookup = store.lookup("example.com", 22)

        assertTrue(conflict.isConflicted)
        assertEquals(null, lookup.fingerprint)
        assertTrue(lookup.hasExistingTrust)
        assertTrue(store.trust(lookup, "SHA256:replacement"))
        assertEquals("SHA256:replacement", store.lookup("EXAMPLE.com.", 22).fingerprint)
        assertEquals(setOf("example.com:22"), store.loadAll().single().storageIds)
    }

    @Test
    fun staleApprovalCannotOverwriteNewerTrust() {
        val firstStore = KnownHostStore(context)
        val secondStore = KnownHostStore(context)
        val first = firstStore.lookup("example.com", 22)
        val stale = secondStore.lookup("EXAMPLE.com.", 22)

        assertTrue(firstStore.trust(first, "SHA256:first"))
        assertFalse(secondStore.trust(stale, "SHA256:stale"))
        assertEquals("SHA256:first", firstStore.lookup("example.com", 22).fingerprint)
    }

    @Test
    fun groupedRemovalDeletesEveryEquivalentAlias() {
        encryptedStore.write("known-hosts.enc", JSONObject().apply {
            put("EXAMPLE.com:22", "SHA256:abc")
            put("example.com.:22", "SHA256:abc")
        }.toString().toByteArray())
        val store = KnownHostStore(context)

        assertTrue(store.remove(store.loadAll().single()))

        assertFalse(store.lookup("example.com", 22).hasExistingTrust)
        assertTrue(store.loadAll().isEmpty())
    }

    @Test
    fun malformedRecordDoesNotHideValidTrustAndRemainsRemovable() {
        encryptedStore.write("known-hosts.enc", JSONObject().apply {
            put("malformed", "")
            put("example.com:22", "SHA256:abc")
        }.toString().toByteArray())
        val store = KnownHostStore(context)

        val records = store.loadAll()
        val malformed = records.single { it.hostname == null }

        assertEquals("SHA256:abc", store.lookup("example.com", 22).fingerprint)
        assertTrue(store.remove(malformed))
        assertEquals(1, store.loadAll().size)
    }

    @Test
    fun migratesLegacyPreferencesAfterEncryptedCommit() {
        context.getSharedPreferences("known_hosts", Context.MODE_PRIVATE).edit()
            .putString("EXAMPLE.com.:22", "SHA256:abc")
            .commit()

        val lookup = KnownHostStore(context).lookup("example.com", 22)

        assertEquals("SHA256:abc", lookup.fingerprint)
        assertTrue(encryptedStore.exists("known-hosts.enc"))
    }

    @Test
    fun refusesUnknownSchemaWithoutOverwritingIt() {
        val original = JSONObject().apply {
            put("version", 3)
            put("records", org.json.JSONArray())
        }.toString().toByteArray()
        encryptedStore.write("known-hosts.enc", original)

        assertThrows(IllegalArgumentException::class.java) { KnownHostStore(context).loadAll() }
        assertTrue(original.contentEquals(encryptedStore.read("known-hosts.enc")))
    }

    @Test
    fun concurrentTrustAcrossInstancesPreservesEveryDestination() {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val destinations = List(20) { index -> "server-$index.example.com" }
        try {
            val futures = destinations.mapIndexed { index, hostname ->
                executor.submit {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    val store = KnownHostStore(context)
                    assertTrue(store.trust(store.lookup(hostname, 22), "SHA256:$index"))
                }
            }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }

            assertEquals(destinations.toSet(), KnownHostStore(context).loadAll().mapNotNull { it.hostname }.toSet())
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    private fun clearStorage() {
        context.fileList().filter { it.startsWith("known-hosts.enc") }.forEach(context::deleteFile)
        context.getSharedPreferences("known_hosts", Context.MODE_PRIVATE).edit().clear().commit()
    }
}
