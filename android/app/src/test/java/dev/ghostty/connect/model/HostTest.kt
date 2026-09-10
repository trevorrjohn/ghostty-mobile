package dev.ghostty.connect.model

import org.junit.Assert.assertEquals
import org.junit.Test

class HostTest {
    @Test
    fun duplicateCopiesHostWithNewIdentityAndName() {
        val host = Host(
            id = "original",
            alias = "Production",
            hostname = "prod.example.com",
            port = 2222,
            username = "ghost",
            authenticationType = AuthenticationType.SSH_KEY,
            identityId = "identity-id",
            allowRemoteClipboard = true,
            allowRemoteNotifications = false,
            allowSftpDelete = true,
            retryEnabled = false,
            retryMaxAttempts = 8,
            retryBackoff = RetryBackoff.CONSERVATIVE,
            startupCommand = "tmux attach || tmux",
        )

        val duplicate = host.duplicate("duplicate", listOf(host.name))

        assertEquals(host.copy(id = "duplicate", alias = "Production copy"), duplicate)
        assertEquals("original", host.id)
        assertEquals("Production", host.alias)
    }

    @Test
    fun duplicateUsesHostnameAndAvoidsExistingNames() {
        val host = Host(id = "original", hostname = "example.com", username = "ghost")

        val duplicate = host.duplicate(
            "duplicate",
            listOf("example.com", "example.com copy", "example.com copy 2"),
        )

        assertEquals("example.com copy 3", duplicate.alias)
    }

    @Test
    fun remoteFileDeletionDefaultsToDisabled() {
        val host = Host(id = "host", hostname = "example.com", username = "ghost")

        assertEquals(false, host.allowSftpDelete)
    }

    @Test
    fun retryDefaultsPreserveExistingBehavior() {
        val host = Host(id = "host", hostname = "example.com", username = "ghost")

        assertEquals(true, host.retryEnabled)
        assertEquals(5, host.retryMaxAttempts)
        assertEquals(RetryBackoff.BALANCED, host.retryBackoff)
    }

    @Test(expected = IllegalArgumentException::class)
    fun retryAttemptLimitIsBounded() {
        Host(id = "host", hostname = "example.com", username = "ghost", retryMaxAttempts = 11)
    }

    @Test
    fun startupCommandIsNormalizedBoundedAndDuplicated() {
        assertEquals(null, normalizeStartupCommand("   "))
        assertEquals("tmux attach || tmux", normalizeStartupCommand("  tmux attach || tmux  "))
        assertEquals("tmux", Host(
            id = "host",
            hostname = "example.com",
            username = "ghost",
            startupCommand = "tmux",
        ).duplicate("copy", emptyList()).startupCommand)
        assertEquals("a".repeat(1_024), normalizeStartupCommand("a".repeat(1_024)))
    }

    @Test(expected = IllegalArgumentException::class)
    fun startupCommandRejectsMultipleLines() {
        normalizeStartupCommand("tmux\nwhoami")
    }

    @Test(expected = IllegalArgumentException::class)
    fun startupCommandRejectsMoreThanMaximumBytes() {
        normalizeStartupCommand("a".repeat(1_025))
    }

    @Test
    fun tailscaleSshUsesPort22WithoutIdentity() {
        val host = Host(
            id = "tailnet",
            hostname = "workstation",
            username = "ghost",
            authenticationType = AuthenticationType.TAILSCALE_SSH,
        )

        assertEquals(22, host.port)
        assertEquals(null, host.identityId)
    }

    @Test(expected = IllegalArgumentException::class)
    fun tailscaleSshRejectsOtherPorts() {
        Host(
            id = "tailnet",
            hostname = "workstation",
            port = 2222,
            username = "ghost",
            authenticationType = AuthenticationType.TAILSCALE_SSH,
        )
    }
}
