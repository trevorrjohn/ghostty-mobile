package dev.ghostty.connect.model

import java.net.IDN
import java.net.Inet6Address
import java.net.InetAddress
import java.util.Locale

class SshDestination private constructor(
    val hostname: String,
    val port: Int,
    val isIpv6: Boolean,
) {
    val storageId: String get() = if (isIpv6) "[$hostname]:$port" else "$hostname:$port"
    val display: String get() = storageId

    override fun equals(other: Any?): Boolean = other is SshDestination &&
        hostname == other.hostname && port == other.port && isIpv6 == other.isIpv6

    override fun hashCode(): Int = 31 * (31 * hostname.hashCode() + port) + isIpv6.hashCode()

    override fun toString(): String = display

    companion object {
        fun create(hostname: String, port: Int): SshDestination {
            require(port in 1..65535) { "SSH port must be between 1 and 65535." }
            require(hostname.none(Char::isISOControl)) { "SSH hostname is invalid." }
            var value = hostname.trim()
            require(value.isNotEmpty()) { "SSH hostname is invalid." }
            val bracketed = value.startsWith('[') || value.endsWith(']')
            if (bracketed) {
                require(value.startsWith('[') && value.endsWith(']')) { "IPv6 brackets are malformed." }
                value = value.substring(1, value.lastIndex)
            }
            if (':' in value) {
                require('%' !in value) { "Scoped IPv6 addresses are not supported." }
                val address = InetAddress.getByName(value)
                require(address is Inet6Address) { "IPv6 address is invalid." }
                return SshDestination(canonicalIpv6(address.address), port, true)
            }
            require(!bracketed) { "Brackets are only valid around IPv6 addresses." }
            if (value.all { it.isDigit() || it == '.' }) {
                val octets = value.split('.')
                require(octets.size == 4 && octets.all { part ->
                    part.isNotEmpty() && part.all(Char::isDigit) && part.toIntOrNull() in 0..255
                }) { "IPv4 address is invalid." }
                return SshDestination(octets.joinToString(".") { it.toInt().toString() }, port, false)
            }
            value = value.removeSuffix(".")
            require(value.isNotEmpty() && !value.endsWith('.')) { "SSH hostname is invalid." }
            val ascii = IDN.toASCII(value, IDN.USE_STD3_ASCII_RULES).lowercase(Locale.ROOT)
            require(ascii.length <= 253 && ascii.split('.').all { it.isNotEmpty() && it.length <= 63 }) {
                "SSH hostname is invalid."
            }
            return SshDestination(ascii, port, false)
        }

        fun parseStorageId(storageId: String): SshDestination {
            val hostname: String
            val portText: String
            if (storageId.startsWith('[')) {
                val closing = storageId.indexOf(']')
                require(closing > 1 && closing + 1 < storageId.length && storageId[closing + 1] == ':') {
                    "Invalid trusted-host destination."
                }
                hostname = storageId.substring(1, closing)
                portText = storageId.substring(closing + 2)
            } else {
                val separator = storageId.lastIndexOf(':')
                require(separator > 0 && separator < storageId.lastIndex) { "Invalid trusted-host destination." }
                hostname = storageId.substring(0, separator)
                portText = storageId.substring(separator + 1)
            }
            return create(hostname, portText.toInt())
        }

        private fun canonicalIpv6(bytes: ByteArray): String {
            require(bytes.size == 16)
            val groups = List(8) { index ->
                ((bytes[index * 2].toInt() and 0xff) shl 8) or (bytes[index * 2 + 1].toInt() and 0xff)
            }
            var bestStart = -1
            var bestLength = 0
            var index = 0
            while (index < groups.size) {
                if (groups[index] != 0) {
                    index++
                    continue
                }
                val start = index
                while (index < groups.size && groups[index] == 0) index++
                val length = index - start
                if (length >= 2 && length > bestLength) {
                    bestStart = start
                    bestLength = length
                }
            }
            if (bestStart < 0) return groups.joinToString(":") { it.toString(16) }
            val left = groups.take(bestStart).joinToString(":") { it.toString(16) }
            val right = groups.drop(bestStart + bestLength).joinToString(":") { it.toString(16) }
            return when {
                left.isEmpty() && right.isEmpty() -> "::"
                left.isEmpty() -> "::$right"
                right.isEmpty() -> "$left::"
                else -> "$left::$right"
            }
        }
    }
}

fun sameSshDestination(firstHostname: String, firstPort: Int, secondHostname: String, secondPort: Int): Boolean =
    runCatching { SshDestination.create(firstHostname, firstPort) }.getOrNull()?.let { first ->
        first == runCatching { SshDestination.create(secondHostname, secondPort) }.getOrNull()
    } == true
