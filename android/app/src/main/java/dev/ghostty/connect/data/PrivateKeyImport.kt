package dev.ghostty.connect.data

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

internal const val MAX_PRIVATE_KEY_BYTES = 1024 * 1024

internal fun privateKeyImportBytes(text: String): ByteArray {
    val bytes = text.toByteArray(Charsets.UTF_8)
    require(bytes.size <= MAX_PRIVATE_KEY_BYTES) { "Private key is too large" }
    require(text.contains("PRIVATE KEY")) { "Paste a PEM, PKCS#8, or OpenSSH private key" }
    return bytes
}

internal fun readPrivateKeyBytes(input: InputStream): ByteArray {
    val buffer = ByteArray(MAX_PRIVATE_KEY_BYTES + 1)
    return try {
        var total = 0
        while (total < buffer.size) {
            val count = input.read(buffer, total, buffer.size - total)
            if (count < 0) break
            if (count == 0) {
                val next = input.read()
                if (next < 0) break
                buffer[total++] = next.toByte()
            } else {
                total += count
            }
        }
        require(total <= MAX_PRIVATE_KEY_BYTES) { "Private key is too large" }
        buffer.copyOf(total)
    } finally {
        buffer.fill(0)
    }
}

internal fun decodePrivateKeyText(bytes: ByteArray): String = try {
    Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString()
} catch (_: Exception) {
    throw IllegalArgumentException("Private key file is not valid UTF-8")
}
