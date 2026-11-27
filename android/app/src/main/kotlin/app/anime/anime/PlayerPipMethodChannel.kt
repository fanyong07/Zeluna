package app.anime.anime

import android.app.Activity
import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

internal fun pipAspectRatio(width: Int?, height: Int?): Pair<Int, Int> {
    if (width == null || height == null || width <= 0 || height <= 0) return 16 to 9
    val ratio = width.toDouble() / height
    return when {
        ratio < 0.42 -> 42 to 100
        ratio > 2.39 -> 239 to 100
        else -> width to height
    }
}

internal class PlayerPipMethodChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "app.anime.anime/pip")
    private val supported get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(supported)
                "enterPip" -> {
                    val args = call.arguments as? Map<*, *>
                    val (w, h) = pipAspectRatio(args?.get("aspectWidth") as? Int, args?.get("aspectHeight") as? Int)
                    val entered = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && supported) {
                        try {
                            activity.enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(w, h)).build())
                        } catch (_: IllegalStateException) {
                            false // Activity is no longer visible or PiP was disabled by the system.
                        }
                    } else false
                    result.success(entered)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun notifyPipChanged(inPip: Boolean) = channel.invokeMethod("onPipChanged", inPip)
    fun close() = channel.setMethodCallHandler(null)
}
