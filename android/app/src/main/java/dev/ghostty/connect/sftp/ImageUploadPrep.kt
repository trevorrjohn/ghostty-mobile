package dev.ghostty.connect.sftp

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException

internal class PreparedImage(val bytes: ByteArray, val extension: String)

/**
 * Decodes, applies EXIF orientation, optionally downscales camera photos, and re-encodes. Re-encoding
 * drops every metadata block, including GPS and camera details, and converts HEIC to JPEG.
 */
internal fun prepareImage(file: File, mimeType: String, source: ImageUploadSource): PreparedImage {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IOException("This file is not an image Android can read.")
    val target = if (source == ImageUploadSource.CAMERA) CAMERA_MAX_LONG_SIDE else MAX_DECODED_LONG_SIDE
    val options = BitmapFactory.Options().apply {
        inSampleSize = imageSampleSize(bounds.outWidth, bounds.outHeight, target)
    }
    var bitmap = BitmapFactory.decodeFile(file.path, options) ?: throw IOException("This image could not be decoded.")
    val orientation = runCatching {
        ExifInterface(file.path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
    }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
    val (width, height) = scaledImageSize(bitmap.width, bitmap.height, target)
    val matrix = Matrix().apply {
        if (width != bitmap.width) postScale(width.toFloat() / bitmap.width, height.toFloat() / bitmap.height)
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { postRotate(90f); postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_TRANSVERSE -> { postRotate(270f); postScale(-1f, 1f) }
        }
    }
    if (!matrix.isIdentity) {
        val transformed = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (transformed !== bitmap) bitmap.recycle()
        bitmap = transformed
    }
    try {
        val png = usesPngOutput(mimeType)
        val output = ByteArrayOutputStream()
        val format = if (png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        check(bitmap.compress(format, if (png) 100 else CAMERA_JPEG_QUALITY, output)) { "The image could not be encoded." }
        if (output.size() > MAX_IMAGE_UPLOAD_BYTES) throw IOException("This image is larger than 25 MiB.")
        return PreparedImage(output.toByteArray(), if (png) "png" else "jpg")
    } finally {
        bitmap.recycle()
    }
}
