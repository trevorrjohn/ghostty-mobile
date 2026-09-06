package dev.ghostty.connect.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TailscaleVerificationTest {
    @Test fun extractsBoundedHttpsVerificationUrl() {
        assertEquals(
            "https://login.tailscale.com/a/example",
            tailscaleVerificationUrl("Authenticate at https://login.tailscale.com/a/example."),
        )
    }

    @Test fun rejectsNonHttpsUrl() {
        assertNull(tailscaleVerificationUrl("Open http://example.test/unsafe"))
    }

    @Test fun rejectsMisleadingOrUnrelatedHttpsUrl() {
        assertNull(tailscaleVerificationUrl("Open https://login.tailscale.com@evil.example/check"))
        assertNull(tailscaleVerificationUrl("Open https://evil.example/check"))
    }

    @Test fun boundsUntrustedBanner() {
        assertEquals(8192, boundedAuthenticationBanner("x".repeat(9000)).length)
    }
}
