package dev.ghostty.connect.model

data class TerminalTheme(
    val id: String,
    val name: String,
    val foreground: Int,
    val background: Int,
    val cursor: Int,
    val palette: IntArray,
)

object TerminalThemes {
    val all = listOf(
        theme("ghostty", "Ghostty", 0xfff1f3f8.toInt(), 0xff0a0c10.toInt(), 0xff8be9b3.toInt(), intArrayOf(
            0xff1d1f21.toInt(), 0xffcc6666.toInt(), 0xffb5bd68.toInt(), 0xfff0c674.toInt(),
            0xff81a2be.toInt(), 0xffb294bb.toInt(), 0xff8abeb7.toInt(), 0xffc5c8c6.toInt(),
            0xff666666.toInt(), 0xffd54e53.toInt(), 0xffb9ca4a.toInt(), 0xffe7c547.toInt(),
            0xff7aa6da.toInt(), 0xffc397d8.toInt(), 0xff70c0b1.toInt(), 0xffeaeaea.toInt(),
        )),
        theme("dracula", "Dracula", 0xfff8f8f2.toInt(), 0xff282a36.toInt(), 0xffff79c6.toInt(), intArrayOf(
            0xff21222c.toInt(), 0xffff5555.toInt(), 0xff50fa7b.toInt(), 0xfff1fa8c.toInt(),
            0xffbd93f9.toInt(), 0xffff79c6.toInt(), 0xff8be9fd.toInt(), 0xfff8f8f2.toInt(),
            0xff6272a4.toInt(), 0xffff6e6e.toInt(), 0xff69ff94.toInt(), 0xffffffa5.toInt(),
            0xffd6acff.toInt(), 0xffff92df.toInt(), 0xffa4ffff.toInt(), 0xffffffff.toInt(),
        )),
        theme("nord", "Nord", 0xffd8dee9.toInt(), 0xff2e3440.toInt(), 0xff88c0d0.toInt(), intArrayOf(
            0xff3b4252.toInt(), 0xffbf616a.toInt(), 0xffa3be8c.toInt(), 0xffebcb8b.toInt(),
            0xff81a1c1.toInt(), 0xffb48ead.toInt(), 0xff88c0d0.toInt(), 0xffe5e9f0.toInt(),
            0xff4c566a.toInt(), 0xffbf616a.toInt(), 0xffa3be8c.toInt(), 0xffebcb8b.toInt(),
            0xff81a1c1.toInt(), 0xffb48ead.toInt(), 0xff8fbcbb.toInt(), 0xffeceff4.toInt(),
        )),
        theme("solarized-dark", "Solarized Dark", 0xff839496.toInt(), 0xff002b36.toInt(), 0xffb58900.toInt(), intArrayOf(
            0xff073642.toInt(), 0xffdc322f.toInt(), 0xff859900.toInt(), 0xffb58900.toInt(),
            0xff268bd2.toInt(), 0xffd33682.toInt(), 0xff2aa198.toInt(), 0xffeee8d5.toInt(),
            0xff002b36.toInt(), 0xffcb4b16.toInt(), 0xff586e75.toInt(), 0xff657b83.toInt(),
            0xff839496.toInt(), 0xff6c71c4.toInt(), 0xff93a1a1.toInt(), 0xfffdf6e3.toInt(),
        )),
    )

    fun byId(id: String?): TerminalTheme = all.firstOrNull { it.id == id } ?: all.first()

    private fun theme(id: String, name: String, foreground: Int, background: Int, cursor: Int, base: IntArray) =
        TerminalTheme(id, name, foreground, background, cursor, xtermPalette(base))

    private fun xtermPalette(base: IntArray): IntArray = IntArray(256).also { palette ->
        base.copyInto(palette)
        val levels = intArrayOf(0, 95, 135, 175, 215, 255)
        var index = 16
        for (red in levels) for (green in levels) for (blue in levels) {
            palette[index++] = 0xff000000.toInt() or (red shl 16) or (green shl 8) or blue
        }
        for (grayIndex in 0 until 24) {
            val gray = 8 + grayIndex * 10
            palette[232 + grayIndex] = 0xff000000.toInt() or (gray shl 16) or (gray shl 8) or gray
        }
    }
}
