package dev.ghostty.connect.terminal

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.util.Base64
import kotlin.math.ceil

internal object ItermImageTranslator {
    fun translate(image: ItermInlineImage, metrics: TerminalPixelMetrics): List<ByteArray> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(image.data, 0, image.data.size, bounds)
        if (bounds.outWidth !in 1..MAX_DIMENSION || bounds.outHeight !in 1..MAX_DIMENSION ||
            bounds.outWidth.toLong() * bounds.outHeight > MAX_PIXELS) return emptyList()
        val bitmap = BitmapFactory.decodeByteArray(image.data, 0, image.data.size) ?: return emptyList()
        val png = try {
            ByteArrayOutputStream().use { output ->
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) return emptyList()
                output.toByteArray().takeIf { it.size <= MAX_PNG_BYTES } ?: return emptyList()
            }
        } finally {
            bitmap.recycle()
        }
        val (columns, rows) = image.cellSize(bounds.outWidth, bounds.outHeight, metrics)
        val encoded = Base64.getEncoder().encode(png)
        return buildList {
            var offset = 0
            while (offset < encoded.size) {
                val length = minOf(KITTY_CHUNK_BYTES, encoded.size - offset)
                val more = offset + length < encoded.size
                val first = offset == 0
                val parameters = if (first) {
                    "a=T,f=100,q=2,c=$columns,r=$rows,m=${if (more) 1 else 0}"
                } else {
                    "m=${if (more) 1 else 0}"
                }
                add(ByteArray(parameters.length + length + 6).also { command ->
                    var target = 0
                    "\u001b_G$parameters;".toByteArray(Charsets.US_ASCII).copyInto(command, destinationOffset = target)
                    target += parameters.length + 4
                    encoded.copyInto(command, target, offset, offset + length)
                    target += length
                    command[target] = 0x1b
                    command[target + 1] = 0x5c
                })
                offset += length
            }
        }
    }

    private fun ItermInlineImage.cellSize(
        imageWidth: Int,
        imageHeight: Int,
        metrics: TerminalPixelMetrics,
    ): Pair<Int, Int> {
        val cellWidth = (metrics.pixelWidth / metrics.columns.coerceAtLeast(1).toFloat()).coerceAtLeast(1f)
        val cellHeight = (metrics.pixelHeight / metrics.rows.coerceAtLeast(1).toFloat()).coerceAtLeast(1f)
        val width = parseDimension(options["width"], metrics.columns, cellWidth)
        val height = parseDimension(options["height"], metrics.rows, cellHeight)
        var columns = width ?: ceil(imageWidth / cellWidth).toInt()
        var rows = height ?: ceil(imageHeight / cellHeight).toInt()
        if (options["preserveAspectRatio"] != "0") {
            when {
                width != null && height == null -> rows = ceil(columns * cellWidth * imageHeight / imageWidth / cellHeight).toInt()
                width == null && height != null -> columns = ceil(rows * cellHeight * imageWidth / imageHeight / cellWidth).toInt()
                width != null && height != null -> {
                    val widthScale = columns * cellWidth / imageWidth
                    val heightScale = rows * cellHeight / imageHeight
                    if (widthScale < heightScale) rows = ceil(imageHeight * widthScale / cellHeight).toInt()
                    else columns = ceil(imageWidth * heightScale / cellWidth).toInt()
                }
            }
        }
        return columns.coerceIn(1, metrics.columns.coerceAtLeast(1)) to rows.coerceIn(1, MAX_CELL_ROWS)
    }

    private fun parseDimension(value: String?, terminalCells: Int, cellPixels: Float): Int? {
        if (value == null || value == "auto") return null
        return runCatching {
            when {
                value.endsWith("px") -> ceil(value.dropLast(2).toDouble() / cellPixels).toInt()
                value.endsWith('%') -> ceil(terminalCells * value.dropLast(1).toDouble() / 100.0).toInt()
                else -> value.toInt()
            }.takeIf { it > 0 }
        }.getOrNull()
    }

    private const val MAX_DIMENSION = 4096
    private const val MAX_PIXELS = 4L * 1024 * 1024
    private const val MAX_PNG_BYTES = 8 * 1024 * 1024
    private const val MAX_CELL_ROWS = 1024
    private const val KITTY_CHUNK_BYTES = 4096
}

internal data class TerminalPixelMetrics(
    val columns: Int,
    val rows: Int,
    val pixelWidth: Int,
    val pixelHeight: Int,
)
