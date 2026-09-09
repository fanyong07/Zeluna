package app.anime.anime

import android.os.Build
import android.os.Bundle
import android.view.View
import app.anime.anime.csp.CspMethodChannel
import app.anime.anime.storage.StorageMethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

open class MainActivity : FlutterActivity() {
    private var videoCompatibilityChannel: MethodChannel? = null
    private var cspMethodChannel: CspMethodChannel? = null
    private var storageMethodChannel: StorageMethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hideSystemBarsDuringStartup()
    }

    @Suppress("DEPRECATION")
    private fun hideSystemBarsDuringStartup() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        videoCompatibilityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.anime.anime/video-compatibility",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method == "requiresSoftwareVideoDecode") {
                    result.success(VideoDecodeCompatibility.requiresSoftwareDecode(
                        Build.SUPPORTED_ABIS.firstOrNull(),
                    ))
                } else {
                    result.notImplemented()
                }
            }
        }
        cspMethodChannel = CspMethodChannel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        storageMethodChannel = StorageMethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        videoCompatibilityChannel?.setMethodCallHandler(null)
        videoCompatibilityChannel = null
        cspMethodChannel?.close()
        cspMethodChannel = null
        storageMethodChannel?.close()
        storageMethodChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
