package dev.ghostty.connect.sftp

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import dev.ghostty.connect.BuildConfig
import java.io.File

/**
 * Hands the system camera one write-only-by-grant destination in app cache. Nothing else can read or
 * write it: the provider is not exported and only the URI grant given with the capture intent opens it.
 */
class CameraCaptureProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String = "image/jpeg"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val file = fileFor(uri)
        val flags = if (mode.contains('w')) {
            ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE or ParcelFileDescriptor.MODE_WRITE_ONLY
        } else ParcelFileDescriptor.MODE_READ_ONLY
        return ParcelFileDescriptor.open(file, flags)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

    private fun fileFor(uri: Uri): File {
        val name = uri.lastPathSegment.orEmpty()
        require(Regex("camera-[0-9a-f-]{36}\\.jpg").matches(name)) { "Unknown capture destination." }
        return File(ImageUploadManager.cacheDirectory(requireNotNull(context)), name)
    }

    companion object {
        fun uriFor(file: File): Uri = Uri.Builder()
            .scheme("content")
            .authority("${BuildConfig.APPLICATION_ID}.camera-capture")
            .appendPath(file.name)
            .build()
    }
}
