package app.anime.anime

import app.anime.anime.csp.CspMethodChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var cspMethodChannel: CspMethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        cspMethodChannel = CspMethodChannel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        cspMethodChannel?.close()
        cspMethodChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
