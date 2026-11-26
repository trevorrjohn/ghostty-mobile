package dev.ghostty.connect.sftp

import java.time.Instant
import java.time.ZoneOffset
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ImageUploadTest {
    private val now = Instant.parse("2026-11-25T14:30:05Z")

    @Test
    fun fileNamesAreTimestampedAndUnique() {
        val first = imageUploadFileName(now, "png", ZoneOffset.UTC, Random(1))
        val second = imageUploadFileName(now, "png", ZoneOffset.UTC, Random(2))
        assertTrue(first, Regex("screenshot-20261125-143005-[a-z0-9]{4}\\.png").matches(first))
        assertNotEquals(first, second)
    }

    @Test
    fun fileNameExtensionIsSanitized() {
        assertTrue(imageUploadFileName(now, "JPG", ZoneOffset.UTC).endsWith(".jpg"))
        assertTrue(imageUploadFileName(now, "../x", ZoneOffset.UTC).endsWith(".x"))
        assertTrue(imageUploadFileName(now, "", ZoneOffset.UTC).endsWith(".png"))
        assertNull(remoteChildNameError(imageUploadFileName(now, "png", ZoneOffset.UTC)))
    }

    @Test
    fun safePathsAreNotQuoted() {
        assertEquals("/home/me/project/a-b_c.png", shellQuotePath("/home/me/project/a-b_c.png"))
    }

    @Test
    fun unsafePathsAreSingleQuoted() {
        assertEquals("'/srv/my project/a.png'", shellQuotePath("/srv/my project/a.png"))
        assertEquals("'/srv/it'\\''s/a.png'", shellQuotePath("/srv/it's/a.png"))
        assertEquals("'/srv/\$HOME/`x`.png'", shellQuotePath("/srv/\$HOME/`x`.png"))
    }

    @Test
    fun pastedTextJoinsPathsWithoutExecutingAnything() {
        val text = pastedUploadPaths(listOf("/a/one.png", "/a b/two.png"))
        assertEquals("/a/one.png '/a b/two.png'", text)
        assertFalse(text.contains('\n') || text.contains('\r'))
    }

    @Test
    fun promptOnlyWhenAskingWithAKnownDirectory() {
        assertTrue(shouldPromptForImageDestination(ImageUploadDestinationMode.ASK, "/srv"))
        assertFalse(shouldPromptForImageDestination(ImageUploadDestinationMode.ASK, null))
        assertFalse(shouldPromptForImageDestination(ImageUploadDestinationMode.CURRENT_DIRECTORY, "/srv"))
        assertFalse(shouldPromptForImageDestination(ImageUploadDestinationMode.UPLOADS_FOLDER, "/srv"))
    }

    @Test
    fun uploadsFolderModeIgnoresTheTerminalDirectory() {
        assertNull(imageUploadTerminalDirectory(ImageUploadDestinationMode.UPLOADS_FOLDER, "/srv"))
        assertEquals("/srv", imageUploadTerminalDirectory(ImageUploadDestinationMode.CURRENT_DIRECTORY, "/srv"))
        assertEquals("/srv", imageUploadTerminalDirectory(ImageUploadDestinationMode.ASK, "/srv"))
        assertNull(imageUploadTerminalDirectory(ImageUploadDestinationMode.CURRENT_DIRECTORY, null))
    }

    @Test
    fun hostChoiceWinsOtherwiseMenuUsesCurrentDirectoryAndShareAsks() {
        assertEquals(ImageUploadDestinationMode.CURRENT_DIRECTORY, resolveImageUploadMode(null, shared = false))
        assertEquals(ImageUploadDestinationMode.ASK, resolveImageUploadMode(null, shared = true))
        assertEquals(ImageUploadDestinationMode.UPLOADS_FOLDER, resolveImageUploadMode(ImageUploadDestinationMode.UPLOADS_FOLDER, shared = true))
        assertEquals(ImageUploadDestinationMode.ASK, resolveImageUploadMode(ImageUploadDestinationMode.ASK, shared = false))
    }

    @Test
    fun shareInSkipsThePickerOnlyForOneLiveSession() {
        assertFalse(shareInGoesToSingleSession(0))
        assertTrue(shareInGoesToSingleSession(1))
        assertFalse(shareInGoesToSingleSession(2))
    }

    @Test
    fun scalingNeverUpscalesAndKeepsAspectRatio() {
        assertEquals(1000 to 500, scaledImageSize(1000, 500, 2048))
        assertEquals(2048 to 1536, scaledImageSize(4000, 3000, 2048))
        assertEquals(1536 to 2048, scaledImageSize(3000, 4000, 2048))
        assertEquals(2048 to 1, scaledImageSize(100000, 40, 2048))
    }

    @Test
    fun sampleSizeKeepsAtLeastTheTargetResolution() {
        assertEquals(1, imageSampleSize(2000, 1000, 2048))
        assertEquals(1, imageSampleSize(4000, 3000, 2048))
        assertEquals(2, imageSampleSize(4096, 3000, 2048))
        assertEquals(4, imageSampleSize(9000, 6000, 2048))
    }

    @Test
    fun screenshotsStayPngAndPhotosBecomeJpeg() {
        assertTrue(usesPngOutput("image/png"))
        assertTrue(usesPngOutput("IMAGE/WEBP"))
        assertFalse(usesPngOutput("image/heic"))
        assertFalse(usesPngOutput("image/jpeg"))
    }

    @Test
    fun onlyImageMimeTypesAreUploadable() {
        assertTrue(isUploadableImageMime("image/heic"))
        assertFalse(isUploadableImageMime("application/pdf"))
        assertFalse(isUploadableImageMime(null))
    }

    @Test
    fun boundedCopyFailsInsteadOfTruncating() {
        val sink = java.io.ByteArrayOutputStream()
        assertEquals(10L, copyBounded(ByteArray(10).inputStream(), sink, 10))
        assertThrows(java.io.IOException::class.java) { copyBounded(ByteArray(11).inputStream(), java.io.ByteArrayOutputStream(), 10) }
    }
}
