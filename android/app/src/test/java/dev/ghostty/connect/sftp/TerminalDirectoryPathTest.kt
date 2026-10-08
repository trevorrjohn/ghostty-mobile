package dev.ghostty.connect.sftp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TerminalDirectoryPathTest {
    @Test
    fun extractsAbsolutePathsAndDecodesOsc7Paths() {
        assertEquals("/srv/project", terminalDirectoryPath("/srv/project"))
        assertEquals("/srv/my project", terminalDirectoryPath("file://remote/srv/my%20project"))
        assertEquals("/", terminalDirectoryPath("file://remote/"))
    }

    @Test
    fun rejectsNonDirectoryMetadataAndUnboundedPaths() {
        listOf("", "relative/path", "https://remote/srv", "file://remote", "file://remote/srv?query",
            "file://remote/srv#fragment", "file://user@remote/srv", "file://remote/%00",
            "/" + "a".repeat(4096), "file://remote/%ZZ").forEach { assertNull(terminalDirectoryPath(it)) }
    }
}
