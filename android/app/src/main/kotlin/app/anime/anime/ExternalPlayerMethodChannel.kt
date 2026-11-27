package app.anime.anime

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class ExternalPlayerMethodChannel(activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "app.anime.anime/external-player")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "openVideoUrl") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val args = call.arguments as? Map<*, *>
            val uri = (args?.get("url") as? String)?.let(Uri::parse)
            if (uri == null || uri.scheme !in setOf("http", "https") || uri.host.isNullOrBlank()) {
                result.success(false)
                return@setMethodCallHandler
            }
            val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/*")
            try {
                activity.startActivity(Intent.createChooser(intent, args["title"] as? String))
                result.success(true)
            } catch (_: ActivityNotFoundException) {
                result.success(false)
            }
        }
    }

    fun close() = channel.setMethodCallHandler(null)
}
