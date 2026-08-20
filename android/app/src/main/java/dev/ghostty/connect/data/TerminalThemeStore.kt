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

    companion object {
        private const val FILE_NAME = "terminal-theme.enc"
    }
}
