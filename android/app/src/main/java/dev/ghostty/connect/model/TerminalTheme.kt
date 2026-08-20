package dev.ghostty.connect.model

data class TerminalTheme(
    val id: String,
    val name: String,
    val foreground: Int,
    val background: Int,
    val cursor: Int,
)

object TerminalThemes {
    val all = listOf(
        TerminalTheme("ghostty", "Ghostty", 0xfff1f3f8.toInt(), 0xff0a0c10.toInt(), 0xff8be9b3.toInt()),
        TerminalTheme("dracula", "Dracula", 0xfff8f8f2.toInt(), 0xff282a36.toInt(), 0xffff79c6.toInt()),
        TerminalTheme("nord", "Nord", 0xffd8dee9.toInt(), 0xff2e3440.toInt(), 0xff88c0d0.toInt()),
        TerminalTheme("solarized-dark", "Solarized Dark", 0xff839496.toInt(), 0xff002b36.toInt(), 0xffb58900.toInt()),
    )

    fun byId(id: String?): TerminalTheme = all.firstOrNull { it.id == id } ?: all.first()
}
