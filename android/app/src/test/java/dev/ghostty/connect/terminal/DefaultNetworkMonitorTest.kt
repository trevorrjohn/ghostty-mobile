package dev.ghostty.connect.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DefaultNetworkMonitorTest {
    @Test
    fun usableDefaultNetworkAllowsRetryRegardlessOfTransport() {
        assertEquals(
            NetworkAvailability.USABLE,
            networkAvailability(true, hasInternetCapability = true, isSuspended = false, isBlocked = false),
        )
        assertTrue(NetworkAvailability.USABLE.allowsRetry())
        assertTrue(NetworkAvailability.UNKNOWN.allowsRetry())
    }

    @Test
    fun absentSuspendedBlockedOrLocalOnlyNetworkWaits() {
        assertEquals(
            NetworkAvailability.UNUSABLE,
            networkAvailability(false, hasInternetCapability = false, isSuspended = true, isBlocked = false),
        )
        assertEquals(
            NetworkAvailability.UNUSABLE,
            networkAvailability(true, hasInternetCapability = true, isSuspended = true, isBlocked = false),
        )
        assertEquals(
            NetworkAvailability.UNUSABLE,
            networkAvailability(true, hasInternetCapability = true, isSuspended = false, isBlocked = true),
        )
        assertEquals(
            NetworkAvailability.UNUSABLE,
            networkAvailability(true, hasInternetCapability = false, isSuspended = false, isBlocked = false),
        )
        assertFalse(NetworkAvailability.UNUSABLE.allowsRetry())
    }
}
