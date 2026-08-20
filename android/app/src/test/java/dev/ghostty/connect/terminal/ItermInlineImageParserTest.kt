package dev.ghostty.connect.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.Base64

class ItermInlineImageParserTest {
    @Test
    fun `extracts an image when every byte arrives separately`() {
        val terminal = ByteArrayOutputStream()
        val images = mutableListOf<ItermInlineImage>()
        val parser = ItermInlineImageParser(terminal::write, images::add)
        val image = byteArrayOf(1, 2, 3, 4)
        val sequence = "before\u001b]1337;File=inline=1;width=4:${Base64.getEncoder().encodeToString(image)}\u0007after"
            .toByteArray()

        sequence.forEach { parser.feed(byteArrayOf(it)) }

        assertEquals("beforeafter", terminal.toString())
        assertEquals(1, images.size)
        assertArrayEquals(image, images.single().data)
        assertEquals("4", images.single().options["width"])
    }

    @Test
    fun `supports multipart images and ST terminators`() {
        val terminal = ByteArrayOutputStream()
        val images = mutableListOf<ItermInlineImage>()
        val parser = ItermInlineImageParser(terminal::write, images::add)
        val sequence = "\u001b]1337;MultipartFile=inline=1;size=4\u001b\\" +
            "output" +
            "\u001b]1337;FilePart=AQID\u0007" +
            "\u001b]1337;FilePart=BA==\u001b\\" +
            "\u001b]1337;FileEnd\u0007"

        parser.feed(sequence.toByteArray())

        assertEquals("output", terminal.toString())
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), images.single().data)
    }

    @Test
    fun `consumes malformed and non-inline file commands`() {
        val terminal = ByteArrayOutputStream()
        val images = mutableListOf<ItermInlineImage>()
        val parser = ItermInlineImageParser(terminal::write, images::add)

        parser.feed("a\u001b]1337;File=inline=1:not base64\u0007b\u001b]1337;File=inline=0:AQ==\u0007c".toByteArray())

        assertEquals("abc", terminal.toString())
        assertTrue(images.isEmpty())
    }

    @Test
    fun `passes unrelated OSC 1337 commands through unchanged`() {
        val terminal = ByteArrayOutputStream()
        val parser = ItermInlineImageParser(terminal::write) { error("Unexpected image") }
        val sequence = "\u001b]1337;CurrentDir=file:///tmp\u0007".toByteArray()

        parser.feed(sequence)

        assertArrayEquals(sequence, terminal.toByteArray())
    }

    @Test
    fun `rejects images larger than declared limit`() {
        val terminal = ByteArrayOutputStream()
        val images = mutableListOf<ItermInlineImage>()
        val parser = ItermInlineImageParser(terminal::write, images::add)

        parser.feed("\u001b]1337;File=inline=1;size=4194305:AQ==\u0007".toByteArray())

        assertTrue(images.isEmpty())
    }

    @Test
    fun `extracts an image through tmux passthrough`() {
        val terminal = ByteArrayOutputStream()
        val images = mutableListOf<ItermInlineImage>()
        val imageParser = ItermInlineImageParser(terminal::write, images::add)
        val tmuxParser = TmuxPassthroughParser(imageParser::feed)
        val inner = "\u001b]1337;File=inline=1:AQID\u0007".toByteArray()
        val escaped = inner.flatMap { if (it == 0x1b.toByte()) listOf(it, it) else listOf(it) }.toByteArray()
        val wrapped = "\u001bPtmux;".toByteArray() + escaped + "\u001b\\".toByteArray()

        wrapped.forEach { tmuxParser.feed(byteArrayOf(it)) }

        assertTrue(terminal.size() == 0)
        assertArrayEquals(byteArrayOf(1, 2, 3), images.single().data)
    }
}
