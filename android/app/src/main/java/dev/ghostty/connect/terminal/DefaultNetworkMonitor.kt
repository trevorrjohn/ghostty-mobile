package dev.ghostty.connect.terminal

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler

internal enum class NetworkAvailability {
    USABLE,
    UNUSABLE,
    UNKNOWN,
}

internal fun NetworkAvailability.allowsRetry(): Boolean = this != NetworkAvailability.UNUSABLE

internal fun networkAvailability(
    hasActiveNetwork: Boolean,
    hasInternetCapability: Boolean,
    isSuspended: Boolean,
    isBlocked: Boolean,
): NetworkAvailability = when {
    !hasActiveNetwork || isBlocked || isSuspended || !hasInternetCapability -> NetworkAvailability.UNUSABLE
    else -> NetworkAvailability.USABLE
}

internal class DefaultNetworkMonitor(
    private val connectivityManager: ConnectivityManager,
    private val handler: Handler,
    private val onChanged: (NetworkAvailability) -> Unit,
) {
    private var generation = 0L
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var availability: NetworkAvailability? = null
    private val blockedNetworks = mutableSetOf<Network>()

    fun start() {
        if (callback != null) return
        val token = ++generation
        val registered = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refresh(token)

            override fun onLost(network: Network) {
                blockedNetworks.remove(network)
                refresh(token)
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = refresh(token)

            override fun onBlockedStatusChanged(network: Network, blocked: Boolean) {
                if (blocked) blockedNetworks += network else blockedNetworks -= network
                refresh(token)
            }
        }
        callback = registered
        val registration = runCatching { connectivityManager.registerDefaultNetworkCallback(registered, handler) }
        if (registration.isFailure) {
            callback = null
            publish(token, NetworkAvailability.UNKNOWN)
            return
        }
        refresh(token)
    }

    fun stop() {
        val registered = callback ?: return
        generation++
        callback = null
        availability = null
        blockedNetworks.clear()
        runCatching { connectivityManager.unregisterNetworkCallback(registered) }
    }

    private fun refresh(token: Long) {
        if (token != generation || callback == null) return
        val current = runCatching {
            val network = connectivityManager.activeNetwork
            val capabilities = network?.let(connectivityManager::getNetworkCapabilities)
            networkAvailability(
                hasActiveNetwork = network != null && capabilities != null,
                hasInternetCapability = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true,
                isSuspended = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED) != true,
                isBlocked = network in blockedNetworks,
            )
        }.getOrDefault(NetworkAvailability.UNKNOWN)
        publish(token, current)
    }

    private fun publish(token: Long, value: NetworkAvailability) {
        if (token != generation || availability == value) return
        availability = value
        onChanged(value)
    }
}
