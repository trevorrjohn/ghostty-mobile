package dev.ghostty.connect.data

import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.ghostty.connect.model.AuthenticationType
import dev.ghostty.connect.model.Host
import dev.ghostty.connect.model.SshIdentity
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
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
class SshIdentityMigrationTest {
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
    fun migratesLegacyKeysIdempotentlyWithoutRemovingRecoveryFiles() {
        val key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        encryptedStore.write("ssh-key-index.enc", JSONArray(listOf("work")).toString().toByteArray())
        encryptedStore.write(legacyIdentityFileName("work"), key)

        val store = SshKeyStore(context)
        val first = store.identities().single()
        val second = store.identities().single()

        assertEquals(first.id, second.id)
        assertEquals("work", first.name)
        assertArrayEquals(key, store.read(first.id))
        assertEquals(false, first.requiresPassphrase)
        assertEquals(true, encryptedStore.exists("ssh-key-index.enc"))
        assertEquals(true, encryptedStore.exists(legacyIdentityFileName("work")))
    }

    @Test
    fun rejectsCollidingLegacyNamesWithoutCommittingMigration() {
        val key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        encryptedStore.write("ssh-key-index.enc", JSONArray(listOf("Aa", "BB")).toString().toByteArray())
        encryptedStore.write(legacyIdentityFileName("Aa"), key)

        val failure = runCatching { SshKeyStore(context).identities() }.exceptionOrNull()

        assertTrue(failure != null)
        assertFalse(encryptedStore.exists("ssh-identity-index.enc"))
        assertTrue(context.fileList().none { it.startsWith("ssh-identity-") })
    }

    @Test
    fun duplicateImportCreatesAnotherIdentityWithoutOverwriting() {
        val firstKey = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        val secondKey = "-----BEGIN PRIVATE KEY-----\nBBBB\n-----END PRIVATE KEY-----\n".toByteArray()
        val store = SshKeyStore(context)

        val first = store.import("work", firstKey)
        val second = store.import("WORK", secondKey)

        assertEquals("work", first.name)
        assertEquals("WORK 2", second.name)
        assertArrayEquals(firstKey, store.read(first.id))
        assertArrayEquals(secondKey, store.read(second.id))
    }

    @Test
    fun renamePreservesIdentityAndKeyDataWithCollisionSafeName() {
        val firstKey = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        val secondKey = "-----BEGIN PRIVATE KEY-----\nBBBB\n-----END PRIVATE KEY-----\n".toByteArray()
        val store = SshKeyStore(context)
        store.import("Work", firstKey)
        val identity = store.import("Personal", secondKey)

        val renamed = store.rename(identity.id, "work")

        assertEquals(identity.id, renamed.id)
        assertEquals("work 2", renamed.name)
        assertEquals(identity.algorithm, renamed.algorithm)
        assertEquals(identity.fingerprint, renamed.fingerprint)
        assertArrayEquals(secondKey, store.read(identity.id))
    }

    @Test
    fun deleteRemovesIdentityBlobAndIsIdempotent() {
        val key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        val store = SshKeyStore(context)
        val identity = store.import("Work", key)

        assertTrue(store.delete(identity.id))

        assertTrue(store.identities().isEmpty())
        assertFalse(context.fileList().contains("ssh-identity-${identity.id}.enc"))
        assertFalse(store.delete(identity.id))
    }

    @Test
    fun deleteLeavesAffectedHostReferenceAvailableForRepair() {
        val key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        val keyStore = SshKeyStore(context)
        val identity = keyStore.import("Work", key)
        val hostStore = HostStore(context, keyStore)
        hostStore.save(Host(
            id = "host-id",
            alias = "Production",
            hostname = "server.example.com",
            username = "deploy",
            authenticationType = AuthenticationType.SSH_KEY,
            identityId = identity.id,
        ))

        keyStore.delete(identity.id)
        val storedHost = hostStore.loadAll().single()

        assertEquals(AuthenticationType.SSH_KEY, storedHost.authenticationType)
        assertEquals(identity.id, storedHost.identityId)
    }

    @Test
    fun interruptedMigrationRetainsOrphanAndLegacyRecoveryBlobs() {
        val key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        val orphanName = "ssh-identity-00000000-0000-0000-0000-000000000001.enc"
        encryptedStore.write(orphanName, key)
        encryptedStore.write("ssh-key-index.enc", JSONArray(listOf("work")).toString().toByteArray())
        encryptedStore.write(legacyIdentityFileName("work"), key)

        SshKeyStore(context).identities()

        assertTrue(encryptedStore.exists(orphanName))
        assertTrue(encryptedStore.exists("ssh-key-index.enc"))
        assertTrue(encryptedStore.exists(legacyIdentityFileName("work")))
    }

