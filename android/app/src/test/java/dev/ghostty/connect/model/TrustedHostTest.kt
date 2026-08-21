package dev.ghostty.connect.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TrustedHostTest {
    @Test
    fun decodesHostnameAndPort() {
        val trustedHost = decodeTrustedHostId("server.example.com:2222", "SHA256:abc")

        assertEquals("server.example.com", trustedHost.hostname)
        assertEquals(2222, trustedHost.port)
        assertEquals("server.example.com:2222", trustedHost.destination)
        assertEquals("SHA256:abc", trustedHost.fingerprint)
    }

    @Test
    fun decodesAndBracketsIpv6Destination() {
        val trustedHost = decodeTrustedHostId("2001:db8::1:22", "SHA256:abc")

        assertEquals("2001:db8::1", trustedHost.hostname)
        assertEquals("[2001:db8::1]:22", trustedHost.destination)
    }

    @Test
    fun preservesAlreadyBracketedIpv6Destination() {
        val trustedHost = decodeTrustedHostId("[2001:db8::1]:22", "SHA256:abc")

        assertEquals("[2001:db8::1]:22", trustedHost.destination)
    }

    @Test
    fun rejectsMalformedDestination() {
        assertThrows(IllegalArgumentException::class.java) {
            decodeTrustedHostId("server.example.com", "SHA256:abc")
        }
        assertThrows(NumberFormatException::class.java) {
            decodeTrustedHostId("server.example.com:ssh", "SHA256:abc")
        }
    }

    @Test
    fun rejectsInvalidPortsAndFingerprints() {
        assertThrows(IllegalArgumentException::class.java) {
            decodeTrustedHostId("server.example.com:0", "SHA256:abc")
        }
        assertThrows(IllegalArgumentException::class.java) {
            decodeTrustedHostId("server.example.com:65536", "SHA256:abc")
        }
        assertThrows(IllegalArgumentException::class.java) {
            decodeTrustedHostId("server.example.com:22", "")
        }
    }

    @Test
    fun preservesMalformedStoredIdentityForExactRemoval() {
        val trustedHost = decodeStoredTrustedHost("malformed", "")

        assertEquals("malformed", trustedHost.storageId)
        assertEquals("malformed", trustedHost.destination)
        assertEquals(null, trustedHost.hostname)
        assertEquals(null, trustedHost.port)
    }

    @Test
    fun preservesNoncanonicalPortStorageId() {
        val trustedHost = decodeStoredTrustedHost("server.example.com:022", "SHA256:abc")

        assertEquals("server.example.com:022", trustedHost.storageId)
        assertEquals("server.example.com:22", trustedHost.destination)
    }
}
