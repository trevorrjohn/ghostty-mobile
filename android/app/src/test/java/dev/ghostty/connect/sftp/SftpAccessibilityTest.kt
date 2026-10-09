package dev.ghostty.connect.sftp

import org.junit.Assert.assertEquals
import org.junit.Test

class SftpAccessibilityTest {
    @Test
    fun entryDescriptionsExposeTypeNameAndPrimaryAction() {
        assertEquals(
            "Directory, src. Tap to open. Long press for details and actions.",
            sftpEntryAccessibilityDescription(SftpEntry("src", SftpEntryType.DIRECTORY), actionable = true),
        )
        assertEquals(
            "File, README.md. Tap to open. Long press for details and actions.",
            sftpEntryAccessibilityDescription(SftpEntry("README.md", SftpEntryType.FILE), actionable = true),
        )
        assertEquals(
            "Symbolic link, current. Long press for details and actions.",
            sftpEntryAccessibilityDescription(SftpEntry("current", SftpEntryType.SYMLINK), actionable = true),
        )
        assertEquals(
            "Unsupported entry, socket. Long press for details and actions.",
            sftpEntryAccessibilityDescription(SftpEntry("socket", SftpEntryType.UNSUPPORTED), actionable = true),
        )
    }

    @Test
    fun disconnectedEntriesDoNotAdvertiseOpenAction() {
        assertEquals(
            "Directory, src. Long press for details and actions.",
            sftpEntryAccessibilityDescription(SftpEntry("src", SftpEntryType.DIRECTORY), actionable = false),
        )
    }
}
