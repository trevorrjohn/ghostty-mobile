package dev.ghostty.connect.data

import android.content.Context
import dev.ghostty.connect.model.TerminalTheme
import dev.ghostty.connect.model.TerminalThemes

class TerminalThemeStore(context: Context) {
    private val encryptedStore = EncryptedFileStore(context)

    fun load(): TerminalTheme = if (encryptedStore.exists(FILE_NAME)) {
        TerminalThemes.byId(encryptedStore.read(FILE_NAME).toString(Charsets.UTF_8))
    } else {
        TerminalThemes.byId(null)
    }

    fun save(theme: TerminalTheme) = encryptedStore.write(FILE_NAME, theme.id.toByteArray())

    fun loadFontSize(): Float = if (encryptedStore.exists(FONT_FILE)) {
        encryptedStore.read(FONT_FILE).toString(Charsets.UTF_8).toFloatOrNull()?.coerceIn(9f, 30f) ?: 15f
    } else 15f

    fun saveFontSize(size: Float) = encryptedStore.write(FONT_FILE, size.coerceIn(9f, 30f).toString().toByteArray())

    companion object {
        private const val FILE_NAME = "terminal-theme.enc"
        private const val FONT_FILE = "terminal-font-size.enc"
    }
}
