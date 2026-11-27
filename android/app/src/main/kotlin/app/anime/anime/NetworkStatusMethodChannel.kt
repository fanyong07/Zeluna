package app.anime.anime

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class NetworkStatusMethodChannel(context: Context, messenger: BinaryMessenger) {
    private val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val channel = MethodChannel(messenger, "app.anime.anime/network-status")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "isUnmetered") result.success(isUnmetered()) else result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun isUnmetered(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            val network = manager.activeNetworkInfo ?: return false
            return network.isConnected && (network.type == ConnectivityManager.TYPE_WIFI ||
                network.type == ConnectivityManager.TYPE_ETHERNET)
        }
        val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
    }

    fun close() = channel.setMethodCallHandler(null)
}
