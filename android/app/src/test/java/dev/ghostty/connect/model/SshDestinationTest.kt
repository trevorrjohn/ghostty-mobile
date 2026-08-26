package dev.ghostty.connect.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SshDestinationTest {
    @Test
    fun normalizesDnsCaseRootDotAndIdn() {
        assertEquals("example.com:22", SshDestination.create("EXAMPLE.com.", 22).storageId)
        assertEquals("xn--bcher-kva.example:22", SshDestination.create("bücher.example", 22).storageId)
        assertEquals(
            SshDestination.create("bücher.example", 22),
            SshDestination.create("XN--BCHER-KVA.EXAMPLE.", 22),
        )
    }

    @Test
    fun normalizesIpv4WithoutOctalInterpretation() {
        assertEquals("192.168.1.1:22", SshDestination.create("192.168.001.001", 22).storageId)
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("256.1.1.1", 22) }
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("1.2.3", 22) }
    }

    @Test
    fun normalizesBracketedExpandedIpv6() {
        val expanded = SshDestination.create("2001:0DB8:0:0:0:0:0:1", 22)
        val bracketed = SshDestination.create("[2001:db8::1]", 22)

        assertEquals(expanded, bracketed)
        assertEquals("[2001:db8::1]:22", expanded.storageId)
        assertEquals("2001:db8::1", expanded.hostname)
    }

    @Test
    fun canonicalizesStoredPortsAndKeepsDistinctPortsSeparate() {
        assertEquals(
            SshDestination.create("example.com", 22),
            SshDestination.parseStorageId("EXAMPLE.com.:022"),
        )
        assertFalse(SshDestination.create("example.com", 22) == SshDestination.create("example.com", 2222))
    }

    @Test
    fun rejectsMalformedDestinations() {
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("[example.com]", 22) }
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("[2001:db8::1", 22) }
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("fe80::1%en0", 22) }
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("example..com", 22) }
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("example.com..", 22) }
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("example.com\n", 22) }
        assertThrows(IllegalArgumentException::class.java) { SshDestination.create("example.com", 0) }
    }

    @Test
    fun comparesOnlyValidNormalizedDestinations() {
        assertTrue(sameSshDestination("EXAMPLE.com.", 22, "example.com", 22))
        assertTrue(sameSshDestination("[2001:db8::1]", 22, "2001:0db8::1", 22))
        assertFalse(sameSshDestination("invalid host", 22, "invalid host", 22))
    }
}