    @Test
    fun corruptIdentityIndexFailsWithoutFallingBackOrOverwriting() {
        val corruptIndex = "{not-json".toByteArray()
        encryptedStore.write("ssh-identity-index.enc", corruptIndex)
        encryptedStore.write("ssh-key-index.enc", JSONArray(listOf("work")).toString().toByteArray())

        val failure = runCatching { SshKeyStore(context).identities() }.exceptionOrNull()

        assertTrue(failure != null)
        assertArrayEquals(corruptIndex, encryptedStore.read("ssh-identity-index.enc"))
        assertTrue(encryptedStore.exists("ssh-key-index.enc"))
    }

    @Test
    fun migratesLegacyHostReferenceAfterIdentityCommit() {
        val key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        encryptedStore.write("ssh-key-index.enc", JSONArray(listOf("work")).toString().toByteArray())
        encryptedStore.write(legacyIdentityFileName("work"), key)
        encryptedStore.write("hosts.enc", JSONArray().apply {
            put(JSONObject().apply {
                put("id", "host-id")
                put("alias", "Production")
                put("hostname", "server.example.com")
                put("port", 22)
                put("username", "deploy")
                put("authenticationType", AuthenticationType.SSH_KEY.name)
                put("keyName", "work")
                put("allowRemoteClipboard", JSONObject.NULL)
                put("allowRemoteNotifications", JSONObject.NULL)
            })
        }.toString().toByteArray())

        val keyStore = SshKeyStore(context)
        val host = HostStore(context, keyStore).loadAll().single()
        val storedHosts = encryptedStore.read("hosts.enc").toString(Charsets.UTF_8)

        assertEquals(keyStore.identities().single().id, host.identityId)
        assertTrue(storedHosts.contains("\"keyName\":\"work\""))
        assertEquals(true, JSONObject(JSONArray(storedHosts).getJSONObject(0).toString()).has("identityId"))
    }

    @Test
    fun migratesPreferencesOnlyStorageAndRetainsRollbackData() {
        val key = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n".toByteArray()
        context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE).edit()
            .putStringSet("names", setOf("work"))
            .commit()
        encryptedStore.write(legacyIdentityFileName("work"), key)
        context.getSharedPreferences("hosts", Context.MODE_PRIVATE).edit()
            .putString("hostname", "server.example.com")
            .putInt("port", 2222)
            .putString("username", "deploy")
            .putString("keyName", "work")
            .commit()

        val keyStore = SshKeyStore(context)
        val first = HostStore(context, keyStore).loadAll().single()
        val second = HostStore(context, keyStore).loadAll().single()

        assertEquals(first.identityId, second.identityId)
        assertArrayEquals(key, keyStore.read(requireNotNull(first.identityId)))
        assertEquals(setOf("work"), context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE)
            .getStringSet("names", emptySet()))
        assertEquals("work", context.getSharedPreferences("hosts", Context.MODE_PRIVATE)
            .getString("keyName", null))
        assertTrue(encryptedStore.exists(legacyIdentityFileName("work")))
    }

    @Test
    fun stableMissingIdentityReferenceRemainsEditable() {
        encryptedStore.write("hosts.enc", JSONArray().apply {
            put(JSONObject().apply {
                put("id", "host-id")
                put("alias", "Recovery")
                put("hostname", "server.example.com")
                put("port", 22)
                put("username", "deploy")
                put("authenticationType", AuthenticationType.SSH_KEY.name)
                put("identityId", "00000000-0000-0000-0000-000000000001")
                put("allowRemoteClipboard", JSONObject.NULL)
                put("allowRemoteNotifications", JSONObject.NULL)
            })
        }.toString().toByteArray())

        val host = HostStore(context, SshKeyStore(context)).loadAll().single()

        assertEquals("00000000-0000-0000-0000-000000000001", host.identityId)
    }

    @Test
    fun concurrentImportsAcrossInstancesPreserveEveryIdentityAndBlob() {
        val executor = Executors.newFixedThreadPool(8)
        val start = CountDownLatch(1)
        val keys = List(12) { index ->
            "-----BEGIN PRIVATE KEY-----\nKEY-$index\n-----END PRIVATE KEY-----\n".toByteArray()
        }
        try {
            val futures = keys.mapIndexed { index, key ->
                executor.submit<SshIdentity> {
                    assertTrue(start.await(5, TimeUnit.SECONDS))
                    SshKeyStore(context).import("Key $index", key)
                }
            }
            start.countDown()
            val imported = futures.map { it.get(10, TimeUnit.SECONDS) }
            val restored = SshKeyStore(context)

            assertEquals(imported.mapTo(mutableSetOf()) { it.id }, restored.identities().mapTo(mutableSetOf()) { it.id })
            imported.forEachIndexed { index, identity -> assertArrayEquals(keys[index], restored.read(identity.id)) }
        } finally {
            executor.shutdownNow()
            executor.awaitTermination(5, TimeUnit.SECONDS)
        }
    }

    private fun clearStorage() {
        context.fileList().filter { file ->
            file == "hosts.enc" || file.startsWith("ssh-key-") || file.startsWith("ssh-identity-")
        }.forEach(context::deleteFile)
        context.getSharedPreferences("ssh_keys", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("hosts", Context.MODE_PRIVATE).edit().clear().commit()
    }
}
