package dev.ghostty.connect.sftp

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SftpPreviewProviderTest {
    @Test
    fun previewUriStreamsPrivateCacheThroughContentResolver() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val uri = SftpPreviewProvider.createUri(context, "notes.txt")
        val expected = "remote contents".toByteArray()

        context.contentResolver.openOutputStream(uri, "w")!!.use { it.write(expected) }

        assertEquals("text/plain", context.contentResolver.getType(uri))
        assertArrayEquals(expected, context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
        assertEquals(1, context.contentResolver.delete(uri, null, null))
    }
}
