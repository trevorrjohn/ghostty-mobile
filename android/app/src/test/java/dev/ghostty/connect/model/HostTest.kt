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
            keyName = "work",
            allowRemoteClipboard = true,
            allowRemoteNotifications = false,
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
}
