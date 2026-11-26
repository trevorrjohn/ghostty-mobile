package dev.ghostty.connect.sftp

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.random.Random

/** Where an uploaded image goes. `ASK` shows a destination sheet; the others upload immediately. */
enum class ImageUploadDestinationMode { ASK, CURRENT_DIRECTORY, UPLOADS_FOLDER }

/** Remote folder, relative to the account's home directory, used when the terminal's directory is unknown or unusable. */
internal const val IMAGE_UPLOADS_FOLDER = ".seance/uploads"

/** Where an image upload finished and why, so the UI can explain a fallback instead of hiding it. */
data class ImageUploadResult(val remotePath: String, val fellBackToUploadsFolder: Boolean)

private val FILE_NAME_TIME: DateTimeFormatter = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss")
private const val RANDOM_SUFFIX_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"

/** `screenshot-20261125-143005-ab12.png`: unique enough that an upload never needs a conflict prompt. */
internal fun imageUploadFileName(
    now: Instant,
    extension: String,
    zone: ZoneId = ZoneId.systemDefault(),
    random: Random = Random.Default,
): String {
    val suffix = buildString { repeat(4) { append(RANDOM_SUFFIX_ALPHABET[random.nextInt(RANDOM_SUFFIX_ALPHABET.length)]) } }
    val safeExtension = extension.lowercase().filter { it in 'a'..'z' || it in '0'..'9' }.ifEmpty { "png" }
    return "screenshot-${FILE_NAME_TIME.format(now.atZone(zone))}-$suffix.$safeExtension"
}

private val SHELL_SAFE = Regex("^[A-Za-z0-9_@%+=:,./-]+$")

/** Quotes only when a POSIX shell would otherwise split or expand the path. */
internal fun shellQuotePath(path: String): String =
    if (SHELL_SAFE.matches(path)) path else "'" + path.replace("'", "'\\''") + "'"

/** Text pasted into the terminal for finished uploads. Never ends in a newline, so nothing is executed. */
internal fun pastedUploadPaths(paths: List<String>): String = paths.joinToString(" ", transform = ::shellQuotePath)

/**
 * Whether a prompt is needed. With no known terminal directory there is only one sensible answer,
 * so `ASK` and `CURRENT_DIRECTORY` both skip straight to the uploads folder.
 */
internal fun shouldPromptForImageDestination(mode: ImageUploadDestinationMode, terminalDirectory: String?): Boolean =
    mode == ImageUploadDestinationMode.ASK && terminalDirectory != null

/** Terminal directory to use for [mode], or null to use the uploads folder. */
internal fun imageUploadTerminalDirectory(mode: ImageUploadDestinationMode, terminalDirectory: String?): String? =
    if (mode == ImageUploadDestinationMode.UPLOADS_FOLDER) null else terminalDirectory

enum class ImageUploadSource { LIBRARY, CAMERA, SHARE }

/** Per-host choice wins; otherwise the terminal menu uploads to the current directory and a share-in asks. */
internal fun resolveImageUploadMode(hostMode: ImageUploadDestinationMode?, shared: Boolean): ImageUploadDestinationMode =
    hostMode ?: if (shared) ImageUploadDestinationMode.ASK else ImageUploadDestinationMode.CURRENT_DIRECTORY

/** A share-in goes straight to the only live session; otherwise the user picks a session or saved host. */
internal fun shareInGoesToSingleSession(liveSessionCount: Int): Boolean = liveSessionCount == 1

internal const val MAX_IMAGE_UPLOAD_BYTES = 25L * 1024 * 1024
internal const val CAMERA_MAX_LONG_SIDE = 2048
internal const val CAMERA_JPEG_QUALITY = 85
internal const val MAX_DECODED_LONG_SIDE = 8192

/** Fits the long side within [maxLongSide] without upscaling. */
internal fun scaledImageSize(width: Int, height: Int, maxLongSide: Int): Pair<Int, Int> {
    val longSide = maxOf(width, height)
    if (longSide <= maxLongSide || width <= 0 || height <= 0) return width to height
    val scale = maxLongSide.toDouble() / longSide
    return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
}

/** Largest power-of-two subsampling that keeps the long side at least [targetLongSide]. */
internal fun imageSampleSize(width: Int, height: Int, targetLongSide: Int): Int {
    var sample = 1
    val longSide = maxOf(width, height)
    while (longSide / (sample * 2) >= targetLongSide) sample *= 2
    return sample
}

/** Screenshots and other lossless sources stay PNG; photos become JPEG, which also converts HEIC. */
internal fun usesPngOutput(mimeType: String): Boolean = when (mimeType.lowercase()) {
    "image/png", "image/webp", "image/gif" -> true
    else -> false
}

internal fun isUploadableImageMime(mimeType: String?): Boolean = mimeType?.lowercase()?.startsWith("image/") == true

/** Copies at most [max] bytes and fails instead of silently truncating. */
internal fun copyBounded(input: java.io.InputStream, output: java.io.OutputStream, max: Long): Long {
    val buffer = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
        val count = input.read(buffer)
        if (count < 0) return total
        total += count
        if (total > max) throw java.io.IOException("This image is larger than ${max / (1024 * 1024)} MiB.")
        output.write(buffer, 0, count)
    }
}
