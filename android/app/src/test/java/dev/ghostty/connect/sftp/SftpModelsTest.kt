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
    fun canonicalAbsolutePathStackProvidesParentNavigationToRoot() {
        assertEquals(
            listOf("/", "/home", "/home/ghost", "/home/ghost/projects", "/home/ghost/projects/app"),
            remoteAbsolutePathStack("/home/ghost/projects/app"),
        )
        assertEquals(listOf("/"), remoteAbsolutePathStack("/"))
        assertEquals(listOf("/", "/var", "/var/tmp"), remoteAbsolutePathStack("/var/tmp"))
        assertTrue(runCatching { remoteAbsolutePathStack("relative/path") }.isFailure)
    }

    @Test
    fun favoriteFolderPathUsesOneValidatedChild() {
        assertEquals("/home/ghost/projects", remoteFolderPath("/home/ghost", "projects"))
        assertEquals("/tmp", remoteFolderPath("/", "tmp"))
        assertTrue(runCatching { remoteFolderPath("/home/ghost", "../private") }.isFailure)
        assertTrue(runCatching { remoteFolderPath("relative", "projects") }.isFailure)
    }

    @Test
    fun fuzzySearchRanksPrefixBeforeSubstringAndSubsequence() {
        val entries = listOf(
            SftpEntry("thread-read.log", SftpEntryType.FILE),
            SftpEntry("README.md", SftpEntryType.FILE),
            SftpEntry("remote-app-data", SftpEntryType.DIRECTORY),
            SftpEntry("unrelated.txt", SftpEntryType.FILE),
        )

        val matches = filterAndSortSftpEntries(entries, "read", SftpSortMode.NAME, false)

        assertEquals(
            listOf("remote-app-data", "README.md", "thread-read.log", "unrelated.txt"),
            matches.map(SftpEntry::name),
        )
        assertTrue(fuzzyScore("configuration", "cfg") != null)
        assertNull(fuzzyScore("README.md", "cfg"))
    }

    @Test
    fun sortingKeepsDirectoriesFirstAndUnknownMetadataLast() {
        val entries = listOf(
            SftpEntry("small", SftpEntryType.FILE, size = 10, modifiedAtSeconds = 30),
            SftpEntry("folder", SftpEntryType.DIRECTORY),
            SftpEntry("unknown", SftpEntryType.FILE),
            SftpEntry("large", SftpEntryType.FILE, size = 100, modifiedAtSeconds = 20),
        )

        assertEquals(
            listOf("folder", "large", "small", "unknown"),
            filterAndSortSftpEntries(entries, "", SftpSortMode.SIZE, true).map(SftpEntry::name),
        )
        assertEquals(
            listOf("folder", "large", "small", "unknown"),
            filterAndSortSftpEntries(entries, "", SftpSortMode.MODIFIED, false).map(SftpEntry::name),
        )
    }
}
