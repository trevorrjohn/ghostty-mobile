package dev.ghostty.connect.sftp

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import dev.ghostty.connect.BuildConfig
import java.io.File
import java.util.UUID

class SftpPreviewProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String {
        val name = uri.getQueryParameter(DISPLAY_NAME).orEmpty()
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val file = fileFor(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply {
            addRow(columns.map { column ->
                when (column) {
                    OpenableColumns.DISPLAY_NAME -> uri.getQueryParameter(DISPLAY_NAME) ?: "Remote file"
                    OpenableColumns.SIZE -> file.length()
                    else -> null
                }
            })
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val file = fileFor(uri)
        return when (mode) {
            "r" -> ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            "w" -> {
                check(Binder.getCallingUid() == Process.myUid()) { "Preview files are read-only outside the app." }
                ParcelFileDescriptor.open(
                    file,
                    ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or
                        ParcelFileDescriptor.MODE_WRITE_ONLY,
                )
            }
            else -> error("Unsupported preview access mode.")
        }
    }

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
        check(Binder.getCallingUid() == Process.myUid()) { "Preview files can only be removed by the app." }
        return if (fileFor(uri).delete()) 1 else 0
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    private fun fileFor(uri: Uri): File {
        require(uri.authority == authority(requireNotNull(context)))
        val name = uri.pathSegments.singleOrNull()
        require(name != null && PREVIEW_FILE.matches(name)) { "Invalid preview file." }
        val directory = previewDirectory(requireNotNull(context))
        val file = File(directory, name)
        require(file.canonicalFile.parentFile == directory.canonicalFile) { "Invalid preview path." }
        return file
    }

    companion object {
        private const val DISPLAY_NAME = "name"
        private const val MAX_CACHE_FILES = 20
        private const val MAX_CACHE_AGE_MS = 24 * 60 * 60 * 1_000L
        private val PREVIEW_FILE = Regex("[0-9a-f-]{36}(?:\\.[a-z0-9]{1,8})?")

        fun createUri(context: Context, displayName: String): Uri {
            val directory = previewDirectory(context)
            cleanup(directory)
            val extension = displayName.substringAfterLast('.', "").lowercase()
                .takeIf { it.matches(Regex("[a-z0-9]{1,8}")) }
            val fileName = UUID.randomUUID().toString() + extension?.let { ".$it" }.orEmpty()
            return Uri.Builder()
                .scheme("content")
                .authority(authority(context))
                .appendPath(fileName)
                .appendQueryParameter(DISPLAY_NAME, displayName.take(255))
                .build()
        }

        fun clearCache(context: Context) {
            previewDirectory(context).listFiles().orEmpty().forEach(File::delete)
        }

        private fun authority(context: Context): String = "${BuildConfig.APPLICATION_ID}.sftp-previews"

        private fun previewDirectory(context: Context): File = File(context.cacheDir, "sftp-previews").apply {
            check(isDirectory || mkdirs()) { "Preview cache could not be created." }
        }

        private fun cleanup(directory: File) {
            val now = System.currentTimeMillis()
            val files = directory.listFiles().orEmpty().sortedByDescending(File::lastModified)
            files.forEachIndexed { index, file ->
                if (index >= MAX_CACHE_FILES || now - file.lastModified() > MAX_CACHE_AGE_MS) file.delete()
            }
        }
    }
}
