package dev.ghostty.connect.sftp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SftpModelsTest {
    @Test
    fun childNamesRejectTraversalSeparatorsAndNul() {
        listOf("", "   ", ".", "..", "child/name", "child\\name", "child\u0000name").forEach { name ->
            assertFalse("Expected unsafe name: $name", safeRemoteChildName(name))
        }
    }

    @Test
    fun childNamesEnforceUtf8ByteBound() {
        assertTrue(safeRemoteChildName("a".repeat(MAX_REMOTE_NAME_BYTES)))
        assertFalse(safeRemoteChildName("é".repeat(128)))
    }

    @Test
    fun ordinaryUnicodeChildNameIsAcceptedUnchanged() {
        val name = "release-東京.txt"

        assertNull(remoteChildNameError(name))
        assertTrue(safeRemoteChildName(name))
    }

    @Test
    fun transferStateDoesNotRequireKnownTotal() {
        val transfer = SftpTransferState(
            direction = SftpTransferDirection.DOWNLOAD,
            displayName = "artifact",
            transferred = 64,
            total = null,
            status = SftpTransferStatus.RUNNING,
        )

        assertEquals(64, transfer.transferred)
        assertNull(transfer.total)
    }

    @Test
    fun canonicalPathContainmentDoesNotAcceptPrefixLookalikes() {
        assertTrue(remotePathWithinHome("/home/ghost", "/home/ghost"))
        assertTrue(remotePathWithinHome("/home/ghost", "/home/ghost/projects/app"))
        assertFalse(remotePathWithinHome("/home/ghost", "/home/ghost-other/private"))
        assertFalse(remotePathWithinHome("/home/ghost", "/etc"))
        assertTrue(remotePathWithinHome("/", "/var/tmp"))
    }

    @Test
    fun canonicalPathStackProvidesRealParentNavigation() {
        assertEquals(
            listOf("/home/ghost", "/home/ghost/projects", "/home/ghost/projects/app"),
            remotePathStack("/home/ghost", "/home/ghost/projects/app"),
        )
        assertEquals(listOf("/"), remotePathStack("/", "/"))
        assertEquals(listOf("/", "/var", "/var/tmp"), remotePathStack("/", "/var/tmp"))
    }

    @Test
    fun favoriteFolderPathUsesOneValidatedChild() {
        assertEquals("/home/ghost/projects", remoteFolderPath("/home/ghost", "projects"))
        assertEquals("/tmp", remoteFolderPath("/", "tmp"))
        assertTrue(runCatching { remoteFolderPath("/home/ghost", "../private") }.isFailure)
        assertTrue(runCatching { remoteFolderPath("relative", "projects") }.isFailure)
    }
}
